//
//  RemoteDocumentPinner.swift
//  Sync · HTTP
//
//  The relay's half of CLAUDE.md non-negotiable 2, and the reason a hosted
//  backend does not turn this app into a fetch-on-open reader.
//
//  ─── THE SEQUENCE, WHICH IS NOT NEGOTIABLE ───────────────────────────────────
//    1. every file the feed declared is downloaded **in full**, to a staging
//       directory inside the app container;
//    2. each one is checked against the size *and* the sha256 the feed
//       declared — a short read and a corrupted read look identical to a
//       reader and neither may become a document;
//    3. only then is the directory committed, sidecar last;
//    4. only then does anything else in the app learn the document exists.
//
//  `DocumentIngesting` is handed URLs inside the container, so by the time
//  Ingest, Storage or the reader sees a document there is no server left in the
//  picture at all. Nothing here is ever called from a reading path, and no
//  document's bytes are ever fetched on demand.
//
//  A mismatch throws and discards the staging directory. **The previous pinned
//  copy is not touched** — not invalidated, not swapped, not removed — because
//  a document that was readable yesterday is readable today whatever the relay
//  is serving now (docs/02-spec.md § Cross-cutting).
//

import Foundation
import Core
import CryptoKit

/// Downloads a relay document in full, verifies it, and pins it into the app
/// container.
///
/// **On failure:** throws `.materialisationFailed(folderName:reason:)` for a
/// download that did not arrive, a size that does not match, a hash that does
/// not match, or a file the server offered without either — and leaves the
/// previously pinned copy of that folder byte for byte as it was. A failed pin
/// costs the *new* revision of a document and nothing else; the row shows as
/// unavailable with the reason, and the next poll tries again.
public struct RemoteDocumentPinner: Sendable {

    /// The relay, already carrying its base URL and token.
    public var client: SyncServerClient

    /// Container discipline, shared with the folder transport so there is one
    /// implementation of "pinned" and not two.
    public var writer: PinnedDocumentWriter

    public init(client: SyncServerClient, writer: PinnedDocumentWriter = PinnedDocumentWriter()) {
        self.client = client
        self.writer = writer
    }

    // MARK: - Deciding whether there is work

    /// Whether the pinned copy is already the revision the feed describes.
    ///
    /// The relay allocates a monotonic sequence number per document, so this is
    /// an equality check rather than a date comparison: an unchanged number
    /// means unchanged bytes.
    public func isPinnedAndCurrent(_ document: RemoteDocument) -> Bool {
        writer.isPinnedAndCurrent(folderName: document.folderName, revision: document.revision)
    }

    /// Where a relay document's pinned copy lives.
    public func pinnedDirectory(for document: RemoteDocument) -> URL {
        writer.pinnedDirectory(forFolderNamed: document.folderName)
    }

    // MARK: - Pinning

    /// Downloads, verifies and pins one document.
    ///
    /// - Returns: the same document as an `InboxItem` whose every URL points
    ///   inside the app container, which is what `DocumentIngesting.ingest(_:)`
    ///   is then handed.
    /// - Throws: `.materialisationFailed(folderName:reason:)`.
    public func pin(_ document: RemoteDocument) async throws -> InboxItem {
        let folderName = document.folderName
        guard document.hasUsableFolderName else {
            throw PencilLoopError.materialisationFailed(
                folderName: folderName,
                reason: "The server sent a folder name this app will not write to disk."
            )
        }
        guard document.isDeleted == false else {
            throw PencilLoopError.materialisationFailed(
                folderName: folderName,
                reason: "It has been deleted on the server."
            )
        }

        let files = document.pinnableFiles
        guard files.contains(where: { $0.name == DocumentFileNames.document })
            || files.contains(where: { $0.name == DocumentFileNames.sourceMarkdown }) else {
            throw PencilLoopError.materialisationFailed(
                folderName: folderName,
                reason: "It contains no document to read."
            )
        }

        let modifiedAt = document.createdAt ?? Date()
        let staging = try writer.beginStaging(forFolderNamed: folderName)

        do {
            var pinnedNames: [String] = []
            var totalBytes: Int64 = 0

            for file in files {
                let target = staging.appendingPathComponent(file.name, isDirectory: false)
                try await client.downloadDocumentFile(
                    named: file.name,
                    inDocumentNamed: folderName,
                    to: target
                )
                let bytes = try verify(file, at: target, folderName: folderName)
                pinnedNames.append(file.name)
                totalBytes += bytes
            }

            let snapshot = PinnedDocumentWriter.Snapshot(
                folderName: folderName,
                modifiedAt: modifiedAt,
                byteCount: totalBytes,
                pinnedAt: Date(),
                fileNames: pinnedNames,
                revision: document.revision
            )
            let destination = try writer.commit(staging: staging, snapshot: snapshot)

            SyncLog.pin.info(
                "Pinned \(folderName) from the relay — \(pinnedNames.count) file(s), \(totalBytes) bytes."
            )
            return RemoteDocumentPinner.item(
                folderName: folderName,
                directory: destination,
                fileNames: pinnedNames,
                modifiedAt: modifiedAt,
                byteCount: totalBytes
            )
        } catch {
            // The staging directory goes; the pinned copy stays exactly where
            // it was. This is the whole reason `commit` is the last step.
            writer.discard(staging)
            if let known = error as? PencilLoopError {
                throw known
            }
            throw PencilLoopError.materialisationFailed(
                folderName: folderName,
                reason: error.localizedDescription
            )
        }
    }

    // MARK: - Verification, as pure functions

    /// Why a downloaded file is not the file that was promised, or nil when it
    /// is.
    ///
    /// Both halves are checked. A truncated download usually fails on size and
    /// a corrupted one on the hash, but a proxy serving a cached older
    /// revision fails only on the hash — and that is precisely the case where
    /// pinning the bytes anyway would put the wrong document in the library
    /// with no sign that anything went wrong.
    public static func mismatchReason(
        for file: RemoteDocument.File,
        downloadedBytes: Int64,
        downloadedHash: String
    ) -> String? {
        guard let expectedBytes = file.bytes, let expectedHash = file.sha256 else {
            return "\(file.name) was offered without a size and checksum, so it cannot be verified."
        }
        if downloadedBytes != expectedBytes {
            return "\(file.name) arrived short — \(downloadedBytes) of \(expectedBytes) bytes."
        }
        if downloadedHash.lowercased() != expectedHash.lowercased() {
            return "\(file.name) does not match its checksum, so the bytes are not the ones that were sent."
        }
        return nil
    }

    /// Lowercase hex SHA-256, 64 characters — the same spelling
    /// `manifest.json` uses, and the same one the relay puts in an `ETag`.
    ///
    /// Exposed rather than private so a test can check a hash without importing
    /// CryptoKit into a test target that is not allowed it, exactly as
    /// `ManifestWriter.sha256Hex(_:)` is.
    public static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    /// The hash of a file on disk.
    ///
    /// Mapped rather than read: the 100MB PDF the relay's own size cap allows
    /// is paged in by the kernel as the hash walks it, and never becomes a
    /// hundred megabytes on this app's heap.
    ///
    /// - Throws: whatever reading the file threw. The caller turns that into
    ///   `.materialisationFailed`.
    public static func sha256Hex(ofFileAt url: URL) throws -> String {
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        return sha256Hex(data)
    }

    // MARK: - Internals

    /// Checks one downloaded file, returning how many bytes it holds.
    private func verify(_ file: RemoteDocument.File, at url: URL, folderName: String) throws -> Int64 {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        let downloadedBytes = Int64(values?.fileSize ?? 0)
        let downloadedHash: String
        do {
            downloadedHash = try RemoteDocumentPinner.sha256Hex(ofFileAt: url)
        } catch {
            throw PencilLoopError.materialisationFailed(
                folderName: folderName,
                reason: "\(file.name) could not be read back after downloading. \(error.localizedDescription)"
            )
        }
        if let reason = RemoteDocumentPinner.mismatchReason(
            for: file,
            downloadedBytes: downloadedBytes,
            downloadedHash: downloadedHash
        ) {
            throw PencilLoopError.materialisationFailed(folderName: folderName, reason: reason)
        }
        return downloadedBytes
    }

    /// The pinned directory, as the thing Ingest is handed.
    ///
    /// Every URL points inside the container. There is deliberately no way to
    /// build one of these that points at a server.
    static func item(
        folderName: String,
        directory: URL,
        fileNames: [String],
        modifiedAt: Date,
        byteCount: Int64
    ) -> InboxItem {
        func url(_ name: String) -> URL? {
            guard fileNames.contains(name) else { return nil }
            return directory.appendingPathComponent(name, isDirectory: false)
        }
        return InboxItem(
            folderName: folderName,
            directoryURL: directory,
            pdfURL: url(DocumentFileNames.document),
            sourceMarkdownURL: url(DocumentFileNames.sourceMarkdown),
            sourceMapURL: url(DocumentFileNames.sourceMap),
            metaURL: url(DocumentFileNames.metadata),
            modifiedAt: modifiedAt,
            byteCount: byteCount
        )
    }
}
