//
//  DocumentStoreHousekeepingTests.swift
//  StorageTests
//
//  Purging archived documents is the only operation in the app that removes a
//  document's bytes (docs/02-spec.md § S6), so it is worth being sure it removes
//  the right ones and nothing else.
//
//  These tests write real files into the app's documents root — that is the
//  behaviour under test — and clean up after themselves.
//

import XCTest
import Foundation
import Core
@testable import Storage

final class DocumentStoreHousekeepingTests: XCTestCase {

    private var folderNames: [String] = []

    override func tearDown() {
        for name in folderNames {
            try? FileManager.default.removeItem(at: StorageLocations.documentDirectory(folderName: name))
        }
        folderNames = []
        super.tearDown()
    }

    /// Materialises a document's bytes the way Ingest would, and returns the DTO
    /// that describes them.
    private func pinnedDocument(folderName: String, bytes: Int) throws -> IngestedDocument {
        folderNames.append(folderName)
        let directory = StorageLocations.documentDirectory(folderName: folderName)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(repeating: 0x50, count: bytes)
            .write(to: directory.appendingPathComponent("document.pdf"))
        return StorageTestFactory.ingested(title: folderName, folderName: folderName, withMarkdown: false)
    }

    func testPurgeRemovesArchivedDocumentsAndTheirBytes() async throws {
        let store = try StorageTestFactory.store()
        let keep = try pinnedDocument(folderName: "2026-08-18-purge-keep", bytes: 4096)
        let drop = try pinnedDocument(folderName: "2026-08-19-purge-drop", bytes: 8192)
        try await store.upsert(keep)
        try await store.upsert(drop)
        try await store.setState(.archived, documentId: drop.id)

        let freed = try await store.purgeArchived()

        XCTAssertEqual(freed, 8192)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: StorageLocations.documentDirectory(folderName: "2026-08-19-purge-drop")
                    .path(percentEncoded: false)
            ),
            "the archived document's pinned bytes are gone"
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: StorageLocations.documentDirectory(folderName: "2026-08-18-purge-keep")
                    .path(percentEncoded: false)
            ),
            "and nothing else was touched"
        )

        let rows = try await store.summaries(LibraryQuery(states: Set(DocState.allCases)))
        XCTAssertEqual(rows.map(\.folderName), ["2026-08-18-purge-keep"])
    }

    func testPurgeWithNothingArchivedFreesNothing() async throws {
        let store = try StorageTestFactory.store()
        try await store.upsert(StorageTestFactory.ingested(folderName: "2026-08-20-nothing-archived"))

        let freed = try await store.purgeArchived()

        XCTAssertEqual(freed, 0, "zero is a normal answer")
        let rows = try await store.summaries(.all)
        XCTAssertEqual(rows.count, 1)
    }

    func testStorageBytesCountsTheAppContainer() async throws {
        let store = try StorageTestFactory.store()
        let document = try pinnedDocument(folderName: "2026-08-21-storage-bytes", bytes: 16_384)
        try await store.upsert(document)

        let bytes = try await store.storageBytes()

        XCTAssertGreaterThanOrEqual(bytes, 16_384, "the pinned document is counted")
    }
}
