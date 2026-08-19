//
//  DocumentStoreCommentTests.swift
//  StorageTests
//
//  Comments, their anchors, their order, and the soft delete that makes
//  "nothing is destructive without undo" true (docs/02-spec.md § Cross-cutting).
//

import XCTest
import Foundation
import Core
@testable import Storage

final class DocumentStoreCommentTests: XCTestCase {

    func testAddCommentMintsIdAndTimestampAndRoundTripsTheAnchor() async throws {
        let store = try StorageTestFactory.store()
        let ingested = StorageTestFactory.ingested()
        try await store.upsert(ingested)

        let draft = StorageTestFactory.draft(
            text: "Say why this is safer than a refresh token.",
            source: .voice,
            quoted: "a signed assertion",
            pageIndex: 1,
            y: 0.4,
            sourceRange: SourceRange(start: 1204, end: 1268)
        )
        let before = Date()
        let snapshot = try await store.addComment(draft, documentId: ingested.id)

        XCTAssertEqual(snapshot.text, draft.text)
        XCTAssertEqual(snapshot.source, .voice)
        XCTAssertEqual(snapshot.resolvedOnPage, 1)
        XCTAssertGreaterThanOrEqual(snapshot.createdAt, before)
        XCTAssertEqual(snapshot.anchor, draft.anchor, "the anchor survives its trip through the columns")
        XCTAssertEqual(snapshot.anchor.sourceRange, SourceRange(start: 1204, end: 1268))
        XCTAssertEqual(snapshot.anchor.normalisedRect.y, 0.4, accuracy: 0.000_001)

        let stored = try await store.comments(documentId: ingested.id)
        XCTAssertEqual(stored, [snapshot])
    }

    func testAnchorWithoutASourceRangeStaysNil() async throws {
        let store = try StorageTestFactory.store()
        let ingested = StorageTestFactory.ingested(withMarkdown: false)
        try await store.upsert(ingested)

        let snapshot = try await store.addComment(StorageTestFactory.draft(), documentId: ingested.id)
        XCTAssertNil(snapshot.anchor.sourceRange, "an imported PDF has no source map and no range")
    }

    func testCommentsComeBackInDocumentOrder() async throws {
        let store = try StorageTestFactory.store()
        let ingested = StorageTestFactory.ingested()
        try await store.upsert(ingested)

        try await store.addComment(
            StorageTestFactory.draft(text: "third", pageIndex: 2, y: 0.1),
            documentId: ingested.id
        )
        try await store.addComment(
            StorageTestFactory.draft(text: "second", pageIndex: 0, y: 0.8),
            documentId: ingested.id
        )
        try await store.addComment(
            StorageTestFactory.draft(text: "first", pageIndex: 0, y: 0.2),
            documentId: ingested.id
        )

        let order = try await store.comments(documentId: ingested.id).map(\.text)
        XCTAssertEqual(order, ["first", "second", "third"], "page, then vertical position")
    }

    func testUpdateCommentEditsTheText() async throws {
        let store = try StorageTestFactory.store()
        let ingested = StorageTestFactory.ingested()
        try await store.upsert(ingested)
        let snapshot = try await store.addComment(StorageTestFactory.draft(), documentId: ingested.id)

        try await store.updateComment(id: snapshot.id, text: "Rewritten in the review sheet.")

        let stored = try await store.comments(documentId: ingested.id)
        XCTAssertEqual(stored.count, 1)
        XCTAssertEqual(stored.first?.text, "Rewritten in the review sheet.")
        XCTAssertEqual(stored.first?.id, snapshot.id, "editing does not mint a new comment")
        XCTAssertEqual(stored.first?.createdAt, snapshot.createdAt)
    }

    func testUpdatingAnUnknownCommentThrows() async throws {
        let store = try StorageTestFactory.store()
        let id = UUID()
        do {
            try await store.updateComment(id: id, text: "nothing to edit")
            XCTFail("expected commentNotFound")
        } catch let error as PencilLoopError {
            XCTAssertEqual(error, PencilLoopError.commentNotFound(id: id))
        }
    }

    func testDeleteIsSoftAndUndoRestoresTheSameComment() async throws {
        let store = try StorageTestFactory.store()
        let ingested = StorageTestFactory.ingested()
        try await store.upsert(ingested)
        let snapshot = try await store.addComment(StorageTestFactory.draft(), documentId: ingested.id)

        try await store.deleteComment(id: snapshot.id)

        var visible = try await store.comments(documentId: ingested.id)
        XCTAssertTrue(visible.isEmpty, "a deleted comment is not readable")
        var summary = try await store.summary(id: ingested.id)
        XCTAssertEqual(summary?.commentCount, 0, "and it does not count")
        let pending = await store.undoableCommentDeletionCount
        XCTAssertEqual(pending, 1)

        let restored = try await store.undoLastCommentDeletion()

        XCTAssertEqual(restored, snapshot, "undo restores the original id, timestamp and anchor")
        visible = try await store.comments(documentId: ingested.id)
        XCTAssertEqual(visible, [snapshot])
        summary = try await store.summary(id: ingested.id)
        XCTAssertEqual(summary?.commentCount, 1)
        let empty = await store.undoableCommentDeletionCount
        XCTAssertEqual(empty, 0)
    }

    func testUndoIsLastInFirstOut() async throws {
        let store = try StorageTestFactory.store()
        let ingested = StorageTestFactory.ingested()
        try await store.upsert(ingested)
        let first = try await store.addComment(
            StorageTestFactory.draft(text: "first", y: 0.1),
            documentId: ingested.id
        )
        let second = try await store.addComment(
            StorageTestFactory.draft(text: "second", y: 0.2),
            documentId: ingested.id
        )

        try await store.deleteComment(id: first.id)
        try await store.deleteComment(id: second.id)

        let firstUndo = try await store.undoLastCommentDeletion()
        XCTAssertEqual(firstUndo?.text, "second")
        let secondUndo = try await store.undoLastCommentDeletion()
        XCTAssertEqual(secondUndo?.text, "first")
        let nothingLeft = try await store.undoLastCommentDeletion()
        XCTAssertNil(nothingLeft, "an empty undo stack is an answer, not a failure")
    }

    func testEditingADeletedCommentThrows() async throws {
        let store = try StorageTestFactory.store()
        let ingested = StorageTestFactory.ingested()
        try await store.upsert(ingested)
        let snapshot = try await store.addComment(StorageTestFactory.draft(), documentId: ingested.id)
        try await store.deleteComment(id: snapshot.id)

        do {
            try await store.updateComment(id: snapshot.id, text: "should not land")
            XCTFail("expected commentNotFound")
        } catch let error as PencilLoopError {
            XCTAssertEqual(error, PencilLoopError.commentNotFound(id: snapshot.id))
        }
    }

    func testDiscardingUndoHistoryRemovesTheRowsForGood() async throws {
        let store = try StorageTestFactory.store()
        let ingested = StorageTestFactory.ingested()
        try await store.upsert(ingested)
        let snapshot = try await store.addComment(StorageTestFactory.draft(), documentId: ingested.id)
        try await store.deleteComment(id: snapshot.id)

        let removed = try await store.discardCommentUndoHistory()
        XCTAssertEqual(removed, 1)

        let nothing = try await store.undoLastCommentDeletion()
        XCTAssertNil(nothing)
        let visible = try await store.comments(documentId: ingested.id)
        XCTAssertTrue(visible.isEmpty)
    }

    func testDeletingADocumentsCommentsDoesNotTouchAnother() async throws {
        let store = try StorageTestFactory.store()
        let first = StorageTestFactory.ingested(folderName: "2026-08-18-first")
        let second = StorageTestFactory.ingested(title: "Second", folderName: "2026-08-19-second")
        try await store.upsert(first)
        try await store.upsert(second)

        let kept = try await store.addComment(StorageTestFactory.draft(text: "kept"), documentId: second.id)
        let doomed = try await store.addComment(StorageTestFactory.draft(text: "doomed"), documentId: first.id)
        try await store.deleteComment(id: doomed.id)

        let survivors = try await store.comments(documentId: second.id)
        XCTAssertEqual(survivors, [kept])
    }
}
