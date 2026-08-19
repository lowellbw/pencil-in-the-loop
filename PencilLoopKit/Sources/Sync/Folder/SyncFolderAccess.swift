//
//  SyncFolderAccess.swift
//  Sync · Folder
//
//  Security-scoped access to the folder the user picked in S0, and the
//  bookmark that survives a relaunch.
//
//  Two things this file is careful about, because both are bugs that take an
//  afternoon to find:
//
//  1. **Every start is balanced by a stop, on every path.** `defer` does it, so
//     a throw in the middle cannot leak a scope. A leaked scope does not fail
//     loudly; it exhausts a per-process limit hours later, in a different
//     feature.
//  2. **A URL that is not security-scoped is not an error.** A plain file URL —
//     an App Group container, the app's own container, a temp directory in a
//     test — returns `false` from `startAccessingSecurityScopedResource()` and
//     needs no scope at all. Treating that as `.accessDenied` would make the
//     whole module untestable and would break the App Group import path.
//
//  ─── OVERLAPPING SCOPES ON ONE ROOT ──────────────────────────────────────────
//  Two callers reach the same folder from two actors: `SyncCoordinator` holds a
//  scope across a whole scan, and `PollingFolderWatcher` opens one of its own
//  every fifteen seconds. Whichever finishes first used to call
//  `stopAccessingSecurityScopedResource()`, and on a provider that does not
//  reference-count that closes the scope under an in-flight pin — which
//  surfaces, much later and somewhere else, as a spurious
//  `.materialisationFailed`.
//
//  So this type counts the opens itself, per root path, in `ScopeRegistry`
//  below. The first `beginAccess` really starts the scope and the last
//  `endAccess` really stops it; everything in between is bookkeeping. Callers
//  are unaffected — start and stop still have to balance — but nesting and
//  overlap are now safe rather than lucky.
//

import Foundation
import Core

/// `FolderAccessing`, over `startAccessingSecurityScopedResource` and
/// `URL.bookmarkData()`.
///
/// **On failure:** `prepareFolder(at:)` throws `.accessDenied` when the scope
/// will not open and the URL is not readable without one, and
/// `.folderUnavailable` when `inbox/` and `outbox/` cannot be created.
/// `resolveFolder(bookmark:)` throws `.bookmarkStale` when the bookmark
/// resolved but has gone stale, and `.folderUnavailable` when it will not
/// resolve at all. None of these may make an already ingested document
/// unreadable — documents live in the app container, and losing the folder
/// costs new documents only (docs/02-spec.md § Cross-cutting).
///
/// - Note: `FolderAccessing` now carries an async `withAccess` overload as
///   well, so work that suspends is reachable through the protocol.
///   `beginAccess(to:)` / `endAccess(to:wasStarted:)` remain here, outside the
///   protocol, for the one caller that opens a scope in one method and closes
///   it in another — `SyncCoordinator`, whose scan spans several collaborators.
///   Everything else should use `withAccess`. Both routes share one per-root
///   claim count, so overlapping callers cannot close a scope under each other.
public struct SyncFolderAccess: FolderAccessing {

    public init() {}

    // MARK: - FolderAccessing

    /// Takes the URL from `fileImporter`, creates `inbox/` and `outbox/` if
    /// absent, and mints a security-scoped bookmark.
    ///
    /// - Parameter url: exactly what the picker returned. Do not normalise it
    ///   first — a bookmark minted from a rewritten URL may not resolve.
    /// - Returns: the folder, with `bookmark` populated when one could be
    ///   minted. A nil bookmark is survivable for this launch and means the
    ///   user will be asked again on the next one.
    /// - Throws: `.accessDenied` when the scope will not open,
    ///   `.folderUnavailable` when the directories cannot be created.
    public func prepareFolder(at url: URL) throws -> SyncFolder {
        let started = url.startAccessingSecurityScopedResource()
        defer {
            if started {
                url.stopAccessingSecurityScopedResource()
            }
        }

        guard started || FileManager.default.isReadableFile(atPath: url.path) else {
            throw PencilLoopError.accessDenied(path: url.path)
        }

        // The root has to already exist. `startAccessingSecurityScopedResource`
        // returns true on iOS for plain file URLs — including ones that point at
        // nothing — so it cannot stand in for this check, and without it the
        // `withIntermediateDirectories` below would cheerfully invent the whole
        // tree. A picker that returned a folder that is gone is a folder that is
        // gone; saying so is the only honest answer.
        guard SyncFolderAccess.isDirectory(url) else {
            throw PencilLoopError.folderUnavailable(
                reason: "The folder is no longer there."
            )
        }

        var folder = SyncFolder(rootURL: url)
        do {
            try createDirectoryIfAbsent(at: folder.inboxURL)
            try createDirectoryIfAbsent(at: folder.outboxURL)
        } catch {
            throw PencilLoopError.folderUnavailable(
                reason: "\(SyncFolder.inboxDirectoryName) and \(SyncFolder.outboxDirectoryName) could not be created. \(error.localizedDescription)"
            )
        }

        folder.bookmark = SyncFolderAccess.bookmark(for: url)
        if folder.bookmark == nil {
            SyncLog.folder.error("The sync folder was prepared but no bookmark could be minted.")
        }
        return folder
    }

    /// Resolves a persisted bookmark.
    ///
    /// - Throws: `.bookmarkStale` when the bookmark resolved but is stale — the
    ///   caller mints a fresh one from the returned folder and saves it, which
    ///   in this implementation means calling `refreshedFolder(bookmark:)`,
    ///   since a throwing function has no folder to return.
    ///   `.folderUnavailable` when it cannot be resolved at all.
    public func resolveFolder(bookmark: Data) throws -> SyncFolder {
        var isStale = false
        let url: URL
        do {
            url = try URL(resolvingBookmarkData: bookmark, bookmarkDataIsStale: &isStale)
        } catch {
            throw PencilLoopError.folderUnavailable(
                reason: "The saved folder could not be reopened. \(error.localizedDescription)"
            )
        }
        if isStale {
            throw PencilLoopError.bookmarkStale
        }
        return SyncFolder(rootURL: url, bookmark: bookmark)
    }

    /// Runs `body` with the security scope open, closing it afterwards even if
    /// `body` throws.
    ///
    /// - Note: nesting is safe here — this type counts the opens per root (see
    ///   the file header), so an inner pair does not close the scope out from
    ///   under an outer one. Prefer not to nest anyway: a reader should be able
    ///   to see where the scope opens.
    /// - Throws: `.accessDenied` when the scope will not open and the root is
    ///   not readable without one; otherwise whatever `body` threw.
    public func withAccess<T: Sendable>(
        to folder: SyncFolder,
        perform body: @Sendable (SyncFolder) throws -> T
    ) throws -> T {
        let started = beginAccess(to: folder)
        defer { endAccess(to: folder, wasStarted: started) }

        guard started || FileManager.default.isReadableFile(atPath: folder.rootURL.path) else {
            throw PencilLoopError.accessDenied(path: folder.rootURL.path)
        }
        return try body(folder)
    }

    /// The same, for work that suspends.
    ///
    /// The scope is held for the whole of `body`, suspensions included, which
    /// is what the synchronous overload cannot do and what scanning, pinning
    /// and writing all need. A scope opened inside `body` — by this actor or
    /// another — joins this one and cannot close it early (see the file
    /// header).
    ///
    /// - Throws: `.accessDenied` when the scope will not open and the root is
    ///   not readable without one; otherwise whatever `body` threw.
    public func withAccess<T: Sendable>(
        to folder: SyncFolder,
        perform body: @Sendable (SyncFolder) async throws -> T
    ) async throws -> T {
        let started = beginAccess(to: folder)
        defer { endAccess(to: folder, wasStarted: started) }

        guard started || FileManager.default.isReadableFile(atPath: folder.rootURL.path) else {
            throw PencilLoopError.accessDenied(path: folder.rootURL.path)
        }
        return try await body(folder)
    }

    /// Whether the root is reachable right now.
    ///
    /// Never throws: a false answer is information — an ejected volume, a
    /// signed-out provider — and the app carries on reading what it already
    /// has.
    public func isReachable(_ folder: SyncFolder) -> Bool {
        let started = beginAccess(to: folder)
        defer { endAccess(to: folder, wasStarted: started) }
        return SyncFolderAccess.isDirectory(folder.rootURL)
    }

    // MARK: - Access that spans an await

    /// Opens the security scope, or joins one this process already holds, and
    /// reports whether the caller now holds a claim on it.
    ///
    /// Pair it with `endAccess(to:wasStarted:)` in a `defer`, always, and pass
    /// the value this returned — an unbalanced claim keeps the scope open for
    /// the life of the process, and a stop that was never started is the bug
    /// this counting exists to prevent.
    ///
    /// `false` is not a failure. It is what a plain file URL returns — an App
    /// Group container, a temp directory in a test — and the caller should carry
    /// on if the root is readable.
    @discardableResult
    public func beginAccess(to folder: SyncFolder) -> Bool {
        SyncFolderAccess.scopes.begin(folder.rootURL)
    }

    /// Releases a claim taken by `beginAccess(to:)`, closing the scope when it
    /// was the last one. A no-op when `wasStarted` is false, which is the only
    /// correct behaviour.
    public func endAccess(to folder: SyncFolder, wasStarted: Bool) {
        guard wasStarted else { return }
        SyncFolderAccess.scopes.end(folder.rootURL)
    }

    /// Whether the root is usable once the scope is already open.
    ///
    /// For callers inside a `beginAccess`/`endAccess` pair, where
    /// `isReachable(_:)` would open a second, nested scope.
    public func isReachableWithinOpenScope(_ folder: SyncFolder) -> Bool {
        SyncFolderAccess.isDirectory(folder.rootURL)
    }

    // MARK: - Recovery

    /// Re-resolves a stale bookmark and mints a fresh one.
    ///
    /// The recovery half of `resolveFolder(bookmark:)` throwing
    /// `.bookmarkStale` — a throwing call returns no folder to mint from, so
    /// the minting happens here. Persist `folder.bookmark` afterwards.
    ///
    /// - Throws: `.folderUnavailable` when the bookmark will not resolve even
    ///   in stale form.
    public func refreshedFolder(bookmark: Data) throws -> SyncFolder {
        var isStale = false
        let url: URL
        do {
            url = try URL(resolvingBookmarkData: bookmark, bookmarkDataIsStale: &isStale)
        } catch {
            throw PencilLoopError.folderUnavailable(
                reason: "The saved folder could not be reopened. \(error.localizedDescription)"
            )
        }
        let started = url.startAccessingSecurityScopedResource()
        defer {
            if started {
                url.stopAccessingSecurityScopedResource()
            }
        }
        let minted = SyncFolderAccess.bookmark(for: url) ?? bookmark
        return SyncFolder(rootURL: url, bookmark: minted)
    }

    /// Creates `inbox/` and `outbox/` inside an already-open scope.
    ///
    /// `prepareFolder(at:)` does this on first run; the watcher and the
    /// coordinator call it again when a folder comes back with its directories
    /// missing, which is what happens when a provider re-creates a root.
    ///
    /// - Throws: `.folderUnavailable` when either directory cannot be created.
    public func ensureDirectories(in folder: SyncFolder) throws {
        do {
            try createDirectoryIfAbsent(at: folder.inboxURL)
            try createDirectoryIfAbsent(at: folder.outboxURL)
        } catch {
            throw PencilLoopError.folderUnavailable(
                reason: "\(SyncFolder.inboxDirectoryName) and \(SyncFolder.outboxDirectoryName) could not be created. \(error.localizedDescription)"
            )
        }
    }

    // MARK: - Scope counting

    /// The one registry for this process. Every `beginAccess`/`endAccess` pair
    /// in the app goes through it, whichever actor made the call.
    private static let scopes = ScopeRegistry()

    /// How many claims each root has open, so two callers on one folder share a
    /// scope rather than closing it under each other.
    ///
    /// Keyed by standardised path: the coordinator and the watcher hold two
    /// `URL` values for the same folder and have to count as one root. The URL
    /// that opened the scope is kept so the stop is made against the same one.
    // SAFETY: `open` is only ever read or written with `lock` held, and the
    // class has no other mutable state. It is a final class with no
    // inheritance, so no subclass can add any.
    private final class ScopeRegistry: @unchecked Sendable {

        private let lock = NSLock()
        private var open: [String: (url: URL, count: Int)] = [:]

        /// Opens the scope for a root, or joins one already open for it.
        ///
        /// - Returns: true when the caller now holds a claim it must release
        ///   with `end(_:)`. False means the URL is not security-scoped at all —
        ///   a plain file URL — and needs no scope.
        func begin(_ url: URL) -> Bool {
            let key = ScopeRegistry.key(for: url)
            lock.lock()
            defer { lock.unlock() }

            if let entry = open[key], entry.count > 0 {
                open[key] = (entry.url, entry.count + 1)
                return true
            }
            guard url.startAccessingSecurityScopedResource() else { return false }
            open[key] = (url, 1)
            return true
        }

        /// Releases one claim, stopping the scope when it was the last one.
        ///
        /// A key nobody holds is ignored: an unbalanced stop is the failure this
        /// type exists to prevent, so it does not perform one.
        func end(_ url: URL) {
            let key = ScopeRegistry.key(for: url)
            lock.lock()
            defer { lock.unlock() }

            guard let entry = open[key], entry.count > 0 else { return }
            if entry.count > 1 {
                open[key] = (entry.url, entry.count - 1)
                return
            }
            open[key] = nil
            entry.url.stopAccessingSecurityScopedResource()
        }

        private static func key(for url: URL) -> String {
            url.standardizedFileURL.path(percentEncoded: false)
        }
    }

    // MARK: - Internals

    /// `URL.bookmarkData()` with no options, which is what makes a
    /// security-scoped bookmark on iOS — `.withSecurityScope` is a macOS-only
    /// option and passing it here fails.
    private static func bookmark(for url: URL) -> Data? {
        do {
            return try url.bookmarkData()
        } catch {
            SyncLog.folder.error("Minting a bookmark failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// Whether `url` is a directory **right now**.
    ///
    /// `FileManager.fileExists` rather than `URL.resourceValues`, and the
    /// difference is the whole point: a `URL` caches the resource values it has
    /// already been asked for, so a root that was a directory when the folder
    /// was picked keeps answering `true` from the same `URL` value long after
    /// the volume was ejected or the provider signed out. `SyncFolder.rootURL`
    /// lives for the whole run, so that cache would mean the app could never
    /// notice its folder had gone — the case docs/02-spec.md § F7 is about, and
    /// the one the status line exists to report.
    ///
    /// Made non-private so `PollingFolderWatcher` can ask the same question the
    /// same way; two spellings of it is how one of them ends up cached again.
    static func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(
            atPath: url.path(percentEncoded: false),
            isDirectory: &isDirectory
        )
        return exists && isDirectory.boolValue
    }

    private func createDirectoryIfAbsent(at url: URL) throws {
        if SyncFolderAccess.isDirectory(url) { return }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
}
