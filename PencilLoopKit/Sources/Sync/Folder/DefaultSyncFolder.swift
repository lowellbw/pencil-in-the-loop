//
//  DefaultSyncFolder.swift
//  Sync · Folder
//
//  The folder the app picks for itself, so that first run has nothing in it.
//
//  ─── WHY THERE IS A DEFAULT AT ALL ───────────────────────────────────────────
//  S0 used to be a folder picker and nothing else, which is one tap but also one
//  decision, and it is a decision most people cannot make well on first launch:
//  the answer has to be a folder their Mac can see, and nothing on the screen
//  says so. The app's own iCloud container is that folder, it needs no picking,
//  and it appears on the Mac as `iCloud Drive/PencilLoop` the moment it exists.
//
//  The picker has not gone anywhere. It is the fallback here and it is still
//  what Settings offers (S6), because a default is only a default: somebody
//  with their documents in Dropbox, or with iCloud Drive switched off, must
//  still be able to say so.
//
//  ─── WHAT THIS COSTS, AND WHY IT IS NOT ON THE LAUNCH PATH ───────────────────
//  `url(forUbiquityContainerIdentifier:)` is documented as blocking, and on a
//  first call it can take seconds — it may have to talk to the account. The
//  launch budget is one second to a readable page (docs/03-architecture.md
//  § Performance targets), so this must never be awaited before the first frame.
//  `RootModel` shows a screen first and resolves afterwards; that ordering is
//  the point, not an implementation detail.
//

import Foundation
import Core

/// The app's own iCloud Drive folder, resolved on demand.
///
/// A namespace, not an object: there is one answer and the system owns it.
///
/// **On failure:** throws `PencilLoopError.folderUnavailable(reason:)` with a
/// sentence a person can read. Failure is ordinary here — iCloud Drive can be
/// switched off, the device can be signed out — and it is never fatal: the
/// caller falls back to the picker, which is why S0 still has one.
public enum DefaultSyncFolder {

    /// The directory inside the container that is published to iCloud Drive.
    ///
    /// `NSUbiquitousContainerIsDocumentScopePublic` exposes the container's
    /// `Documents` and nothing else, so this is the only place a folder can go
    /// and still be visible on the Mac. Anything written beside it is private
    /// to the app for ever, which would be an invisible sync folder — the one
    /// failure this whole file exists to avoid.
    public static let publishedDirectoryName = "Documents"

    /// Resolves the container, creates the published directory if it is not
    /// there yet, and hands back a URL ready for `prepareFolder(at:)`.
    ///
    /// `nonisolated` and doing its own blocking work: call it from a detached
    /// task, never from the main actor. See the file header.
    ///
    /// - Returns: the folder the app should adopt, with no `inbox/` or
    ///   `outbox/` in it yet — creating those is `prepareFolder(at:)`'s job, so
    ///   that a picked folder and a default one go through exactly one path.
    /// - Throws: `.folderUnavailable(reason:)` when iCloud Drive is not
    ///   available to this app, or when the published directory cannot be made.
    public nonisolated static func locate() throws -> URL {
        // A nil identifier means "the first container in the entitlement",
        // which is what keeps the bundle id out of this file. Hard-coding
        // `iCloud.com.…` here would be a second place to edit when the id
        // changes, and the one nobody would remember (FirstBuild.md § 2b).
        guard let container = FileManager.default.url(forUbiquityContainerIdentifier: nil) else {
            throw PencilLoopError.folderUnavailable(
                reason: "iCloud Drive is not available on this iPad. Turn it on in Settings, or choose a folder yourself."
            )
        }

        let published = container.appendingPathComponent(
            publishedDirectoryName,
            isDirectory: true
        )
        do {
            try createDirectoryIfAbsent(at: published)
        } catch {
            throw PencilLoopError.folderUnavailable(
                reason: "The iCloud folder could not be created. \(error.localizedDescription)"
            )
        }
        return published
    }

    /// Whether the app has an iCloud container to put a folder in.
    ///
    /// Cheaper than `locate()` in the failing case only; it does the same
    /// blocking resolve, so it carries the same rule about the main actor. For
    /// a status row that wants to say why sync is idle, not for the launch
    /// path.
    public nonisolated static var isAvailable: Bool {
        FileManager.default.url(forUbiquityContainerIdentifier: nil) != nil
    }

    private nonisolated static func createDirectoryIfAbsent(at url: URL) throws {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(
            atPath: url.path(percentEncoded: false),
            isDirectory: &isDirectory
        )
        if exists && isDirectory.boolValue { return }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
}
