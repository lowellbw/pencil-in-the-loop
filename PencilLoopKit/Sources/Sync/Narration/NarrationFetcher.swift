//
//  NarrationFetcher.swift
//  Sync · Narration
//
//  Collecting the spoken version of a document, once the relay has made one.
//
//  **Why this is not part of pinning.** A narration is an addition to a bundle
//  that already works: it turns up minutes or days after the document, and a
//  document is not incomplete without one. Putting it in
//  `DocumentFileNames.documentFiles` would have made `RemoteDocumentPinner`
//  fetch it — and that pinner requires `document.pdf` or `source.md` to be
//  present and replaces the whole directory when it runs, so a narration-only
//  update would have been rejected on the way in and destroyed on the next
//  re-pin. Fetching it on its own is smaller and survives both.
//
//  **Offline is not a feature here, it is the shape.** The file lands in the
//  document's own pinned directory, which is never evicted (CLAUDE.md
//  non-negotiable 2) and which `DocumentStore.purgeArchived` deletes whole — so
//  the audio is offline the moment it arrives and cleaned up with the document
//  it belongs to, with nothing written to make either true.
//
//  A re-pin does remove it, because `PinnedDocumentWriter.commit` replaces the
//  directory wholesale. That is survivable and deliberate: the relay still has
//  it, this notices it is missing on the next scan, and fetches it again. It is
//  also why a narration must never be *made* on the device.
//

import Foundation
import os
import Core

/// Downloads narrations the relay has made and the device does not have.
///
/// **On failure:** never throws. A narration that cannot be fetched is a
/// document you read instead of listening to, and it will be tried again on the
/// next scan. Nothing here may stop documents arriving.
public actor NarrationFetcher {

    private static let log = Logger(subsystem: "co.pencil-loop.sync", category: "narration")

    private let client: SyncServerClient

    /// Folder names tried and failed this run, so one unreachable file is not
    /// retried on every poll of a fifteen-second timer. Cleared when the app
    /// restarts, which is the cheapest retry policy that is not "never".
    private var failed: Set<String> = []

    public init(client: SyncServerClient) {
        self.client = client
    }

    /// Fetches any narration named in the feed that is not already on disk.
    ///
    /// - Parameter documents: the change feed's documents, whose `files` list
    ///   already carries the narration — the feed has no allowlist, which is
    ///   what makes this possible without a second request per document.
    /// - Returns: how many were fetched. Zero is the normal answer.
    @discardableResult
    public func fetch(for documents: [RemoteDocument]) async -> Int {
        var fetched = 0
        for document in documents where document.isDeleted == false {
            if Task.isCancelled { break }
            guard failed.contains(document.folderName) == false else { continue }
            guard document.files.contains(where: { $0.name == DocumentFileNames.narration })
            else { continue }

            let destination = DocumentContainer
                .documentDirectory(folderName: document.folderName)
                .appendingPathComponent(DocumentFileNames.narration, isDirectory: false)
            guard FileManager.default.fileExists(atPath: destination.path) == false else {
                continue
            }
            // Only into a directory the document already occupies. A narration
            // arriving before its document would otherwise create a directory
            // holding nothing but audio, which every other part of the app
            // would read as a broken document.
            guard FileManager.default.fileExists(
                atPath: DocumentContainer.documentDirectory(
                    folderName: document.folderName
                ).path
            ) else { continue }

            do {
                try await client.downloadDocumentFile(
                    named: DocumentFileNames.narration,
                    inDocumentNamed: document.folderName,
                    to: destination
                )
                fetched += 1
                NarrationFetcher.log.notice(
                    "Fetched the narration for \(document.folderName, privacy: .public)."
                )
            } catch {
                // Deliberately quiet. The document is readable either way, and
                // an error about audio the reader never asked for is noise.
                failed.insert(document.folderName)
                NarrationFetcher.log.notice(
                    "No narration for \(document.folderName, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
            }
        }
        return fetched
    }

    /// Whether this document has a narration on disk, ready to play offline.
    ///
    /// A `fileExists`, deliberately: the alternative was a column on `Document`
    /// and therefore a schema migration, and the file's own presence is the
    /// only fact anybody needs.
    public nonisolated static func hasNarration(forFolderName folderName: String) -> Bool {
        FileManager.default.fileExists(
            atPath: DocumentContainer
                .documentDirectory(folderName: folderName)
                .appendingPathComponent(DocumentFileNames.narration, isDirectory: false)
                .path
        )
    }

    /// Where a document's narration lives, whether or not it is there yet.
    public nonisolated static func narrationURL(forFolderName folderName: String) -> URL {
        DocumentContainer
            .documentDirectory(folderName: folderName)
            .appendingPathComponent(DocumentFileNames.narration, isDirectory: false)
    }

    /// Forgets this run's failures, so a pull-to-refresh retries them.
    public func retryFailures() {
        failed.removeAll()
    }
}
