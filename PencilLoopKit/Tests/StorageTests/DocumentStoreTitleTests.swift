//
//  DocumentStoreTitleTests.swift
//  StorageTests
//
//  Renaming a document (Protocols.swift § DocumentStoring.setTitle).
//
//  A note is made in one tap and starts out called "Note", so renaming is not a
//  power feature here — it is how most notes get their name, from the page menu
//  or from the first sentence somebody wrote. The property worth defending is
//  that a rename touches the *label* and nothing else: `folderName` is the
//  identity every stroke, comment and sent review is filed under, and a rename
//  that moved it would orphan all of them.
//

import XCTest
import Foundation
import Core
@testable import Storage

final class DocumentStoreTitleTests: XCTestCase {

    private func summary(_ id: UUID, in store: DocumentStore) async throws -> DocumentSummary {
        let fetched = try await store.summary(id: id)
        return try XCTUnwrap(fetched)
    }

    func testRenamingShowsOnTheRow() async throws {
        let store = try StorageTestFactory.store()
        let ingested = StorageTestFactory.ingested()
        try await store.upsert(ingested)

        try await store.setTitle("Cutover plan", documentId: ingested.id)

        let after = try await summary(ingested.id, in: store)
        XCTAssertEqual(after.title, "Cutover plan")
    }

    /// The folder name is an identity, not a label.
    func testRenamingDoesNotMoveTheDocument() async throws {
        let store = try StorageTestFactory.store()
        let ingested = StorageTestFactory.ingested()
        try await store.upsert(ingested)

        try await store.setTitle("Cutover plan", documentId: ingested.id)

        let after = try await summary(ingested.id, in: store)
        XCTAssertEqual(after.folderName, ingested.folderName)
        let byFolder = try await store.documentId(forFolderName: ingested.folderName)
        XCTAssertEqual(byFolder, ingested.id, "the folder still finds the document it always did")
    }

    /// A field somebody has just cleared. The old name is a better answer than
    /// a row with no name, and better than an error.
    func testAnEmptyTitleIsIgnored() async throws {
        let store = try StorageTestFactory.store()
        let ingested = StorageTestFactory.ingested(title: "Field notes")
        try await store.upsert(ingested)

        try await store.setTitle("   ", documentId: ingested.id)

        let after = try await summary(ingested.id, in: store)
        XCTAssertEqual(after.title, "Field notes")
    }

    func testTheTitleIsTrimmed() async throws {
        let store = try StorageTestFactory.store()
        let ingested = StorageTestFactory.ingested()
        try await store.upsert(ingested)

        try await store.setTitle("  Cutover plan\n", documentId: ingested.id)

        let after = try await summary(ingested.id, in: store)
        XCTAssertEqual(after.title, "Cutover plan")
    }

    func testRenamingAnUnknownDocumentThrows() async throws {
        let store = try StorageTestFactory.store()

        do {
            try await store.setTitle("Cutover plan", documentId: UUID())
            XCTFail("a write to a missing document throws (Protocols.swift § DocumentStoring)")
        } catch let error as PencilLoopError {
            guard case .documentNotFound = error else {
                return XCTFail("expected .documentNotFound, got \(error)")
            }
        }
    }
}
