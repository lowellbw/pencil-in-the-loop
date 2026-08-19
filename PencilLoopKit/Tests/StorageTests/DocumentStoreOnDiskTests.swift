//
//  DocumentStoreOnDiskTests.swift
//  StorageTests
//
//  Every other test in this target uses `DocumentStore.inMemory()`, which means
//  the store the app actually runs — a SQLite file on disk, with a migration
//  plan — has never been exercised by a test at all. SwiftData does not
//  translate every predicate the same way against both backings, and a
//  container that opens in memory can still refuse to open on disk.
//
//  `LibraryContainer.make(url:)` has always taken an override "for tests that
//  want a real file on disk". Nothing had ever passed one.
//

import XCTest
import Foundation
import SwiftData
import Core
@testable import Storage

final class DocumentStoreOnDiskTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        try super.tearDownWithError()
    }

    private func onDiskStore() throws -> DocumentStore {
        let container = try LibraryContainer.make(
            url: directory.appendingPathComponent("Library.store", isDirectory: false)
        )
        return DocumentStore.make(container: container)
    }

    /// The container the app opens at launch. If this fails, every screen fails
    /// with it and `RootModel` shows one sentence instead of a library.
    func testTheRealContainerOpensOnDisk() throws {
        XCTAssertNoThrow(try onDiskStore())
    }

    /// The write that happens on every arriving document.
    func testADocumentCanBeUpsertedAndReadBackFromDisk() async throws {
        let store = try onDiskStore()
        let ingested = StorageTestFactory.ingested(
            title: "Auth refactor plan",
            folderName: "2026-08-18-auth-refactor-plan"
        )

        try await store.upsert(ingested)

        let summaries = try await store.summaries(.all)
        XCTAssertEqual(summaries.map(\.folderName), ["2026-08-18-auth-refactor-plan"])
    }

    /// Re-ingest keyed on `folderName`, which is what a re-sent document does.
    func testUpsertingTwiceKeepsOneRow() async throws {
        let store = try onDiskStore()
        try await store.upsert(StorageTestFactory.ingested(folderName: "2026-08-18-once"))
        try await store.upsert(StorageTestFactory.ingested(folderName: "2026-08-18-once"))

        let summaries = try await store.summaries(.all)
        XCTAssertEqual(summaries.count, 1)
    }

    /// The predicate `LibraryFetch` builds, against real SQLite rather than the
    /// in-memory backing every other test uses. This is the one most likely to
    /// behave differently, and the file's own header warns about exactly that
    /// class of predicate.
    func testSearchWorksAgainstTheOnDiskStore() async throws {
        let store = try onDiskStore()
        try await store.upsert(
            StorageTestFactory.ingested(
                title: "Latency budget",
                folderName: "2026-08-19-latency-budget",
                extractedText: "Frames are budgeted at sixteen milliseconds."
            )
        )

        let hits = try await store.summaries(LibraryQuery(searchText: "sixteen"))
        XCTAssertEqual(hits.map(\.folderName), ["2026-08-19-latency-budget"])
    }

    /// `@Attribute(.externalStorage)` on a `String` again, but this time with a
    /// file behind it — the case where external storage really does move bytes
    /// out of the row.
    func testSearchReachesExternallyStoredTextOnDisk() async throws {
        let store = try onDiskStore()
        let filler = String(repeating: "The frame budget holds. ", count: 22_000)
        try await store.upsert(
            StorageTestFactory.ingested(
                title: "Long paper",
                folderName: "2026-08-20-long-paper",
                extractedText: filler + " The sentinel phrase is pemmican."
            )
        )

        let hits = try await store.summaries(LibraryQuery(searchText: "pemmican"))
        XCTAssertEqual(hits.map(\.folderName), ["2026-08-20-long-paper"])
    }

    /// A row recorded for a document that never arrived, which is what the sync
    /// coordinator writes when an ingest fails.
    func testAnIngestFailureCanBeRecordedOnDisk() async throws {
        let store = try onDiskStore()
        try await store.recordIngestFailure(
            folderName: "2026-08-18-never-landed",
            reason: "The download did not finish."
        )

        let summaries = try await store.summaries(.all)
        XCTAssertEqual(summaries.count, 1)
        XCTAssertEqual(summaries.first?.localState, .unavailable(reason: "The download did not finish."))
    }

    /// Growing a notebook, from the store's point of view: the same folder
    /// re-ingested with more pages.
    ///
    /// The assertion that matters is the ink. `apply(_:to:)` says the source
    /// was regenerated and the reader's marks were not, and adding paper to a
    /// notebook is the first thing in the app that relies on it being true —
    /// a stroke lost here is somebody's handwriting, which cannot be recovered
    /// from anywhere.
    func testAddingPagesLeavesEarlierInkByteIdentical() async throws {
        let store = try onDiskStore()
        let strokes = Data([0x50, 0x4B, 0x01, 0x02, 0xFF, 0x00, 0x7A])

        let created = try await store.upsert(
            StorageTestFactory.ingested(folderName: "2026-08-19-working-notes", pageCount: 2)
        )
        try await store.saveDrawing(strokes, pageIndex: 1, documentId: created.id)

        _ = try await store.upsert(
            StorageTestFactory.ingested(
                id: created.id, folderName: "2026-08-19-working-notes", pageCount: 6
            )
        )

        let after = try await store.drawingData(pageIndex: 1, documentId: created.id)
        XCTAssertEqual(after, strokes, "growing the notebook rewrote somebody's handwriting")

        let summaries = try await store.summaries(.all)
        XCTAssertEqual(summaries.count, 1, "growing made a second row rather than growing the one")
        XCTAssertEqual(summaries.first?.pageCount, 6)
    }

    /// Reopening the same file is what a relaunch does, and the point of a
    /// store being on disk at all.
    func testWhatWasWrittenSurvivesReopeningTheStore() async throws {
        let url = directory.appendingPathComponent("Library.store", isDirectory: false)

        let first = DocumentStore.make(container: try LibraryContainer.make(url: url))
        try await first.upsert(StorageTestFactory.ingested(folderName: "2026-08-18-persisted"))

        let second = DocumentStore.make(container: try LibraryContainer.make(url: url))
        let summaries = try await second.summaries(.all)
        XCTAssertEqual(summaries.map(\.folderName), ["2026-08-18-persisted"])
    }
}
