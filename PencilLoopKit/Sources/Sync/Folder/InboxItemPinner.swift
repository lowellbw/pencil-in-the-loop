//
//  InboxItemPinner.swift
//  Sync · Folder
//
//  Full-download-and-pin. This is the file that makes CLAUDE.md non-negotiable
//  2 true, and it is the one most easily reduced to something that looks right
//  and is not.
//
//  ─── WHY A COPY, AND WHY VERIFY ──────────────────────────────────────────────
//  "Documents are downloaded in full on arrival and pinned. They are not
//  fetched on demand, not thumbnails-until-tapped, and never evicted."
//  (docs/02-spec.md § Everything is always local.)
//
//  A file-provider URL is not a file. It is a promise that bytes can be
//  fetched, and the provider is free to evict those bytes whenever it likes.
//  `startDownloadingUbiquitousItem` starts the fetch and returns immediately —
//  it says nothing about whether the bytes arrived. So the sequence here is:
//
//    1. ask for the download,
//    2. wait until the item reports itself downloaded **and** has a size,
//    3. read it under coordination, which blocks until it is materialised,
//    4. copy it into the app's own document directory — the one
//       `DocumentContainer.documentDirectory(folderName:)` names, which is
//       also where Ingest materialises and what Storage records,
//    5. compare the copied byte count against the size the provider reported,
//    6. write the snapshot sidecar last, so a directory without one is
//       recognisably half-copied and gets redone.
//
//  Only after step 6 is the document allowed to become openable. A document
//  that lives only in a provider is one iCloud purge away from being a spinner
//  on a plane, which defeats the entire app.
//  ─────────────────────────────────────────────────────────────────────────────
//

import Foundation
import Core

/// Downloads an inbox directory in full and copies it into the app container.
///
/// **On failure:** throws `.materialisationFailed(folderName:reason:)` — the
/// download did not complete, the copy was short, or the destination could not
/// be written. Nothing partial survives: a failed pin removes its staging
/// directory and leaves any previous pinned copy untouched, so a document that
/// was readable yesterday is still readable today.
///
/// The `InboxItem` this returns has every URL rewritten to point inside the
/// container, which is what `DocumentIngesting.ingest(_:)` is then handed. By
/// the time Ingest sees it there is no file provider left in the picture.
public struct InboxItemPinner: Sendable {

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

        public init(
            folderName: String,
            modifiedAt: Date,
            byteCount: Int64,
            pinnedAt: Date,
            fileNames: [String]
        ) {
            self.folderName = folderName
            self.modifiedAt = modifiedAt
            self.byteCount = byteCount
            self.pinnedAt = pinnedAt
            self.fileNames = fileNames
        }
    }

    /// What the filesystem says about one file's availability.
    ///
    /// Split out from the waiting loop so the decision — "are the bytes here?"
    /// — is a pure function that can be tested without iCloud
    /// (Tests/SyncTests/InboxItemPinnerTests.swift).
    public struct FileStatus: Sendable, Hashable {

        /// True when the item belongs to a file provider at all. A plain local
        /// file is not ubiquitous and is materialised by definition.
        public var isUbiquitous: Bool

        /// True when the provider reports the local copy as current.
        public var isDownloaded: Bool

        /// The provider's own reason for not being able to download, when it
        /// has one. Present means give up rather than keep waiting.
        public var downloadingErrorDescription: String?

        /// Size on disk as reported by the filesystem, when it reports one.
        public var reportedSize: Int64?

        public init(
            isUbiquitous: Bool,
            isDownloaded: Bool,
            downloadingErrorDescription: String? = nil,
            reportedSize: Int64? = nil
        ) {
            self.isUbiquitous = isUbiquitous
            self.isDownloaded = isDownloaded
            self.downloadingErrorDescription = downloadingErrorDescription
            self.reportedSize = reportedSize
        }
    }

    /// Where pinned copies live: `DocumentContainer.documentsRoot()` in the
    /// app, a temporary directory in tests. Everything under here is ours to
    /// delete.
    public var destinationRoot: URL

    /// How long to wait for a provider to finish a download before giving up
    /// and showing an error row. Generous: a 60-page PDF on a slow connection
    /// is still worth waiting for, and the wait never blocks reading or
    /// annotating anything already local (docs/04-flows.md § F7).
    public var materialisationTimeout: TimeInterval

    /// How often to re-ask the filesystem while waiting.
    public var pollInterval: TimeInterval

    public init(
        destinationRoot: URL = InboxItemPinner.defaultDestinationRoot(),
        materialisationTimeout: TimeInterval = InboxItemPinner.defaultMaterialisationTimeout,
        pollInterval: TimeInterval = 0.25
    ) {
        self.destinationRoot = destinationRoot
        self.materialisationTimeout = materialisationTimeout
        self.pollInterval = pollInterval
    }

    /// Two minutes. Long enough for a large document on a poor connection,
    /// short enough that a document the provider will never deliver becomes an
    /// error row rather than a permanent spinner.
    public static let defaultMaterialisationTimeout: TimeInterval = 120

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
            .appendingPathComponent(InboxItemPinner.snapshotFileName, isDirectory: false)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? ContractCoding.decoder().decode(Snapshot.self, from: data)
    }

    /// Whether this item is already pinned, complete, and current.
    ///
    /// The one question the coordinator asks before doing any work on a folder
    /// the library already knows about. A folder rewritten in place — same
    /// name, newer contents — answers false and is re-ingested.
    public func isPinnedAndCurrent(_ item: InboxItem) -> Bool {
        guard let snapshot = pinnedSnapshot(forFolderNamed: item.folderName) else { return false }
        if snapshot.modifiedAt < item.modifiedAt { return false }
        if item.byteCount > 0, snapshot.byteCount != item.byteCount { return false }
        return true
    }

    // MARK: - Pinning

    /// Downloads every file in the item, verifies each one is really here, and
    /// copies the directory into the app container.
    ///
    /// - Parameter item: a scanned inbox directory. The caller must already
    ///   hold access to the sync folder for the whole call, which is why this
    ///   is not wrapped in `withAccess` — it awaits, and that closure cannot.
    /// - Returns: the same item with every URL pointing at the pinned copy.
    /// - Throws: `.materialisationFailed(folderName:reason:)`.
    public func pin(_ item: InboxItem) async throws -> InboxItem {
        let manager = FileManager.default
        let destination = pinnedDirectory(forFolderNamed: item.folderName)
        let staging = destinationRoot.appendingPathComponent(
            SyncFileNames.stagingName(for: item.folderName, token: UUID().uuidString),
            isDirectory: true
        )

        do {
            try manager.createDirectory(at: destinationRoot, withIntermediateDirectories: true)
            // A pin that was interrupted by a crash left its staging directory —
            // a whole copy of a document — inside the documents root, where
            // nothing looks for it and `DocumentStore.storageBytes()` counts it.
            // Sweeping here is the only moment this module is certain to reach.
            StagingSweeper.sweep(in: destinationRoot)
            try manager.createDirectory(at: staging, withIntermediateDirectories: true)
        } catch {
            throw PencilLoopError.materialisationFailed(
                folderName: item.folderName,
                reason: "The app's document store could not be prepared. \(error.localizedDescription)"
            )
        }

        do {
            var copiedNames: [String] = []
            var copiedBytes: Int64 = 0

            for source in InboxItemPinner.sourceFiles(of: item) {
                let name = source.lastPathComponent
                let status = try await materialise(source, folderName: item.folderName)
                let target = staging.appendingPathComponent(name, isDirectory: false)
                let bytes = try copy(from: source, to: target, reportedSize: status.reportedSize, folderName: item.folderName)
                copiedNames.append(name)
                copiedBytes += bytes
            }

            let snapshot = Snapshot(
                folderName: item.folderName,
                modifiedAt: item.modifiedAt,
                byteCount: item.byteCount,
                pinnedAt: Date(),
                fileNames: copiedNames
            )
            // Written last, exactly like `manifest.json` on the way out: the
            // sidecar's presence is what makes the directory trustworthy.
            let snapshotURL = staging.appendingPathComponent(InboxItemPinner.snapshotFileName, isDirectory: false)
            try ContractCoding.encoder().encode(snapshot).write(to: snapshotURL, options: [.atomic])

            try swap(staging: staging, into: destination)
            InboxItemPinner.includeInBackup(destination)

            SyncLog.pin.info("Pinned \(item.folderName) — \(copiedNames.count) file(s), \(copiedBytes) bytes.")
            return InboxItemPinner.rewrite(item, into: destination)
        } catch {
            try? manager.removeItem(at: staging)
            if let known = error as? PencilLoopError {
                throw known
            }
            throw PencilLoopError.materialisationFailed(
                folderName: item.folderName,
                reason: error.localizedDescription
            )
        }
    }

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
    /// library does not reflect them — and `isPinnedAndCurrent(_:)` would
    /// otherwise answer true for ever, so the coordinator would skip the folder
    /// on every later scan and the document would never reach the library at
    /// all. Without the sidecar the next scan pins and ingests it again.
    ///
    /// Every file stays exactly where it is, deliberately: a document that was
    /// readable yesterday is still readable today (docs/02-spec.md
    /// § Cross-cutting), whatever went wrong with the newest revision.
    public func invalidateSnapshot(forFolderNamed folderName: String) {
        let url = pinnedDirectory(forFolderNamed: folderName)
            .appendingPathComponent(InboxItemPinner.snapshotFileName, isDirectory: false)
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - Verification, as pure functions

    /// Whether a status says the bytes are on this device.
    ///
    /// A non-ubiquitous file is local by definition; a ubiquitous one has to
    /// say so itself.
    public static func isMaterialised(_ status: FileStatus) -> Bool {
        if status.isUbiquitous == false { return true }
        return status.isDownloaded
    }

    /// Whether a copy landed whole.
    ///
    /// When the provider reported a size, the copy has to match it exactly.
    /// When it reported nothing, any successful copy counts — a short read
    /// under coordination throws rather than returning truncated bytes.
    public static func isCompleteCopy(reportedSize: Int64?, copiedSize: Int64) -> Bool {
        guard let reportedSize else { return copiedSize >= 0 }
        return reportedSize == copiedSize
    }

    /// What the filesystem currently says about one file.
    public func status(of url: URL) -> FileStatus {
        let values = try? url.resourceValues(forKeys: [
            .isUbiquitousItemKey,
            .ubiquitousItemDownloadingStatusKey,
            .ubiquitousItemDownloadingErrorKey,
            .fileSizeKey
        ])
        var size: Int64?
        if let bytes = values?.fileSize {
            size = Int64(bytes)
        }
        return FileStatus(
            isUbiquitous: values?.isUbiquitousItem ?? false,
            isDownloaded: values?.ubiquitousItemDownloadingStatus == .current,
            downloadingErrorDescription: values?.ubiquitousItemDownloadingError?.localizedDescription,
            reportedSize: size
        )
    }

    // MARK: - Internals

    /// The files worth copying, in the order they are copied.
    static func sourceFiles(of item: InboxItem) -> [URL] {
        var urls: [URL] = []
        if let pdf = item.pdfURL { urls.append(pdf) }
        if let markdown = item.sourceMarkdownURL { urls.append(markdown) }
        if let map = item.sourceMapURL { urls.append(map) }
        if let meta = item.metaURL { urls.append(meta) }
        return urls
    }

    /// The same item, pointing at its pinned copy.
    static func rewrite(_ item: InboxItem, into directory: URL) -> InboxItem {
        func moved(_ url: URL?) -> URL? {
            guard let url else { return nil }
            return directory.appendingPathComponent(url.lastPathComponent, isDirectory: false)
        }
        return InboxItem(
            folderName: item.folderName,
            directoryURL: directory,
            pdfURL: moved(item.pdfURL),
            sourceMarkdownURL: moved(item.sourceMarkdownURL),
            sourceMapURL: moved(item.sourceMapURL),
            metaURL: moved(item.metaURL),
            modifiedAt: item.modifiedAt,
            byteCount: item.byteCount
        )
    }

    /// Asks for the download, then waits for the bytes to actually be here.
    private func materialise(_ url: URL, folderName: String) async throws -> FileStatus {
        let manager = FileManager.default
        do {
            try manager.startDownloadingUbiquitousItem(at: url)
        } catch {
            // Thrown for anything that is not a ubiquitous item, which is the
            // common case for a local folder and not a failure.
            SyncLog.pin.debug("No ubiquitous download for \(url.lastPathComponent); treating it as local.")
        }

        let deadline = Date().addingTimeInterval(materialisationTimeout)
        while true {
            let current = status(of: url)
            if let reason = current.downloadingErrorDescription {
                throw PencilLoopError.materialisationFailed(folderName: folderName, reason: reason)
            }
            if InboxItemPinner.isMaterialised(current) {
                return current
            }
            if Task.isCancelled {
                throw PencilLoopError.materialisationFailed(
                    folderName: folderName,
                    reason: "The download was cancelled."
                )
            }
            if Date() >= deadline {
                throw PencilLoopError.materialisationFailed(
                    folderName: folderName,
                    reason: "\(url.lastPathComponent) did not finish downloading. It will be retried on the next refresh."
                )
            }
            try? await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
        }
    }

    /// Coordinated copy plus the size check that makes it a verification
    /// rather than a hope.
    private func copy(from source: URL, to target: URL, reportedSize: Int64?, folderName: String) throws -> Int64 {
        let manager = FileManager.default
        try CoordinatedFileAccess.read(at: source) { readableURL in
            if manager.fileExists(atPath: target.path) {
                try manager.removeItem(at: target)
            }
            try manager.copyItem(at: readableURL, to: target)
        }

        let values = try? target.resourceValues(forKeys: [.fileSizeKey])
        let copied = Int64(values?.fileSize ?? 0)
        guard InboxItemPinner.isCompleteCopy(reportedSize: reportedSize, copiedSize: copied) else {
            throw PencilLoopError.materialisationFailed(
                folderName: folderName,
                reason: "\(source.lastPathComponent) copied short — \(copied) of \(reportedSize ?? 0) bytes."
            )
        }
        return copied
    }

    /// Puts the finished staging directory where the pinned copy belongs,
    /// keeping the previous copy until the new one is in place.
    ///
    /// The replacement is wholesale, so anything Ingest derived into the
    /// previous directory — a `document.pdf` rendered from markdown, a
    /// `sourcemap.json` — goes with it. That is correct: a re-pin only happens
    /// when the source directory changed, and the caller re-ingests
    /// immediately afterwards, which regenerates exactly those files
    /// (SyncCoordinator.ingest(_:)).
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
