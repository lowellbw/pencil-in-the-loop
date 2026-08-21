//
//  DocumentStorePinTests.swift
//  StorageTests
//
//  docs/02-spec.md § S1: pinning keeps a document at the top of the Library.
//
//  The property worth defending here is that pinning is **orthogonal to
//  `DocState`**. It would have been cheaper to add a fourth state, and it would
//  have been wrong: pinning a document would then forget whether it had been
//  read, and un-pinning would have to guess where to put it back. These tests
//  are what stops that shortcut being taken later.
//

import XCTest
import Foundation
import Core
@testable import Storage

final class DocumentStorePinTests: XCTestCase {

    private func freshDocument() async throws -> (DocumentStore, IngestedDocument) {
        let store = try StorageTestFactory.store()
        let ingested = StorageTestFactory.ingested()
        let summary = try await store.upsert(ingested)
        XCTAssertFalse(summary.isPinned, "a newly ingested document is not pinned")
        return (store, ingested)
    }

    private func summary(_ id: UUID, in store: DocumentStore) async throws -> DocumentSummary {
        // Bound before unwrapping: `XCTUnwrap` takes an autoclosure, which
        // cannot carry the `await` into the actor.
        let fetched = try await store.summary(id: id)
        return try XCTUnwrap(fetched)
    }

    func testPinningIsVisibleOnTheRow() async throws {
        let (store, ingested) = try await freshDocument()

        try await store.setPinned(true, documentId: ingested.id)

        let after = try await summary(ingested.id, in: store)
        XCTAssertTrue(after.isPinned)
    }

    func testUnpinningPutsItBack() async throws {
        let (store, ingested) = try await freshDocument()

        try await store.setPinned(true, documentId: ingested.id)
        try await store.setPinned(false, documentId: ingested.id)

        let after = try await summary(ingested.id, in: store)
        XCTAssertFalse(after.isPinned)
    }

    /// The whole reason `pinnedAt` is a column of its own rather than a fourth
    /// `DocState`.
    func testPinningDoesNotChangeTheReadingState() async throws {
        let (store, ingested) = try await freshDocument()
        try await store.addComment(StorageTestFactory.draft(), documentId: ingested.id)
        let before = try await summary(ingested.id, in: store)
        XCTAssertEqual(before.state, .reviewing, "annotating moved it (docs/04-flows.md § F2)")

        try await store.setPinned(true, documentId: ingested.id)
        let pinned = try await summary(ingested.id, in: store)
        XCTAssertEqual(pinned.state, .reviewing, "pinning is not a state change")

        try await store.setPinned(false, documentId: ingested.id)
        let unpinned = try await summary(ingested.id, in: store)
        XCTAssertEqual(unpinned.state, .reviewing, "and neither is un-pinning")
    }

    /// A double tap on the swipe action must not rewrite `pinnedAt` and quietly
    /// reorder the Pinned section under the user's finger.
    func testPinningTwiceDoesNotMoveIt() async throws {
        let (store, ingested) = try await freshDocument()

        try await store.setPinned(true, documentId: ingested.id)
        let first = try await store.pinnedAt(documentId: ingested.id)
        XCTAssertNotNil(first)

        try await store.setPinned(true, documentId: ingested.id)
        let second = try await store.pinnedAt(documentId: ingested.id)
        XCTAssertEqual(first, second, "pinning a pinned document is a no-op")
    }

    /// Un-pinning clears the date rather than remembering it, so the column
    /// cannot lie to a future sort.
    func testUnpinningClearsThePinTime() async throws {
        let (store, ingested) = try await freshDocument()

        try await store.setPinned(true, documentId: ingested.id)
        try await store.setPinned(false, documentId: ingested.id)

        let after = try await store.pinnedAt(documentId: ingested.id)
        XCTAssertNil(after)
    }

    func testPinningAnUnknownDocumentThrows() async throws {
        let store = try StorageTestFactory.store()

        do {
            try await store.setPinned(true, documentId: UUID())
            XCTFail("a write to a missing document throws (Protocols.swift § DocumentStoring)")
        } catch let error as PencilLoopError {
            guard case .documentNotFound = error else {
                return XCTFail("expected .documentNotFound, got \(error)")
            }
        }
    }

    func testPinningSurvivesAReIngest() async throws {
        let (store, ingested) = try await freshDocument()
        try await store.setPinned(true, documentId: ingested.id)

        // The same document re-sent: the source was regenerated, the reader's
        // marks were not — and a pin is one of the reader's marks.
        try await store.upsert(StorageTestFactory.ingested(id: ingested.id, title: "Auth refactor plan v2"))

        let after = try await summary(ingested.id, in: store)
        XCTAssertEqual(after.title, "Auth refactor plan v2", "the document did update")
        XCTAssertTrue(after.isPinned, "and it stayed pinned")
    }
}
