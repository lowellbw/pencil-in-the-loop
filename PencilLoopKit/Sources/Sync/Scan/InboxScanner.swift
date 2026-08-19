//
//  InboxScanner.swift
//  Sync · Scan
//
//  Walks `inbox/` and says what is in it. It reads directory entries and file
//  sizes; it does not open a PDF, parse markdown or decide whether a document
//  is any good. That is `DocumentIngesting`'s job, and keeping the two apart is
//  what lets a scan run every fifteen seconds without costing anything.
//
//  An actor rather than a struct for one reason: it remembers the modification
//  date at which each folder was last *handled*, which is how a folder that was
//  rewritten in place gets noticed while a folder that has not changed is
//  skipped (Protocols.swift § InboxScanning).
//
//  ─── HANDLED, NOT SEEN ───────────────────────────────────────────────────────
//  That memory is written by `markHandled(_:)`, which the coordinator calls
//  after a folder has been ingested or found already pinned and current — never
//  by `scan` itself. The difference is the whole behaviour: a scan that recorded
//  every item it returned marked a folder seen before anybody had tried to
//  ingest it, so a folder whose first ingest failed was skipped by every later
//  scan in the session and the "it will be retried on the next refresh" the
//  pinner promises was untrue.
//

import Foundation
import Core

/// `InboxScanning`, over `FileManager` and `NSFileCoordinator`.
///
/// **On failure:** throws `.folderUnavailable` when `inbox/` itself cannot be
/// read. A single unreadable subdirectory is skipped and returned in
/// `InboxScanResult.skipped`, never propagated — one bad folder must not stop
/// the scan, and it must not vanish either.
///
/// Scanning is cheap and idempotent. Pull-to-refresh calls it, the watcher
/// calls it, and first launch calls it.
public actor InboxScanner: InboxScanning {

    /// Folder name to the modification date at which it was last handled, as
    /// reported by `markHandled(_:)`.
    ///
    /// In memory only: on a cold start every known folder is reported once, and
    /// the coordinator decides from its pinned copy whether there is anything
    /// to do (`InboxItemPinner.isPinnedAndCurrent(_:)`).
    private var lastHandled: [String: Date] = [:]

    public init() {}

    /// - Parameters:
    ///   - folder: the sync root. The caller must already hold access.
    ///   - knownFolderNames: names already in the library. A known folder is
    ///     skipped only once it has been handled at its current modification
    ///     date — see `markHandled(_:)`. A folder whose ingest failed is
    ///     reported again by the next scan, which is what makes a retry
    ///     possible at all.
    /// - Returns: items in folder-name order, which is chronological given the
    ///   date prefix, plus every subdirectory that could not be read.
    /// - Throws: `.folderUnavailable` when `inbox/` cannot be listed.
    public func scan(_ folder: SyncFolder, knownFolderNames: Set<String>) async throws -> InboxScanResult {
        let entries: [URL]
        do {
            entries = try CoordinatedFileAccess.read(at: folder.inboxURL) { readableURL in
                try FileManager.default.contentsOfDirectory(
                    at: readableURL,
                    includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
                    options: [.skipsHiddenFiles]
                )
            }
        } catch {
            throw PencilLoopError.folderUnavailable(
                reason: "\(SyncFolder.inboxDirectoryName) could not be read. \(error.localizedDescription)"
            )
        }

        var found: [InboxItem] = []
        var skipped: [InboxScanResult.Skipped] = []
        for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let name = entry.lastPathComponent
            if SyncFileNames.isHidden(name) { continue }
            guard InboxScanner.isDirectory(entry) else { continue }

            let item: InboxItem?
            do {
                item = try await self.item(at: entry)
            } catch {
                // One unreadable directory is skipped, never propagated
                // (Protocols.swift § InboxScanning) — and reported, so the
                // coordinator can show an error row rather than nothing.
                SyncLog.scan.error("Skipping \(name): \(error.localizedDescription)")
                skipped.append(
                    InboxScanResult.Skipped(
                        folderName: name,
                        reason: "The folder could not be read. \(error.localizedDescription)"
                    )
                )
                continue
            }
            guard let item else { continue }

            // Known, and already handled at this modification date: nothing to
            // do. Nothing is recorded here — a folder is marked handled by the
            // coordinator once it really has been (see the file header).
            if knownFolderNames.contains(item.folderName),
               let handled = lastHandled[item.folderName],
               handled >= item.modifiedAt {
                continue
            }
            found.append(item)
        }
        return InboxScanResult(items: found, skipped: skipped)
    }

    /// Examines one directory, for the watcher's targeted case.
    ///
    /// - Returns: nil when the directory holds nothing ingestible — no
    ///   `document.pdf` and no `source.md`. A directory with only a `meta.json`
    ///   in it is a directory somebody is still writing.
    /// - Throws: the underlying error when the directory cannot be listed at
    ///   all. Callers scanning a whole inbox catch and skip.
    public func item(at directoryURL: URL) async throws -> InboxItem? {
        let contents = try CoordinatedFileAccess.read(at: directoryURL) { readableURL in
            try FileManager.default.contentsOfDirectory(
                at: readableURL,
                includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .isDirectoryKey],
                options: []
            )
        }

        var byName: [String: URL] = [:]
        var newest = InboxScanner.modificationDate(of: directoryURL) ?? Date(timeIntervalSince1970: 0)
        var bytes: Int64 = 0

        for file in contents {
            let name = file.lastPathComponent
            if SyncFileNames.isHidden(name) { continue }
            byName[name] = file
            if let modified = InboxScanner.modificationDate(of: file), modified > newest {
                newest = modified
            }
            bytes += InboxScanner.byteCount(of: file)
        }

        let item = InboxItem(
            folderName: directoryURL.lastPathComponent,
            directoryURL: directoryURL,
            pdfURL: byName[DocumentFileNames.document],
            sourceMarkdownURL: byName[DocumentFileNames.sourceMarkdown],
            sourceMapURL: byName[DocumentFileNames.sourceMap],
            metaURL: byName[DocumentFileNames.metadata],
            modifiedAt: newest,
            byteCount: bytes
        )
        guard item.isIngestible else { return nil }
        return item
    }

    /// Records that a folder has been dealt with at the modification date the
    /// item carries, so later scans may skip it until it changes again.
    ///
    /// The coordinator calls it after an ingest succeeds, and for a folder it
    /// found already pinned and current. It deliberately does **not** call it
    /// for a folder that failed: an ingest failure is temporary until proven
    /// otherwise, and a folder nobody has handled has to keep coming back
    /// (`InboxItemPinner` promises the user exactly that).
    public func markHandled(_ item: InboxItem) {
        lastHandled[item.folderName] = item.modifiedAt
    }

    /// Forgets what this scanner has handled, so the next scan reports every
    /// folder again.
    ///
    /// The coordinator calls it when the folder comes back after being
    /// unavailable, because anything could have happened while we were not
    /// looking, and on every `refresh()`, because pull-to-refresh is the user
    /// asking for exactly that.
    public func forgetSeenFolders() {
        lastHandled.removeAll()
    }

    /// Every directory name currently in `inbox/`.
    ///
    /// Synchronous, total, and the set `Slug.disambiguated(_:existing:)` is
    /// given whenever this app writes a new directory of its own — a reply
    /// opened as a document, or an item imported from the share extension's
    /// staging area. An unreadable inbox answers with an empty set rather than
    /// failing: the worst case is a name collision, and
    /// `Slug.disambiguated(_:existing:)` is what protects against that.
    ///
    /// - Parameter folder: the sync root. The caller must already hold access.
    public static func folderNames(in folder: SyncFolder) -> Set<String> {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: folder.inboxURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        return Set(
            entries
                .map { $0.lastPathComponent }
                .filter { SyncFileNames.isHidden($0) == false }
        )
    }

    // MARK: - Internals

    private static func isDirectory(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey])
        return values?.isDirectory == true
    }

    private static func modificationDate(of url: URL) -> Date? {
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
        return values?.contentModificationDate
    }

    private static func byteCount(of url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        guard let size = values?.fileSize else { return 0 }
        return Int64(size)
    }
}
