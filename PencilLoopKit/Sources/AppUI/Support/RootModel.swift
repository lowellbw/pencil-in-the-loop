//
//  RootModel.swift
//  AppUI · Support
//
//  What the app is showing, and the one piece of start-up logic there is:
//  resolve the sync folder if there is one, and do not wait for it if there is
//  not.
//

import Foundation
import Observation
import Core

/// The shell's state: the environment, which screen is up, and the folder.
///
/// **The launch path is deliberately short.** Build the environment, read one
/// setting, show a screen. Everything to do with the sync folder happens after
/// that and never blocks it: a bookmark that resolves attaches a coordinator, a
/// bookmark that does not puts one sentence in the library's status line, and
/// either way the library is already on screen reading from the local store.
/// Cold launch to a readable page has a one-second budget
/// (docs/03-architecture.md § Performance targets) and a file provider that is
/// signed out can take much longer than that to say so.
///
/// **On failure:** the only failure that reaches the user is the library store
/// refusing to open, which is `.unusable` and one sentence. Everything else —
/// no folder, a stale bookmark, an ejected volume — is a degraded sync loop and
/// a fully working reader.
@Observable
@MainActor
public final class RootModel {

    /// Which screen the app is showing.
    public enum Phase: Sendable, Hashable {

        /// Before the first settings read has come back. A frame or two.
        case starting

        /// No folder has ever been chosen: S0, and nothing else
        /// (docs/02-spec.md § S0).
        case firstRun

        /// The library and the reader.
        case library

        /// The library store would not open. `message` is shown verbatim.
        case unusable(message: String)
    }

    public private(set) var phase: Phase = .starting

    /// Built once and held. Nil only before `start()` has run, and after a
    /// failure that made `.unusable` the phase.
    public private(set) var environment: (any AppEnvironment)?

    /// A document the app should select in the library — an agent's reply that
    /// has just been opened as a document (docs/04-flows.md § F6).
    public var pendingSelection: UUID?

    /// The live environment, when the environment is the live one. The shell
    /// needs it for the folder ladder; every view is handed `environment`.
    private var live: LiveEnvironment?

    public init() {}

    /// Previews and `AppUITests`: a shell already holding an environment, so
    /// that nothing builds a real store, opens a real container or resolves a
    /// real bookmark. `start()` finds the phase is not `.starting` and does
    /// nothing.
    public init(previewing environment: any AppEnvironment, phase: Phase = .library) {
        self.environment = environment
        self.phase = phase
    }

    // MARK: - Launch

    /// Builds the environment and decides which screen to show.
    ///
    /// Safe to call more than once: a second call after the app is running
    /// re-scans rather than rebuilding anything.
    public func start() async {
        guard case .starting = phase else {
            await noteActive()
            return
        }

        let built: LiveEnvironment
        do {
            built = try await RootModel.buildEnvironment()
        } catch let error as PencilLoopError {
            phase = .unusable(message: error.message)
            return
        } catch {
            phase = .unusable(message: error.localizedDescription)
            return
        }

        live = built
        environment = built

        let settings = await built.settings.settings
        guard settings.hasCompletedFirstRun, let bookmark = settings.syncFolderBookmark else {
            phase = .firstRun
            return
        }

        // The library first, the folder second. In that order the reader is
        // usable before a file provider has been asked anything at all.
        phase = .library
        await attach(bookmark: bookmark, in: built)
    }

    /// Builds the environment away from the main thread.
    ///
    /// `LiveEnvironment.init` opens the SwiftData container, which is a
    /// synchronous store open and, after a schema change, a migration of
    /// unbounded length (`LibraryContainer`). `start()` is on the main actor
    /// because it sets `phase`, so without this hop the whole of that would run
    /// on the thread that is meant to be putting the first frame up. The
    /// launch path stays short by leaving the main actor for the one part of it
    /// that touches disk (docs/03-architecture.md § Performance targets).
    ///
    /// - Throws: whatever the initialiser throws, which is only
    ///   `PencilLoopError.storeWriteFailed`.
    private nonisolated static func buildEnvironment() async throws -> LiveEnvironment {
        try await Task.detached(priority: .userInitiated) {
            try LiveEnvironment()
        }.value
    }

    /// First run finished, or Settings changed the folder: start syncing it and
    /// show the library.
    public func adopt(_ folder: SyncFolder) async {
        guard let live else { return }
        await live.adoptFolder(folder)
        phase = .library
    }

    /// The scene became active.
    ///
    /// Two jobs, both cheap: re-scan, because file coordination does not
    /// reliably see every change a provider made while we were away
    /// (docs/02-spec.md § S1), and retry the folder if it was not there at
    /// launch — a volume gets remounted, a provider signs back in, and nothing
    /// else in the app is watching for that.
    public func noteActive() async {
        guard let live, case .library = phase else { return }
        if await live.gateway.isAttached {
            await live.sync.start()
            return
        }
        let settings = await live.settings.settings
        guard let bookmark = settings.syncFolderBookmark else { return }
        await attach(bookmark: bookmark, in: live)
    }

    /// The scene went away. Stops the watcher; the library stays fully usable.
    public func noteInactive() async {
        guard let live else { return }
        await live.sync.stop()
    }

    // MARK: - The folder

    /// The documented resolution ladder (Protocols.swift § FolderAccessing).
    ///
    /// 1. Resolve the bookmark.
    /// 2. A stale bookmark still yields a usable folder — take it from
    ///    `refreshedFolder(bookmark:)`, which also mints a replacement, and
    ///    persist that so the *next* launch does not have to do this.
    /// 3. Anything else: one sentence in the status line, and carry on. The
    ///    library is already on screen and every document in it opens.
    private func attach(bookmark: Data, in live: LiveEnvironment) async {
        do {
            let folder = try live.folderAccess.resolveFolder(bookmark: bookmark)
            await live.adoptFolder(folder)
        } catch let error as PencilLoopError {
            guard case .bookmarkStale = error else {
                await report(error, in: live)
                return
            }
            do {
                let folder = try live.folderAccess.refreshedFolder(bookmark: bookmark)
                try? await live.settingsStore.setSyncFolder(
                    bookmark: folder.bookmark,
                    displayName: folder.displayName
                )
                await live.adoptFolder(folder)
            } catch {
                await report(error, in: live)
            }
        } catch {
            await report(error, in: live)
        }
    }

    /// Puts a folder problem where folder problems belong: the library's status
    /// line, through the same event stream a running coordinator would use.
    private func report(_ error: any Error, in live: LiveEnvironment) async {
        await live.gateway.reportFolderUnavailable(SyncFolderChoice.describe(error))
    }
}
