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
//
//  ─── WHAT MOVED, AND WHY IT STILL READS THE SAME ─────────────────────────────
//  Steps 4 to 6 — staging, sweeping, the sidecar written last, retire-and-swap
//  with restore-on-failure, the backup exclusion, and the freshness comparison
//  — are not about iCloud at all, and the relay transport needs every one of
//  them. They live in `PinnedDocumentWriter` (Sync/Pin) and this type calls it.
//  What is left here is the half that genuinely is about a file provider:
//  asking for the download, waiting for the bytes, and the coordinated copy.
//
//  This type's public surface did not change by a character, which is the point
//  — `InboxItemPinnerTests` never learned about the split and is the proof the
//  extraction was behaviour-preserving.
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
    /// The same type both transports write, declared in `PinnedDocumentWriter`
    /// and spelled `InboxItemPinner.Snapshot` here because that is what every
    /// caller and every test already says. One sidecar format, one decoder: a
    /// directory pinned over HTTP and a directory pinned from a folder are the
    /// same directory afterwards, and neither can be told from the other.
    public typealias Snapshot = PinnedDocumentWriter.Snapshot

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
    public static let snapshotFileName = PinnedDocumentWriter.snapshotFileName

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
        PinnedDocumentWriter.defaultDestinationRoot()
    }

    /// The container discipline, which is shared with the relay transport.
    ///
    /// Computed rather than stored because `destinationRoot` is a `var` a
    /// caller may set after construction, and a writer captured at init would
    /// then quietly keep pinning into the old root.
    private var writer: PinnedDocumentWriter {
        PinnedDocumentWriter(destinationRoot: destinationRoot)
    }

    // MARK: - Deciding whether there is work

    /// Where a folder's pinned copy lives.
    ///
    /// The same directory `DocumentContainer.documentDirectory(folderName:)`
    /// names, and the same one Ingest materialises into and Storage records
    /// paths relative to. There is one directory per document, not three.
    public func pinnedDirectory(forFolderNamed folderName: String) -> URL {
        writer.pinnedDirectory(forFolderNamed: folderName)
    }

    /// The snapshot of a completed pin, or nil when there is none — which
    /// includes the case of a directory left behind by a copy that did not
    /// finish.
    public func pinnedSnapshot(forFolderNamed folderName: String) -> Snapshot? {
        writer.pinnedSnapshot(forFolderNamed: folderName)
    }

    /// Whether this item is already pinned, complete, and current.
    ///
    /// The one question the coordinator asks before doing any work on a folder
    /// the library already knows about. A folder rewritten in place — same
    /// name, newer contents — answers false and is re-ingested. The
    /// whole-second comparison that makes this answer true for a folder nobody
    /// touched is in `PinnedDocumentWriter`, with the story of what its absence
    /// costs.
    public func isPinnedAndCurrent(_ item: InboxItem) -> Bool {
        writer.isPinnedAndCurrent(
            folderName: item.folderName,
            modifiedAt: item.modifiedAt,
            byteCount: item.byteCount
        )
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
        let writer = self.writer
        let staging = try writer.beginStaging(forFolderNamed: item.folderName)

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
            let destination = try writer.commit(staging: staging, snapshot: snapshot)

            SyncLog.pin.info("Pinned \(item.folderName) — \(copiedNames.count) file(s), \(copiedBytes) bytes.")
            return InboxItemPinner.rewrite(item, into: destination)
        } catch {
            writer.discard(staging)
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
        writer.removePinnedCopy(forFolderNamed: folderName)
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
        writer.invalidateSnapshot(forFolderNamed: folderName)
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
}
