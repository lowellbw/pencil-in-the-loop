//
//  PinnedDocumentWriter.swift
//  Sync · Pin
//
//  Container discipline, with no opinion about where the bytes came from.
//
//  ─── WHY THIS IS ITS OWN TYPE ────────────────────────────────────────────────
//  `InboxItemPinner` does two separable jobs. One is iCloud materialisation —
//  ask a file provider for a download and wait until the bytes are really here
//  — which is meaningless over HTTP. The other is *container discipline*, and
//  it is where all the subtlety lives:
//
//    · stage into a hidden sibling, so a half-written copy is never mistaken
//      for a document;
//    · sweep the debris a process that died mid-copy left behind;
//    · write the snapshot sidecar **last**, so a directory without one is
//      recognisably unfinished and gets redone rather than trusted;
//    · retire-and-swap with restore-on-failure, so a document readable
//      yesterday is readable today even when today's copy fails half way;
//    · clear the backup exclusion, because pinned bytes are the user's
//      (docs/02-spec.md § Everything is always local);
//    · the whole-second comparison in `isPinnedAndCurrent`, whose absence
//      re-downloads the entire library every fifteen seconds.
//
//  A second transport that wrote its own version of that would give
//  CLAUDE.md non-negotiable 2 two implementations free to drift apart, and the
//  drift would show up as a document that stops opening on a plane. So the
//  discipline is here, once, and both transports call it: `InboxItemPinner`
//  after a provider download, `RemoteDocumentPinner` after an HTTP one.
//  ─────────────────────────────────────────────────────────────────────────────
//

import Foundation
import Core

/// Stages, verifies and commits one document directory inside the app
/// container.
///
/// **On failure:** `beginStaging(forFolderNamed:)` and
/// `commit(staging:snapshot:)` throw
/// `.materialisationFailed(folderName:reason:)` and leave nothing partial
/// behind — the staging directory is the caller's to `discard(_:)`, and any
/// previously pinned copy of that folder is still exactly where it was, byte
/// for byte. The snapshot accessors never throw: an unreadable or absent
/// sidecar reads as "not pinned", which means the document is copied again
/// rather than trusted.
public struct PinnedDocumentWriter: Sendable {

    /// What one pinned directory records about itself.
    ///
    /// Written last and read first: a pinned directory with no snapshot is a
    /// copy that did not finish, and is re-pinned rather than trusted. It lives
    /// in the app container, never in the sync folder — the sync folder is a
    /// published contract and this is our bookkeeping.
    public struct Snapshot: Codable, Sendable, Hashable {

        /// `YYYY-MM-DD-<slug>`.
        public var folderName: String

        /// The source directory's newest modification date at the time of the
        /// copy. What "has this folder been rewritten?" is decided against.
        public var modifiedAt: Date

        /// The **source** directory's total size at the time of the copy, not
        /// the number of bytes copied. The two differ when a directory holds a
        /// file this app does not copy, and comparing the copied total against
        /// a scan would then say "changed" forever.
        public var byteCount: Int64

        /// When the copy completed.
        public var pinnedAt: Date

        /// The file names that were copied, in copy order.
        public var fileNames: [String]

        /// The server's own marker for the revision that was copied, when the
        /// bytes came from a relay rather than a folder.
        ///
        /// **Optional, and it has to stay Optional.** Sidecars written before
        /// this field existed are on devices now, and Swift's synthesised
        /// `Codable` fails the whole decode on an absent non-Optional key — so
        /// a required field here would report every already-pinned document as
        /// unpinned and re-download the library once per install. Nil means
        /// "pinned from a folder, or pinned before this field existed", and
        /// both answer the freshness question by date and size as they always
        /// did.
        public var revision: String?

        public init(
            folderName: String,
            modifiedAt: Date,
            byteCount: Int64,
            pinnedAt: Date,
            fileNames: [String],
            revision: String? = nil
        ) {
            self.folderName = folderName
            self.modifiedAt = modifiedAt
            self.byteCount = byteCount
            self.pinnedAt = pinnedAt
            self.fileNames = fileNames
            self.revision = revision
        }
    }

    /// Where pinned copies live: `DocumentContainer.documentsRoot()` in the
    /// app, a temporary directory in tests. Everything under here is ours to
    /// delete.
    public var destinationRoot: URL

    public init(destinationRoot: URL = PinnedDocumentWriter.defaultDestinationRoot()) {
        self.destinationRoot = destinationRoot
    }

    /// The sidecar's file name. Dot-prefixed so that if a pinned directory is
    /// ever copied back into a sync folder by hand, every watcher ignores it.
    public static let snapshotFileName = ".pinned.json"

    /// `DocumentContainer.documentsRoot()` — the one place a pinned document
    /// lives.
    ///
    /// This used to be a `pinned/` directory of its own, which meant Sync
    /// verified one copy of the bytes and Ingest then made a second one
    /// somewhere else, and the copy Storage recorded was the unverified one.
    /// Pinning straight into the documents root is what makes the path Storage
    /// stores relative, and therefore what makes a document still open after a
    /// reinstall (DocumentContainer.swift header).
    public static func defaultDestinationRoot() -> URL {
        DocumentContainer.documentsRoot()
    }

    // MARK: - Deciding whether there is work

    /// Where a folder's pinned copy lives.
    ///
    /// The same directory `DocumentContainer.documentDirectory(folderName:)`
    /// names, and the same one Ingest materialises into and Storage records
    /// paths relative to. There is one directory per document, not three.
    public func pinnedDirectory(forFolderNamed folderName: String) -> URL {
        destinationRoot.appendingPathComponent(folderName, isDirectory: true)
    }

    /// The snapshot of a completed pin, or nil when there is none — which
    /// includes the case of a directory left behind by a copy that did not
    /// finish.
    public func pinnedSnapshot(forFolderNamed folderName: String) -> Snapshot? {
        let url = pinnedDirectory(forFolderNamed: folderName)
            .appendingPathComponent(PinnedDocumentWriter.snapshotFileName, isDirectory: false)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? ContractCoding.decoder().decode(Snapshot.self, from: data)
    }

    /// Whether a folder is already pinned, complete, and no older than the
    /// source says it is.
    ///
    /// The one question a coordinator asks before doing any work on a folder
    /// the library already knows about. A folder rewritten in place — same
    /// name, newer contents — answers false and is re-ingested.
    ///
    /// - Parameters:
    ///   - folderName: the directory name, which is the identity.
    ///   - modifiedAt: the source's newest modification date.
    ///   - byteCount: the source's total size, or zero when it is unknown.
    public func isPinnedAndCurrent(
        folderName: String,
        modifiedAt: Date,
        byteCount: Int64
    ) -> Bool {
        guard let snapshot = pinnedSnapshot(forFolderNamed: folderName) else { return false }

        // Compare at whole seconds, because that is all the sidecar can hold.
        // `ContractCoding` writes dates as `2026-08-18T18:22:04Z` with no
        // fractional part, so a snapshot written from this very item reads back
        // up to a second *earlier* than the modification date it was taken
        // from — and a straight `<` then calls every pinned document stale, on
        // every scan, for ever. The symptom is not a wrong answer anywhere
        // visible: it is the whole library being re-downloaded, re-copied and
        // re-ingested every fifteen seconds.
        let recorded = snapshot.modifiedAt.timeIntervalSince1970.rounded(.down)
        let scanned = modifiedAt.timeIntervalSince1970.rounded(.down)
        if recorded < scanned { return false }
        if byteCount > 0, snapshot.byteCount != byteCount { return false }
        return true
    }

    /// Whether the pinned copy of a folder is the revision a server just
    /// described.
    ///
    /// The HTTP transport's version of the freshness question, and a much
    /// simpler one: the relay allocates a monotonic sequence number per
    /// document, so an unchanged marker means unchanged bytes and there is
    /// nothing to compare dates about. A pinned directory with no recorded
    /// revision — one pinned from a folder, or before that field existed —
    /// answers false, so it is copied again rather than assumed to match.
    public func isPinnedAndCurrent(folderName: String, revision: String) -> Bool {
        guard let snapshot = pinnedSnapshot(forFolderNamed: folderName) else { return false }
        guard let recorded = snapshot.revision else { return false }
        return recorded == revision
    }

    // MARK: - Staging, committing, discarding

    /// Prepares an empty hidden directory to assemble a copy in.
    ///
    /// Also sweeps the destination root, which is the only moment this module
    /// is certain to reach: a pin interrupted by a crash left a whole copy of a
    /// document inside the documents root, where nothing looks for it and
    /// `DocumentStore.storageBytes()` counts it.
    ///
    /// - Returns: the staging directory. The caller owns it until it is either
    ///   committed or discarded.
    /// - Throws: `.materialisationFailed(folderName:reason:)` when the
    ///   container cannot be prepared at all.
    public func beginStaging(forFolderNamed folderName: String) throws -> URL {
        let manager = FileManager.default
        let staging = destinationRoot.appendingPathComponent(
            SyncFileNames.stagingName(for: folderName, token: UUID().uuidString),
            isDirectory: true
        )
        do {
            try manager.createDirectory(at: destinationRoot, withIntermediateDirectories: true)
            StagingSweeper.sweep(in: destinationRoot)
            try manager.createDirectory(at: staging, withIntermediateDirectories: true)
        } catch {
            throw PencilLoopError.materialisationFailed(
                folderName: folderName,
                reason: "The app's document store could not be prepared. \(error.localizedDescription)"
            )
        }
        return staging
    }

    /// Writes the sidecar, then puts the staging directory where the pinned
    /// copy belongs.
    ///
    /// The sidecar is written last, exactly like `manifest.json` on the way
    /// out: its presence is what makes the directory trustworthy. The
    /// replacement is wholesale, so anything Ingest derived into the previous
    /// directory — a `document.pdf` rendered from markdown, a `sourcemap.json`
    /// — goes with it. That is correct: a re-pin only happens when the source
    /// changed, and the caller re-ingests immediately afterwards, which
    /// regenerates exactly those files (SyncCoordinator.ingest(_:)).
    ///
    /// - Returns: the pinned directory, which is where every URL handed on to
    ///   Ingest must now point.
    /// - Throws: `.materialisationFailed(folderName:reason:)`. The previous
    ///   pinned copy is put back before this throws, so the document that was
    ///   readable a moment ago still is.
    @discardableResult
    public func commit(staging: URL, snapshot: Snapshot) throws -> URL {
        let destination = pinnedDirectory(forFolderNamed: snapshot.folderName)
        do {
            let snapshotURL = staging.appendingPathComponent(
                PinnedDocumentWriter.snapshotFileName,
                isDirectory: false
            )
            try ContractCoding.encoder().encode(snapshot).write(to: snapshotURL, options: [.atomic])
            try swap(staging: staging, into: destination)
        } catch let error as PencilLoopError {
            throw error
        } catch {
            throw PencilLoopError.materialisationFailed(
                folderName: snapshot.folderName,
                reason: error.localizedDescription
            )
        }
        PinnedDocumentWriter.includeInBackup(destination)
        return destination
    }

    /// Throws away a staging directory a copy did not finish with.
    ///
    /// **Never fails.** A staging directory that will not delete is debris the
    /// next sweep collects, and a failed pin must report why it failed rather
    /// than why the cleanup did.
    public func discard(_ staging: URL) {
        try? FileManager.default.removeItem(at: staging)
    }

    // MARK: - Removing

    /// Deletes a pinned copy. Only Storage's purge and a failed re-pin have any
    /// business calling this — pinned bytes are the user's, and the system
    /// never decides to remove them (docs/02-spec.md § S6).
    public func removePinnedCopy(forFolderNamed folderName: String) {
        try? FileManager.default.removeItem(at: pinnedDirectory(forFolderNamed: folderName))
    }

    /// Drops a pinned directory's completion sidecar and nothing else.
    ///
    /// For the case where the copy finished and the *ingest* did not. The bytes
    /// on disk are then in the same position as a half-finished copy — the
    /// library does not reflect them — and `isPinnedAndCurrent` would otherwise
    /// answer true for ever, so the coordinator would skip the folder on every
    /// later scan and the document would never reach the library at all.
    /// Without the sidecar the next scan pins and ingests it again.
    ///
    /// Every file stays exactly where it is, deliberately: a document that was
    /// readable yesterday is still readable today (docs/02-spec.md
    /// § Cross-cutting), whatever went wrong with the newest revision.
    public func invalidateSnapshot(forFolderNamed folderName: String) {
        let url = pinnedDirectory(forFolderNamed: folderName)
            .appendingPathComponent(PinnedDocumentWriter.snapshotFileName, isDirectory: false)
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - Internals

    /// Puts the finished staging directory where the pinned copy belongs,
    /// keeping the previous copy until the new one is in place.
    private func swap(staging: URL, into destination: URL) throws {
        let manager = FileManager.default
        if manager.fileExists(atPath: destination.path) {
            let retired = destinationRoot.appendingPathComponent(
                SyncFileNames.stagingName(for: destination.lastPathComponent, token: "retired-\(UUID().uuidString)"),
                isDirectory: true
            )
            try manager.moveItem(at: destination, to: retired)
            do {
                try manager.moveItem(at: staging, to: destination)
            } catch {
                // Put the previous copy back rather than leaving the document
                // with no bytes at all.
                try? manager.moveItem(at: retired, to: destination)
                throw error
            }
            try? manager.removeItem(at: retired)
            return
        }
        try manager.moveItem(at: staging, to: destination)
    }

    /// `isExcludedFromBackup = false`, per docs/02-spec.md § Everything is
    /// always local. Set through `NSURL` so no mutable resource-values struct
    /// has to be built for one flag.
    private static func includeInBackup(_ url: URL) {
        let reference = url as NSURL
        do {
            try reference.setResourceValue(NSNumber(value: false), forKey: .isExcludedFromBackupKey)
        } catch {
            SyncLog.pin.notice("Could not clear the backup exclusion on \(url.lastPathComponent).")
        }
    }
}
