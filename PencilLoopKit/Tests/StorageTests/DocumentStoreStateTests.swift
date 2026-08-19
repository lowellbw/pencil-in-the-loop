//
//  DocumentStoreStateTests.swift
//  StorageTests
//
//  docs/04-flows.md § F2: the transition `.unread → .reviewing` happens on the
//  first annotation, **never on open**. That distinction is the whole point of
//  the Library's Reviewing section, and it is one line of code away from being
//  wrong in either direction.
//

import XCTest
import Foundation
import Core
@testable import Storage

final class DocumentStoreStateTests: XCTestCase {

    private func freshDocument() async throws -> (DocumentStore, IngestedDocument) {
        let store = try StorageTestFactory.store()
        let ingested = StorageTestFactory.ingested()
        let summary = try await store.upsert(ingested)
        XCTAssertEqual(summary.state, .unread, "a newly ingested document is Unread")
        return (store, ingested)
    }

    private func state(of id: UUID, in store: DocumentStore) async throws -> DocState {
        let summary = try await store.summary(id: id)
        return try XCTUnwrap(summary).state
    }

    func testOpeningADocumentDoesNotMoveIt() async throws {
        let (store, ingested) = try await freshDocument()

        let detail = try await store.detail(id: ingested.id)
        XCTAssertNotNil(detail)
        try await store.setLastReadPage(2, documentId: ingested.id)
        try await store.addReadingSeconds(90, documentId: ingested.id)

        let after = try await state(of: ingested.id, in: store)
        XCTAssertEqual(after, .unread, "reading is not annotating (docs/04-flows.md § F2)")
    }

    func testFirstCommentMovesItToReviewing() async throws {
        let (store, ingested) = try await freshDocument()

        try await store.addComment(StorageTestFactory.draft(), documentId: ingested.id)

        let after = try await state(of: ingested.id, in: store)
        XCTAssertEqual(after, .reviewing)
    }

    func testFirstDrawingMovesItToReviewing() async throws {
        let (store, ingested) = try await freshDocument()

        try await store.saveDrawing(StorageTestFactory.drawingData(), pageIndex: 0, documentId: ingested.id)

        let after = try await state(of: ingested.id, in: store)
        XCTAssertEqual(after, .reviewing)

        let summary = try await store.summary(id: ingested.id)
        XCTAssertEqual(summary?.hasInk, true)
    }

    func testRecognisedInkAloneDoesNotMoveIt() async throws {
        let (store, ingested) = try await freshDocument()

        try await store.saveRecognisedInk("a margin note", pageIndex: 0, documentId: ingested.id)

        let after = try await state(of: ingested.id, in: store)
        XCTAssertEqual(after, .unread, "recognition is background work, not an annotation")
    }

    func testClearingInkDoesNotMoveIt() async throws {
        let (store, ingested) = try await freshDocument()

        try await store.saveDrawing(nil, pageIndex: 0, documentId: ingested.id)

        let after = try await state(of: ingested.id, in: store)
        XCTAssertEqual(after, .unread)
    }

    func testAnnotatingAReadDocumentLeavesItRead() async throws {
        let (store, ingested) = try await freshDocument()
        try await store.setState(.read, documentId: ingested.id)

        try await store.addComment(StorageTestFactory.draft(), documentId: ingested.id)

        let after = try await state(of: ingested.id, in: store)
        XCTAssertEqual(after, .read, "only .unread is promoted; every other state is the user's choice")
    }

    func testPagesReportInkPerPage() async throws {
        let (store, ingested) = try await freshDocument()

        try await store.saveDrawing(StorageTestFactory.drawingData("page-2"), pageIndex: 2, documentId: ingested.id)
        try await store.saveRecognisedInk("rotate the keys", pageIndex: 2, documentId: ingested.id)

        let pages = try await store.pages(documentId: ingested.id)
        XCTAssertEqual(pages.count, 4)
        XCTAssertEqual(pages.map(\.hasInk), [false, false, true, false])
        XCTAssertEqual(pages[2].recognisedInk, "rotate the keys")
        XCTAssertEqual(pages[2].drawingData, StorageTestFactory.drawingData("page-2"))
        XCTAssertNil(pages[0].drawingData)
        XCTAssertNil(pages[0].recognisedInk, "an untouched page has no recognised text")
    }

    func testClearingInkRemovesTheRecognisedTextToo() async throws {
        let (store, ingested) = try await freshDocument()
        try await store.saveDrawing(StorageTestFactory.drawingData(), pageIndex: 1, documentId: ingested.id)
        try await store.saveRecognisedInk("scribble", pageIndex: 1, documentId: ingested.id)

        try await store.saveDrawing(nil, pageIndex: 1, documentId: ingested.id)

        let pages = try await store.pages(documentId: ingested.id)
        XCTAssertFalse(pages[1].hasInk)
        XCTAssertNil(pages[1].drawingData)
        XCTAssertNil(pages[1].recognisedInk)

        let summary = try await store.summary(id: ingested.id)
        XCTAssertEqual(summary?.hasInk, false)
    }

    func testLocalStateRoundTrips() async throws {
        let (store, ingested) = try await freshDocument()

        try await store.setLocalState(.downloading(progress: 0.25), documentId: ingested.id)
        var summary = try await store.summary(id: ingested.id)
        XCTAssertEqual(summary?.localState, .downloading(progress: 0.25))
        XCTAssertEqual(summary?.isLocal, false)

        try await store.setLocalState(.unavailable(reason: "The folder went away."), documentId: ingested.id)
        summary = try await store.summary(id: ingested.id)
        XCTAssertEqual(summary?.localState, .unavailable(reason: "The folder went away."))

        try await store.setLocalState(.local, documentId: ingested.id)
        summary = try await store.summary(id: ingested.id)
        XCTAssertEqual(summary?.localState, .local)
        XCTAssertEqual(summary?.isLocal, true)
    }
}
