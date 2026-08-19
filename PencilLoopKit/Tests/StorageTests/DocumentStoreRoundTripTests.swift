//
//  DocumentStoreRoundTripTests.swift
//  StorageTests
//
//  Insert, then read back through the DTOs. These are the tests that would have
//  caught a mapping written in only one direction.
//

import XCTest
import Foundation
import Core
@testable import Storage

final class DocumentStoreRoundTripTests: XCTestCase {

    func testUpsertThenSummaryRoundTrips() async throws {
        let store = try StorageTestFactory.store()
        let ingested = StorageTestFactory.ingested()

        let inserted = try await store.upsert(ingested)

        XCTAssertEqual(inserted.id, ingested.id)
        XCTAssertEqual(inserted.title, "Auth refactor plan")
        XCTAssertEqual(inserted.folderName, ingested.folderName)
        XCTAssertEqual(inserted.pageCount, 4)
        XCTAssertEqual(inserted.state, .unread)
        XCTAssertEqual(inserted.localState, .local)
        XCTAssertTrue(inserted.isLocal)
        XCTAssertEqual(inserted.commentCount, 0)
        XCTAssertFalse(inserted.hasInk)
        XCTAssertEqual(inserted.originDisplayName, OriginKind.cowork.displayName)
        XCTAssertEqual(inserted.addedAt, ingested.addedAt)

        let fetched = try await store.summary(id: ingested.id)
        XCTAssertEqual(fetched, inserted)

        let rows = try await store.summaries(.all)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.id, ingested.id)
    }

    func testDetailCarriesEverythingTheReaderNeeds() async throws {
        let store = try StorageTestFactory.store()
        let map = SourceMap(entries: [
            SourceMap.Entry(
                pageIndex: 0,
                rect: NormalisedRect(x: 0.1, y: 0.2, width: 0.6, height: 0.02),
                range: SourceRange(start: 1204, end: 1268)
            )
        ])
        let ingested = StorageTestFactory.ingested(sourceMap: map)
        try await store.upsert(ingested)

        let fetched = try await store.detail(id: ingested.id)
        let detail = try XCTUnwrap(fetched)

        XCTAssertEqual(detail.id, ingested.id)
        XCTAssertEqual(detail.title, ingested.title)
        XCTAssertEqual(detail.folderName, ingested.folderName)
        XCTAssertEqual(detail.pdfURL?.lastPathComponent, "document.pdf")
        XCTAssertEqual(detail.pdfURL?.standardizedFileURL, ingested.pdfURL.standardizedFileURL)
        XCTAssertEqual(detail.sourceMarkdownURL?.lastPathComponent, "source.md")
        XCTAssertEqual(detail.extractedText, ingested.extractedText)
        XCTAssertEqual(detail.pageCount, 4)
        XCTAssertEqual(detail.lastReadPage, 0)
        XCTAssertEqual(detail.origin.kind, .cowork)
        XCTAssertEqual(detail.origin.sessionId, "session_1")
        XCTAssertEqual(detail.origin.threadTitle, "Q3 platform planning")
        XCTAssertEqual(detail.sourceMap?.entries.count, 1)
        XCTAssertEqual(detail.sourceMap?.entries.first?.range, SourceRange(start: 1204, end: 1268))
        XCTAssertEqual(detail.pages.count, 4, "every page has a snapshot, inked or not")
        XCTAssertEqual(detail.pages.map(\.pageIndex), [0, 1, 2, 3])
        XCTAssertTrue(detail.comments.isEmpty)
    }

    func testDetailIsNilForAnUnknownDocument() async throws {
        let store = try StorageTestFactory.store()
        let missing = try await store.detail(id: UUID())
        XCTAssertNil(missing)
        let unknownSummary = try await store.summary(id: UUID())
        XCTAssertNil(unknownSummary)
    }

    func testWritingToAnUnknownDocumentThrows() async throws {
        let store = try StorageTestFactory.store()
        let id = UUID()
        do {
            try await store.setState(.read, documentId: id)
            XCTFail("expected documentNotFound")
        } catch let error as PencilLoopError {
            XCTAssertEqual(error, PencilLoopError.documentNotFound(id: id))
        }
    }

    func testKnownFolderNamesAndFolderLookup() async throws {
        let store = try StorageTestFactory.store()
        let first = StorageTestFactory.ingested(folderName: "2026-08-18-auth-refactor-plan")
        let second = StorageTestFactory.ingested(
            title: "Latency budget",
            folderName: "2026-08-19-latency-budget"
        )
        try await store.upsert(first)
        try await store.upsert(second)

        let names = try await store.knownFolderNames()
        XCTAssertEqual(names, ["2026-08-18-auth-refactor-plan", "2026-08-19-latency-budget"])

        let id = try await store.documentId(forFolderName: "2026-08-19-latency-budget")
        XCTAssertEqual(id, second.id)
        let unknownFolder = try await store.documentId(forFolderName: "2026-01-01-nothing")
        XCTAssertNil(unknownFolder)
    }

    func testReIngestUpdatesInPlaceAndKeepsMarks() async throws {
        let store = try StorageTestFactory.store()
        let ingested = StorageTestFactory.ingested()
        try await store.upsert(ingested)
        try await store.addComment(StorageTestFactory.draft(), documentId: ingested.id)
        try await store.saveDrawing(StorageTestFactory.drawingData(), pageIndex: 2, documentId: ingested.id)
        try await store.setLastReadPage(3, documentId: ingested.id)

        // The same folder, regenerated: new id, new title, more pages.
        let regenerated = StorageTestFactory.ingested(
            id: UUID(),
            title: "Auth refactor plan (v2)",
            pageCount: 6,
            extractedText: "Now with a section on key rotation."
        )
        let summary = try await store.upsert(regenerated)

        XCTAssertEqual(summary.id, ingested.id, "the existing row keeps its id — comments point at it")
        XCTAssertEqual(summary.title, "Auth refactor plan (v2)")
        XCTAssertEqual(summary.pageCount, 6)
        XCTAssertEqual(summary.commentCount, 1, "comments survive a re-ingest")
        XCTAssertTrue(summary.hasInk, "ink survives a re-ingest")

        let rows = try await store.summaries(.all)
        XCTAssertEqual(rows.count, 1, "a re-sent document must not become a duplicate")

        let fetchedDetail = try await store.detail(id: ingested.id)
        let detail = try XCTUnwrap(fetchedDetail)
        XCTAssertEqual(detail.extractedText, "Now with a section on key rotation.")
        XCTAssertEqual(detail.lastReadPage, 3, "reading position survives")
        XCTAssertEqual(detail.state, .reviewing, "so does the state the annotation put it in")
    }

    func testTheSameDocumentUnderANewFolderNameMovesTheRow() async throws {
        let store = try StorageTestFactory.store()
        let monday = StorageTestFactory.ingested(folderName: "2026-08-18-auth-refactor-plan")
        try await store.upsert(monday)

        // The same plan, sent again tomorrow: same `meta.json` id, new
        // `YYYY-MM-DD-` prefix, so `upsert` matches the row by id.
        let tuesday = StorageTestFactory.ingested(
            id: monday.id,
            folderName: "2026-08-19-auth-refactor-plan"
        )
        let summary = try await store.upsert(tuesday)

        XCTAssertEqual(summary.id, monday.id, "it is the same document")
        XCTAssertEqual(
            summary.folderName,
            "2026-08-19-auth-refactor-plan",
            "the row names the folder the document is in now"
        )

        let rows = try await store.summaries(.all)
        XCTAssertEqual(rows.count, 1, "re-sending is not duplicating")

        let known = try await store.knownFolderNames()
        XCTAssertEqual(
            known,
            ["2026-08-19-auth-refactor-plan"],
            "or the scanner treats the new folder as new for ever"
        )

        let matched = try await store.documentId(forFolderName: "2026-08-19-auth-refactor-plan")
        XCTAssertEqual(
            matched,
            monday.id,
            "a reply.md in <new folder>.review has to find its way back (SyncCoordinator.collectReplies)"
        )
        let stale = try await store.documentId(forFolderName: "2026-08-18-auth-refactor-plan")
        XCTAssertNil(stale, "the folder it used to be in holds nothing now")
    }

    func testIngestFailureLeavesAnErrorRowRatherThanNothing() async throws {
        let store = try StorageTestFactory.store()
        try await store.recordIngestFailure(folderName: "2026-08-20-broken", reason: "No document to read.")

        let rows = try await store.summaries(.all)
        let row = try XCTUnwrap(rows.first { $0.folderName == "2026-08-20-broken" })
        XCTAssertFalse(row.isLocal)
        XCTAssertEqual(row.localState, .unavailable(reason: "No document to read."))
        XCTAssertEqual(row.title, "2026-08-20-broken")
    }

    func testLastReadPageIsClampedIntoRange() async throws {
        let store = try StorageTestFactory.store()
        let ingested = StorageTestFactory.ingested(pageCount: 4)
        try await store.upsert(ingested)

        try await store.setLastReadPage(99, documentId: ingested.id)
        let high = try await store.detail(id: ingested.id)
        XCTAssertEqual(try XCTUnwrap(high).lastReadPage, 3)

        try await store.setLastReadPage(-5, documentId: ingested.id)
        let low = try await store.detail(id: ingested.id)
        XCTAssertEqual(try XCTUnwrap(low).lastReadPage, 0)
    }

    func testReadingSecondsAccumulate() async throws {
        let store = try StorageTestFactory.store()
        let ingested = StorageTestFactory.ingested()
        try await store.upsert(ingested)

        try await store.addReadingSeconds(45, documentId: ingested.id)
        try await store.addReadingSeconds(75, documentId: ingested.id)
        try await store.addReadingSeconds(-10, documentId: ingested.id)

        let total = try await store.readingSeconds(documentId: ingested.id)
        XCTAssertEqual(total, 120, accuracy: 0.001)
    }

    func testReviewLifecycleIsRecorded() async throws {
        let store = try StorageTestFactory.store()
        let ingested = StorageTestFactory.ingested()
        try await store.upsert(ingested)

        let sentAt = Date(timeIntervalSince1970: 1_770_100_000)
        try await store.recordReviewSent(
            documentId: ingested.id,
            at: sentAt,
            directoryName: OutboxPayload.directoryName(forDocumentFolder: ingested.folderName)
        )
        let sentSummary = try await store.summary(id: ingested.id)
        let summary = try XCTUnwrap(sentSummary)
        XCTAssertEqual(summary.state, .read, "sending a review moves the document to Read")

        try await store.recordReply(
            documentId: ingested.id,
            text: "Rotated the keys, see the diff.",
            receivedAt: Date(timeIntervalSince1970: 1_770_200_000)
        )
    }
}
