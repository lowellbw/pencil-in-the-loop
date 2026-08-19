//
//  SettingsModel.swift
//  AppUI · Settings
//
//  The settings screen's state: the persisted values, the two things that have
//  to be asked for (storage size, speech assets), and the writes back.
//

import Foundation
import Observation
import Core

/// What S6 shows and changes (docs/02-spec.md § S6).
///
/// Every change is written straight through — there is no Save button anywhere
/// in this app and no unsaved state to lose (docs/02-spec.md § Cross-cutting).
///
/// **On failure:** a write that throws leaves the in-memory value as the user
/// set it and puts the reason in `statusMessage`. Reads that fail leave the
/// previous value; settings that cannot be loaded at all fall back to
/// `AppSettings.initial`, which lands the user on the folder picker
/// (Protocols.swift § SettingsStoring).
@Observable
public final class SettingsModel {

    /// The persisted configuration, as last read or last set.
    public private(set) var settings: AppSettings = .initial

    /// Bytes the library occupies, for the Storage row.
    public private(set) var storageBytes: Int64 = 0

    /// Whether on-device dictation can run. Polled when the screen appears;
    /// cheap by contract (Protocols.swift § SpeechTranscribing).
    public private(set) var speechAssetState: SpeechAssetState = .ready

    /// The languages the transcriber says it can handle, as BCP-47 identifiers
    /// in the order the picker shows them.
    ///
    /// Empty when the engine will not say, which is the documented answer and
    /// not a failure (Protocols.swift § SpeechTranscribing.supportedLocales).
    /// The picker then offers the selected language alone — one row, honestly
    /// labelled, rather than fourteen identifiers hardcoded in a view that has
    /// no idea what this device can do.
    public private(set) var supportedLocaleIdentifiers: [String] = []

    /// One line under whichever row last failed, or the result of a purge.
    public private(set) var statusMessage: String?

    private let environment: any AppEnvironment

    public init(environment: any AppEnvironment) {
        self.environment = environment
    }

    /// The one line the speech row shows, or nil when the assets are installed
    /// and there is nothing to say (docs/03-architecture.md § 4).
    public var speechAssetLine: String? {
        switch speechAssetState {
        case .ready:
            return nil
        case let .downloading(progress):
            guard let progress else { return "Downloading language assets" }
            let percent = min(max(progress, 0), 1).formatted(.percent.precision(.fractionLength(0)))
            return "Downloading language assets · " + percent
        case let .unavailable(reason):
            return reason
        }
    }

    /// True only while assets are actually arriving, so the row can carry a
    /// progress view without one appearing on the failure case.
    public var isDownloadingSpeechAssets: Bool {
        if case .downloading = speechAssetState { return true }
        return false
    }

    /// The rows the language picker shows: what the engine supports, with
    /// whatever is currently selected kept in the list even when it is not one
    /// of them.
    ///
    /// A setting that vanishes from its own picker is a setting the user cannot
    /// see they have.
    public var languageIdentifiers: [String] {
        var identifiers = supportedLocaleIdentifiers
        let current = settings.transcriptionLocaleIdentifier
        if identifiers.contains(current) == false {
            identifiers.insert(current, at: 0)
        }
        return identifiers
    }

    /// Reads everything the screen displays. Safe to call every time it appears.
    public func load() async {
        settings = await environment.settings.settings
        speechAssetState = await environment.transcriber.assetState()
        supportedLocaleIdentifiers = await environment.transcriber
            .supportedLocales()
            .map { $0.identifier(.bcp47) }
        do {
            storageBytes = try await environment.store.storageBytes()
        } catch {
            statusMessage = SyncFolderChoice.describe(error)
        }
    }

    /// Applies one edit and persists it.
    ///
    /// Takes a mutation rather than a whole `AppSettings` so that two rows
    /// changed in quick succession cannot write each other's stale copy back.
    public func change(_ mutate: (inout AppSettings) -> Void) {
        var updated = settings
        mutate(&updated)
        settings = updated
        Task { await persist(updated) }
    }

    /// Deletes archived documents and their bytes — the only operation in the
    /// app that removes a document's files, and the user has to ask for it
    /// (docs/02-spec.md § S6).
    public func purge() async {
        do {
            let freed = try await environment.store.purgeArchived()
            storageBytes = try await environment.store.storageBytes()
            statusMessage = freed == 0
                ? "Nothing to remove"
                : freed.formatted(.byteCount(style: .file)) + " removed"
        } catch {
            statusMessage = SyncFolderChoice.describe(error)
        }
    }

    /// Adopts a folder the user picked in Settings, and re-reads what changed.
    public func adoptFolder(_ url: URL) async {
        do {
            let folder = try await SyncFolderChoice.adopt(
                url,
                folderAccess: environment.folderAccess,
                settings: environment.settings
            )
            // A folder chosen in Settings that only takes effect after a
            // relaunch is a folder the user will assume did not work.
            await environment.adoptFolder(folder)
            settings = await environment.settings.settings
            statusMessage = nil
        } catch {
            statusMessage = SyncFolderChoice.describe(error)
        }
    }

    /// Reports a problem the view saw before the model was involved — a picker
    /// that failed, for instance.
    public func report(_ message: String) {
        statusMessage = message
    }

    private func persist(_ updated: AppSettings) async {
        do {
            try await environment.settings.update(updated)
            statusMessage = nil
        } catch {
            statusMessage = SyncFolderChoice.describe(error)
        }
    }
}
