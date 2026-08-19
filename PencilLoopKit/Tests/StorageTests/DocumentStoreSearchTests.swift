//
//  DocumentStoreSearchTests.swift
//  StorageTests
//
//  docs/02-spec.md § S1: search covers document text *and* recognised
//  handwriting. Both halves are asserted here, because the ink half is the one
//  that silently stops working when the predicate is rewritten.
//

import XCTest
import Foundation
import Core
@testable import Storage

final class DocumentStoreSearchTests: XCTestCase {

    /// Two documents: one whose body mentions the term, one where only the
    /// margin scribble does.
    private func populated() async throws -> DocumentStore {
        let store = try StorageTestFactory.store()

        let paper = StorageTestFactory.ingested(
            title: "Auth refactor plan",
            folderName: "2026-08-18-auth-refactor-plan",
            extractedText: "The refactor replaces the session token with a signed assertion."
        )
        try await store.upsert(paper)

        let latency = StorageTestFactory.ingested(
            title: "Latency budget",
            folderName: "2026-08-19-latency-budget",
            extractedText: "Frames are budgeted at sixteen milliseconds."
        )
        try await store.upsert(latency)
        try await store.saveDrawing(StorageTestFactory.drawingData(), pageIndex: 1, documentId: latency.id)
        try await store.saveRecognisedInk("check the assertion lifetime", pageIndex: 1, documentId: latency.id)

        return store
    }

    func testSearchMatchesExtractedText() async throws {
        let store = try await populated()
        let hits = try await store.summaries(LibraryQuery(searchText: "signed assertion"))
        XCTAssertEqual(hits.map(\.folderName), ["2026-08-18-auth-refactor-plan"])
    }

    func testSearchMatchesTitle() async throws {
        let store = try await populated()
        let hits = try await store.summaries(LibraryQuery(searchText: "latency"))
        XCTAssertEqual(hits.map(\.folderName), ["2026-08-19-latency-budget"])
    }

    func testSearchMatchesRecognisedInk() async throws {
        let store = try await populated()
        let hits = try await store.summaries(LibraryQuery(searchText: "lifetime"))
        XCTAssertEqual(
            hits.map(\.folderName),
            ["2026-08-19-latency-budget"],
            "recognised handwriting is searchable (docs/02-spec.md § S1)"
        )
    }

    func testSearchMatchesTextAndInkTogether() async throws {
        let store = try await populated()
        let hits = try await store.summaries(LibraryQuery(searchText: "assertion"))
        XCTAssertEqual(
            Set(hits.map(\.folderName)),
            ["2026-08-18-auth-refactor-plan", "2026-08-19-latency-budget"],
            "one document matches on its text, the other only on its ink"
        )
    }

    func testSearchIsCaseInsensitive() async throws {
        let store = try await populated()
        let hits = try await store.summaries(LibraryQuery(searchText: "SIGNED ASSERTION"))
        XCTAssertEqual(hits.count, 1)
    }

    func testClearedInkStopsMatching() async throws {
        let store = try await populated()
        let found = try await store.documentId(forFolderName: "2026-08-19-latency-budget")
        let id = try XCTUnwrap(found)

        try await store.saveDrawing(nil, pageIndex: 1, documentId: id)

        let hits = try await store.summaries(LibraryQuery(searchText: "lifetime"))
        XCTAssertTrue(hits.isEmpty, "clearing a page's ink clears its recognised text with it")
    }

    func testEmptySearchTextIsNoFilter() async throws {
        let store = try await populated()
        let blank = try await store.summaries(LibraryQuery(searchText: "   "))
        XCTAssertEqual(blank.count, 2)
    }

    func testArchivedIsHiddenUnlessAskedFor() async throws {
        let store = try await populated()
        let found = try await store.documentId(forFolderName: "2026-08-19-latency-budget")
        let id = try XCTUnwrap(found)
        try await store.setState(.archived, documentId: id)

        let visible = try await store.summaries(.all)
        XCTAssertEqual(visible.map(\.folderName), ["2026-08-18-auth-refactor-plan"])

        let archived = try await store.summaries(LibraryQuery(states: [.archived]))
        XCTAssertEqual(archived.map(\.folderName), ["2026-08-19-latency-budget"])
    }

    /// `extractedText` is a `String` carrying `@Attribute(.externalStorage)`,
    /// which maps to Core Data's `allowsExternalBinaryDataStorage` — an option
    /// defined for binary attributes. SwiftData accepts it here rather than
    /// throwing at container creation, so the schema is fine; what that leaves
    /// open is whether a value big enough to actually be spilled out of the row
    /// is still reachable from the `#Predicate`, or whether search quietly stops
    /// working for exactly the long documents it matters most for.
    ///
    /// Half a megabyte is past any plausible inline threshold. The needle sits
    /// at the far end, so a match cannot come from a truncated prefix.
    func testSearchReachesTextLongEnoughToBeStoredOutsideTheRow() async throws {
        let store = try StorageTestFactory.store()
        let filler = String(repeating: "The frame budget holds. ", count: 22_000)
        try await store.upsert(
            StorageTestFactory.ingested(
                title: "Long paper",
                folderName: "2026-08-20-long-paper",
                extractedText: filler + " The sentinel phrase is pemmican."
            )
        )
        XCTAssertGreaterThan(filler.utf8.count, 500_000)

        let hits = try await store.summaries(LibraryQuery(searchText: "pemmican"))
        XCTAssertEqual(
            hits.map(\.folderName),
            ["2026-08-20-long-paper"],
            "search has to reach text that external storage moved out of the row"
        )
    }

    func testStateFilterNarrowsToOneSection() async throws {
        let store = try await populated()
        let found = try await store.documentId(forFolderName: "2026-08-18-auth-refactor-plan")
        let id = try XCTUnwrap(found)
        try await store.setState(.read, documentId: id)

        let read = try await store.summaries(LibraryQuery(states: [.read]))
        XCTAssertEqual(read.map(\.folderName), ["2026-08-18-auth-refactor-plan"])

        // The fixture inks a page of the latency budget, and a document's first
        // annotation moves it to `.reviewing` (docs/04-flows.md § F2). So the
        // section holding it is Reviewing, and Unread is empty — which is the
        // stronger assertion anyway: a filter that narrows to one section has
        // to be able to return none.
        let reviewing = try await store.summaries(LibraryQuery(states: [.reviewing]))
        XCTAssertEqual(reviewing.map(\.folderName), ["2026-08-19-latency-budget"])

        let unread = try await store.summaries(LibraryQuery(states: [.unread]))
        XCTAssertTrue(unread.isEmpty)
    }

    func testSortOrders() async throws {
        let store = try await populated()

        let newestFirst = try await store.summaries(LibraryQuery(sort: .dateAdded, ascending: false))
        XCTAssertEqual(newestFirst.count, 2)
        let firstAdded = try XCTUnwrap(newestFirst.first?.addedAt)
        let lastAdded = try XCTUnwrap(newestFirst.last?.addedAt)
        XCTAssertGreaterThanOrEqual(firstAdded, lastAdded)

        let oldestFirst = try await store.summaries(LibraryQuery(sort: .dateAdded, ascending: true))
        let firstOfAscending = try XCTUnwrap(oldestFirst.first?.addedAt)
        let lastOfAscending = try XCTUnwrap(oldestFirst.last?.addedAt)
        XCTAssertLessThanOrEqual(
            firstOfAscending,
            lastOfAscending,
            "ascending == true is oldest-first for .dateAdded (DTOs.swift, LibraryQuery.ascending)"
        )
    }

    func testTitleSortIsAToZWhenAscending() async throws {
        let store = try await populated()

        // `LibraryQuery.ascending` is frozen in DTOs.swift: "`true` is
        // oldest-first for `.dateAdded` and A–Z for `.title`". `LibraryModel`
        // passes `ascending: sort == .title` on exactly that reading, so an
        // inverted branch here is a Library that sorts titles backwards.
        let aToZ = try await store.summaries(LibraryQuery(sort: .title, ascending: true))
        XCTAssertEqual(aToZ.map(\.title), ["Auth refactor plan", "Latency budget"])

        let zToA = try await store.summaries(LibraryQuery(sort: .title, ascending: false))
        XCTAssertEqual(zToA.map(\.title), ["Latency budget", "Auth refactor plan"])
    }

    func testAllowedStatesExcludeArchivedByDefault() {
        XCTAssertEqual(
            Set(LibraryFetch.allowedStateRawValues([])),
            Set(DocState.librarySections.map(\.rawValue))
        )
        XCTAssertFalse(LibraryFetch.allowedStateRawValues([]).contains(DocState.archived.rawValue))
        XCTAssertEqual(LibraryFetch.allowedStateRawValues([.read]), ["read"])
    }

    func testSortDescriptorsFollowTheFrozenConvention() {
        // Asserted on the descriptors themselves as well as through a fetch:
        // this half holds whatever SwiftData does with them.
        let titleAscending = LibraryFetch.sortDescriptors(for: LibraryQuery(sort: .title, ascending: true))
        XCTAssertEqual(titleAscending.first?.order, .forward, "A–Z when ascending")

        let titleDescending = LibraryFetch.sortDescriptors(for: LibraryQuery(sort: .title, ascending: false))
        XCTAssertEqual(titleDescending.first?.order, .reverse)

        let dateAscending = LibraryFetch.sortDescriptors(for: LibraryQuery(sort: .dateAdded, ascending: true))
        XCTAssertEqual(dateAscending.first?.order, .forward, "oldest-first when ascending")

        let dateDescending = LibraryFetch.sortDescriptors(for: LibraryQuery(sort: .dateAdded, ascending: false))
        XCTAssertEqual(dateDescending.first?.order, .reverse)
    }

    func testSearchTermIsTrimmed() {
        XCTAssertNil(LibraryFetch.searchTerm(in: LibraryQuery(searchText: nil)))
        XCTAssertNil(LibraryFetch.searchTerm(in: LibraryQuery(searchText: "\n  \t")))
        XCTAssertEqual(LibraryFetch.searchTerm(in: LibraryQuery(searchText: "  ink  ")), "ink")
    }
}
