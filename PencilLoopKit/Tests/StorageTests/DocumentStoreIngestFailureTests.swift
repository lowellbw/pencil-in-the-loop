//
//  DocumentStoreIngestFailureTests.swift
//  StorageTests
//
//  What a failed ingest is allowed to do to a document that already exists.
//
//  The rule, from docs/02-spec.md § Cross-cutting: "losing the folder costs you
//  *new* documents, never existing ones". A provider hiccup on Tuesday must not
//  take away a document the user read offline on Monday — and the pinner makes
//  that possible by rolling its previous copy back on failure
//  (`InboxItemPinner.swap(staging:into:)`), so the bytes really are still there.
//  The store is the half that has to not throw them away.
//

import XCTest
import Foundation
import Core
@testable import Storage

final class DocumentStoreIngestFailureTests: XCTestCase {

    private static let folderName = "2026-08-18-auth-refactor-plan"

    func testAFailedRefreshLeavesAReadableDocumentReadable() async throws {
        let directory = try StorageTestFactory.pinBytes(forFolderName: Self.folderName)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = try StorageTestFactory.store()
        let ingested = StorageTestFactory.ingested(folderName: Self.folderName)
        try await store.upsert(ingested)

        try await store.recordIngestFailure(
            folderName: Self.folderName,
            reason: "The download did not finish."
        )

        let summary = try await store.summary(id: ingested.id)
        let row = try XCTUnwrap(summary)
        XCTAssertEqual(
            row.localState,
            .local,
            "the pinned bytes are still on disk, so the row still opens (docs/02-spec.md § S1)"
        )
        XCTAssertTrue(row.isLocal)

        let fetched = try await store.detail(id: ingested.id)
        let detail = try XCTUnwrap(fetched)
        XCTAssertNotNil(detail.pdfURL, "and the reader still has something to open")

        let note = try await store.refreshFailure(forFolderName: Self.folderName)
        XCTAssertEqual(note, "The download did not finish.", "the failure is recorded, not discarded")
    }

    /// The gap this covers: the failure was recorded and no DTO carried it, so
    /// the library could not tell a document that quietly stopped updating from
    /// one that is fine. The only live surfacing was a transient
    /// `SyncEvent.ingestFailed`, gone by the next scan.
    func testAFailedRefreshReachesTheLibraryRow() async throws {
        let directory = try StorageTestFactory.pinBytes(forFolderName: Self.folderName)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = try StorageTestFactory.store()
        let ingested = StorageTestFactory.ingested(folderName: Self.folderName)
        try await store.upsert(ingested)

        try await store.recordIngestFailure(
            folderName: Self.folderName,
            reason: "The download did not finish."
        )

        let fetched = try await store.summary(id: ingested.id)
        let row = try XCTUnwrap(fetched)
        XCTAssertEqual(
            row.refreshFailureReason,
            "The download did not finish.",
            "the row opens and is not current, and only the second half was ever visible"
        )
        XCTAssertTrue(row.isLocal, "and saying so must not dim it")
    }

    func testASucceedingRefreshClearsTheNoteOnTheRowToo() async throws {
        let directory = try StorageTestFactory.pinBytes(forFolderName: Self.folderName)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = try StorageTestFactory.store()
        let ingested = StorageTestFactory.ingested(folderName: Self.folderName)
        try await store.upsert(ingested)
        try await store.recordIngestFailure(folderName: Self.folderName, reason: "A transient failure.")

        try await store.upsert(StorageTestFactory.ingested(folderName: Self.folderName))

        let fetched = try await store.summary(id: ingested.id)
        let row = try XCTUnwrap(fetched)
        XCTAssertNil(row.refreshFailureReason, "the bytes arrived, so the row has nothing to add")
    }

    /// A row with no bytes already says the whole of it in `.unavailable`, and
    /// the store records the same sentence in both places. The row must not read
    /// it out twice in two different voices.
    func testADimmedRowDoesNotAlsoCarryTheRefreshNote() async throws {
        let store = try StorageTestFactory.store()
        let ingested = StorageTestFactory.ingested(folderName: "2026-08-19-never-landed")
        try await store.upsert(ingested)

        try await store.recordIngestFailure(
            folderName: "2026-08-19-never-landed",
            reason: "No document to read."
        )

        let fetched = try await store.summary(id: ingested.id)
        let row = try XCTUnwrap(fetched)
        XCTAssertEqual(row.localState, .unavailable(reason: "No document to read."))
        XCTAssertNil(row.refreshFailureReason)
    }

    func testASucceedingRefreshClearsTheFailureNote() async throws {
        let directory = try StorageTestFactory.pinBytes(forFolderName: Self.folderName)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = try StorageTestFactory.store()
        let ingested = StorageTestFactory.ingested(folderName: Self.folderName)
        try await store.upsert(ingested)
        try await store.recordIngestFailure(folderName: Self.folderName, reason: "A transient failure.")

        try await store.upsert(StorageTestFactory.ingested(folderName: Self.folderName))

        let note = try await store.refreshFailure(forFolderName: Self.folderName)
        XCTAssertNil(note, "the bytes arrived, so the complaint is history")
    }

    func testARowWithNoPinnedBytesStillGoesUnavailable() async throws {
        let store = try StorageTestFactory.store()
        // No `pinBytes` call: this row names a `document.pdf` that is not there,
        // which is the case where dimming the row is the honest answer.
        let ingested = StorageTestFactory.ingested(folderName: "2026-08-19-never-landed")
        try await store.upsert(ingested)

        try await store.recordIngestFailure(
            folderName: "2026-08-19-never-landed",
            reason: "No document to read."
        )

        let summary = try await store.summary(id: ingested.id)
        let row = try XCTUnwrap(summary)
        XCTAssertEqual(row.localState, .unavailable(reason: "No document to read."))
        XCTAssertFalse(row.isLocal)
    }

    func testAFailureForAnUnknownFolderIsStillAnErrorRow() async throws {
        let store = try StorageTestFactory.store()

        try await store.recordIngestFailure(folderName: "2026-08-20-broken", reason: "Unreadable.")

        let rows = try await store.summaries(.all)
        let row = try XCTUnwrap(rows.first { $0.folderName == "2026-08-20-broken" })
        XCTAssertFalse(row.isLocal, "a folder we never ingested has nothing behind it (docs/04-flows.md § F1)")
        XCTAssertEqual(row.localState, .unavailable(reason: "Unreadable."))
    }

    func testAFailureDoesNotDisturbTheReadersMarks() async throws {
        let directory = try StorageTestFactory.pinBytes(forFolderName: Self.folderName)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = try StorageTestFactory.store()
        let ingested = StorageTestFactory.ingested(folderName: Self.folderName)
        try await store.upsert(ingested)
        try await store.addComment(StorageTestFactory.draft(), documentId: ingested.id)
        try await store.setLastReadPage(2, documentId: ingested.id)

        try await store.recordIngestFailure(folderName: Self.folderName, reason: "Provider hiccup.")

        let fetched = try await store.detail(id: ingested.id)
        let detail = try XCTUnwrap(fetched)
        XCTAssertEqual(detail.comments.count, 1)
        XCTAssertEqual(detail.lastReadPage, 2)
        XCTAssertEqual(detail.state, .reviewing)
    }
}
