//
//  SyncTestIngester.swift
//  SyncTests
//
//  A `DocumentIngesting` that records what it was handed and can be told to
//  fail for one folder, so the "shows an error row rather than vanishing"
//  behaviour has something to fail against.
//
//  It also asserts, on every call, the guarantee the real ingester relies on:
//  by the time Sync hands an item over, every URL in it is inside the pinned
//  directory and every file behind those URLs exists.
//

import Foundation
import Core
@testable import Sync

/// An ingester that turns any item into a plausible document.
actor SyncTestIngester: DocumentIngesting {

    /// Every item this ingester was handed, in order.
    private(set) var received: [InboxItem] = []

    /// Folder names that should fail, and why.
    private var failures: [String: String] = [:]

    init() {}

    /// Makes `ingest(_:)` throw for one folder.
    func fail(folderName: String, reason: String) {
        failures[folderName] = reason
    }

    /// Stops it throwing for that folder — a transient failure that has passed.
    func succeed(folderName: String) {
        failures[folderName] = nil
    }

    /// How many times one folder was handed over.
    func attempts(forFolderName folderName: String) -> Int {
        received.filter { $0.folderName == folderName }.count
    }

    func ingest(_ item: InboxItem) async throws -> IngestedDocument {
        received.append(item)
        if let reason = failures[item.folderName] {
            throw PencilLoopError.unreadableDocument(folderName: item.folderName, reason: reason)
        }
        let metadata = await self.metadata(at: item.directoryURL)
        let title = metadata.title ?? item.folderName
        return IngestedDocument(
            id: metadata.uuid ?? UUID(),
            externalId: metadata.id,
            title: title,
            folderName: item.folderName,
            relativePath: "\(SyncFolder.inboxDirectoryName)/\(item.folderName)",
            pdfURL: item.pdfURL ?? item.directoryURL.appendingPathComponent("document.pdf"),
            sourceMarkdownURL: item.sourceMarkdownURL,
            sourceMap: nil,
            origin: metadata.resolvedOrigin,
            sourceFormat: metadata.sourceFormat ?? .unknown,
            pageCount: metadata.pageCount ?? 1,
            extractedText: "",
            createdAt: metadata.createdAt ?? item.modifiedAt,
            addedAt: Date()
        )
    }

    func metadata(at url: URL) async -> DocumentMetadata {
        MetadataFile.read(inDirectory: url)
    }

    /// Whether every URL this ingester was handed pointed at a file that
    /// existed — the "fully downloaded and pinned" half of the contract.
    func everyReceivedFileExists() -> Bool {
        for item in received {
            let urls = [item.pdfURL, item.sourceMarkdownURL, item.sourceMapURL, item.metaURL].compactMap { $0 }
            for url in urls where FileManager.default.fileExists(atPath: url.path) == false {
                return false
            }
        }
        return true
    }

    /// Whether every item was handed over from inside the given directory,
    /// rather than from the sync folder.
    func everyReceivedItemIsUnder(_ root: URL) -> Bool {
        received.allSatisfy { $0.directoryURL.path.hasPrefix(root.path) }
    }
}
