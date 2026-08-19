//
//  OutboxWriter.swift
//  Sync · Write
//
//  The atomic outbox write (docs/04-flows.md § F5), and the reply read that
//  closes the loop (§ F6).
//
//  ─── WRITE ORDERING, AND WHY IT IS NOT ARBITRARY ─────────────────────────────
//  The bundle is assembled in a hidden sibling `.tmp` directory and renamed
//  into place, so on this device the directory appears whole or not at all.
//
//  That guarantee does not survive the sync hop. A file provider uploads the
//  contents of the renamed directory file by file, and the watcher on the other
//  side sees them arrive one at a time. `integrations/mac-watcher/README.md`
//  § Completeness says exactly what it waits for:
//
//    · `manifest.json` exists and parses as a JSON object;
//    · `review.md` exists;
//    · every file the manifest lists exists;
//    · the directory has stopped changing for `settleSeconds`.
//
//  So this writer puts `manifest.json` last, after every file it lists. In the
//  common case where a provider uploads in write order, the gate cannot open
//  early. In the case where it does not, the manifest's file list closes the
//  hole anyway. Both mechanisms are cheap and neither is sufficient alone.
//  ─────────────────────────────────────────────────────────────────────────────
//

import Foundation
import Core

/// `OutboxWriting`, over a hidden staging directory and a coordinated rename.
///
/// **On failure:** throws `.outboxWriteFailed(reason:)`, having removed the
/// staging directory — nothing partial is left behind, and no half-written
/// bundle ever carries the real name. When the folder is simply unreachable —
/// offline provider, ejected volume — throws `.folderUnavailable(reason:)`, and
/// the caller queues the payload and tells the user "will send when online"
/// rather than reporting a failure (docs/04-flows.md § F7).
public struct OutboxWriter: OutboxWriting {

    public init() {}

    /// - Parameters:
    ///   - payload: the bundle as bytes. This writer does not build, format or
    ///     re-order anything, with the single exception of moving
    ///     `manifest.json` to the end — see the file header.
    ///   - folder: the sync root. The caller must already hold access.
    /// - Returns: where it landed.
    public func write(_ payload: OutboxPayload, to folder: SyncFolder) async throws -> WrittenReview {
        let manager = FileManager.default

        guard OutboxWriter.isDirectory(folder.rootURL) else {
            throw PencilLoopError.folderUnavailable(
                reason: "The sync folder is not reachable, so the review is waiting to be sent."
            )
        }
        do {
            try manager.createDirectory(at: folder.outboxURL, withIntermediateDirectories: true)
        } catch {
            throw PencilLoopError.folderUnavailable(
                reason: "\(SyncFolder.outboxDirectoryName) could not be created. \(error.localizedDescription)"
            )
        }

        // A send interrupted by a crash left a hidden `.tmp` sibling in the
        // user's outbox. Nothing on either side of the folder looks at those, so
        // this is the only place they get cleared up.
        StagingSweeper.sweep(in: folder.outboxURL)

        let finalURL = folder.outboxURL.appendingPathComponent(payload.directoryName, isDirectory: true)
        let stagingURL = folder.outboxURL.appendingPathComponent(
            SyncFileNames.stagingName(for: payload.directoryName, token: UUID().uuidString),
            isDirectory: true
        )

        var byteCount: Int64 = 0
        var fileCount = payload.files.count
        do {
            try manager.createDirectory(at: stagingURL, withIntermediateDirectories: true)

            for file in OutboxWriter.writeOrder(for: payload.files) {
                let target = stagingURL.appendingPathComponent(file.relativePath, isDirectory: false)
                let parent = target.deletingLastPathComponent()
                if parent.path != stagingURL.path {
                    try manager.createDirectory(at: parent, withIntermediateDirectories: true)
                }
                try file.data.write(to: target, options: [.atomic])
                byteCount += Int64(file.data.count)
            }

            // A second review of the same document replaces the first, and the
            // first may already carry an agent's reply. Losing that would lose
            // half a conversation, so it comes across — and it counts, because
            // `WrittenReview` describes the bundle on disk, not the payload.
            if let carried = try OutboxWriter.carryForwardReply(from: finalURL, to: stagingURL) {
                byteCount += carried
                fileCount += 1
            }

            try OutboxWriter.swap(staging: stagingURL, into: finalURL)
        } catch {
            try? manager.removeItem(at: stagingURL)
            throw PencilLoopError.outboxWriteFailed(reason: error.localizedDescription)
        }

        SyncLog.outbox.info("Wrote \(payload.directoryName) — \(fileCount) file(s), \(byteCount) bytes.")
        return WrittenReview(
            documentId: payload.documentId,
            directoryURL: finalURL,
            directoryName: payload.directoryName,
            writtenAt: Date(),
            fileCount: fileCount,
            byteCount: byteCount
        )
    }

    /// Reads `outbox/<directoryName>/reply.md`, if an agent has written one
    /// (docs/04-flows.md § F6).
    ///
    /// - Returns: nil when there is no reply yet. Absence is the normal case
    ///   and is never an error.
    /// - Throws: only when the file exists and cannot be read.
    public func readReply(inReviewDirectory directoryName: String, in folder: SyncFolder) async throws -> String? {
        let url = folder.outboxURL
            .appendingPathComponent(directoryName, isDirectory: true)
            .appendingPathComponent(DocumentFileNames.reply, isDirectory: false)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }

        let data = try CoordinatedFileAccess.read(at: url) { readableURL in
            try Data(contentsOf: readableURL)
        }
        return String(data: data, encoding: .utf8) ?? ""
    }

    // MARK: - Ordering

    /// The payload's files, with `manifest.json` moved to the end.
    ///
    /// Everything else keeps the order the builder chose — the builder knows
    /// which file a reader reaches for first, and this writer does not.
    public static func writeOrder(for files: [BundleFile]) -> [BundleFile] {
        let manifests = files.filter { $0.relativePath == BundleManifest.fileName }
        let rest = files.filter { $0.relativePath != BundleManifest.fileName }
        return rest + manifests
    }

    // MARK: - Internals

    private static func isDirectory(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey])
        return values?.isDirectory == true
    }

    /// Copies an existing `reply.md` into the staging directory, so replacing a
    /// bundle does not discard the reply it already collected.
    ///
    /// - Returns: the bytes copied, or nil when nothing was carried — either
    ///   there was no reply, or the payload already brought one of its own and
    ///   it is counted with the rest of the payload.
    private static func carryForwardReply(from existing: URL, to staging: URL) throws -> Int64? {
        let manager = FileManager.default
        let source = existing.appendingPathComponent(DocumentFileNames.reply, isDirectory: false)
        guard manager.fileExists(atPath: source.path) else { return nil }
        let target = staging.appendingPathComponent(DocumentFileNames.reply, isDirectory: false)
        guard manager.fileExists(atPath: target.path) == false else { return nil }
        try manager.copyItem(at: source, to: target)

        let values = try? target.resourceValues(forKeys: [.fileSizeKey])
        return Int64(values?.fileSize ?? 0)
    }

    /// The rename. Coordinated, so a presenter on the other side is told this
    /// was one move rather than a delete and a create.
    private static func swap(staging: URL, into destination: URL) throws {
        let manager = FileManager.default
        try CoordinatedFileAccess.move(from: staging, to: destination) { movableSource, replaceableDestination in
            if manager.fileExists(atPath: replaceableDestination.path) {
                _ = try manager.replaceItemAt(replaceableDestination, withItemAt: movableSource)
                return
            }
            try manager.moveItem(at: movableSource, to: replaceableDestination)
        }
    }
}
