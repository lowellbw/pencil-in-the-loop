//
//  NarrationFetcherTests.swift
//  SyncTests
//
//  Collecting a spoken version the relay has made.
//
//  The behaviour worth pinning is what this does *not* do: it must never throw
//  into a scan, never fetch twice, and never leave a directory holding nothing
//  but audio. A document is readable whether or not any of this works.
//

import XCTest
import Foundation
import Core
@testable import Sync

final class NarrationFetcherTests: XCTestCase {

    private var root = URL(fileURLWithPath: "/dev/null")

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = DocumentContainer.documentsRoot()
    }

    override func tearDown() {
        for name in ["2026-08-25-narrated", "2026-08-25-silent"] {
            try? FileManager.default.removeItem(
                at: DocumentContainer.documentDirectory(folderName: name)
            )
        }
        super.tearDown()
    }

    private func makeDocumentDirectory(_ folderName: String) throws {
        try FileManager.default.createDirectory(
            at: DocumentContainer.documentDirectory(folderName: folderName),
            withIntermediateDirectories: true
        )
    }

    private func remote(_ folderName: String, hasNarration: Bool) -> RemoteDocument {
        RemoteDocument(
            folderName: folderName,
            seq: 1,
            files: hasNarration
                ? [RemoteDocument.File(name: "narration.mp3", bytes: 3, sha256: "abc")]
                : [RemoteDocument.File(name: "document.pdf", bytes: 3, sha256: "abc")]
        )
    }

    // MARK: - Presence

    func testAMissingNarrationIsNotThere() throws {
        try makeDocumentDirectory("2026-08-25-silent")

        XCTAssertFalse(NarrationFetcher.hasNarration(forFolderName: "2026-08-25-silent"))
    }

    func testANarrationOnDiskIsFound() throws {
        try makeDocumentDirectory("2026-08-25-narrated")
        try Data("mp3".utf8).write(
            to: NarrationFetcher.narrationURL(forFolderName: "2026-08-25-narrated")
        )

        XCTAssertTrue(NarrationFetcher.hasNarration(forFolderName: "2026-08-25-narrated"))
    }

    func testTheNarrationLivesInTheDocumentsOwnDirectory() {
        // Which is what makes it offline and what makes purge clean it up, with
        // nothing written to achieve either.
        let url = NarrationFetcher.narrationURL(forFolderName: "2026-08-25-narrated")

        XCTAssertEqual(url.lastPathComponent, DocumentFileNames.narration)
        XCTAssertEqual(
            url.deletingLastPathComponent().standardizedFileURL,
            DocumentContainer.documentDirectory(folderName: "2026-08-25-narrated")
                .standardizedFileURL
        )
    }

    // MARK: - Fetching

    func testADocumentWithNoNarrationIsSkipped() async throws {
        try makeDocumentDirectory("2026-08-25-silent")
        let fetcher = NarrationFetcher(client: Self.unreachableClient())

        let fetched = await fetcher.fetch(for: [remote("2026-08-25-silent", hasNarration: false)])

        XCTAssertEqual(fetched, 0)
    }

    func testOneAlreadyOnDiskIsNotFetchedAgain() async throws {
        try makeDocumentDirectory("2026-08-25-narrated")
        try Data("mp3".utf8).write(
            to: NarrationFetcher.narrationURL(forFolderName: "2026-08-25-narrated")
        )
        // An unreachable client: if this tried to fetch, it would fail rather
        // than quietly succeed, and the count would still be zero — so the file
        // is checked afterwards too.
        let fetcher = NarrationFetcher(client: Self.unreachableClient())

        let fetched = await fetcher.fetch(for: [remote("2026-08-25-narrated", hasNarration: true)])

        XCTAssertEqual(fetched, 0)
        XCTAssertEqual(
            try Data(contentsOf: NarrationFetcher.narrationURL(forFolderName: "2026-08-25-narrated")),
            Data("mp3".utf8),
            "the file on disk is untouched"
        )
    }

    func testADocumentThisDeviceDoesNotHaveIsSkipped() async {
        // A narration arriving before its document would otherwise create a
        // directory holding nothing but audio, which reads as a broken
        // document everywhere else in the app.
        let fetcher = NarrationFetcher(client: Self.unreachableClient())

        let fetched = await fetcher.fetch(for: [remote("2026-08-25-narrated", hasNarration: true)])

        XCTAssertEqual(fetched, 0)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: DocumentContainer.documentDirectory(folderName: "2026-08-25-narrated").path
            ),
            "no directory was created for it"
        )
    }

    func testAnUnreachableRelayNeverThrowsIntoTheScan() async throws {
        try makeDocumentDirectory("2026-08-25-narrated")
        let fetcher = NarrationFetcher(client: Self.unreachableClient())

        // The assertion is that this returns at all.
        let fetched = await fetcher.fetch(for: [remote("2026-08-25-narrated", hasNarration: true)])

        XCTAssertEqual(fetched, 0)
        XCTAssertFalse(NarrationFetcher.hasNarration(forFolderName: "2026-08-25-narrated"))
    }

    func testADeletedDocumentIsIgnored() async throws {
        try makeDocumentDirectory("2026-08-25-narrated")
        let tombstone = RemoteDocument(
            folderName: "2026-08-25-narrated",
            seq: 2,
            deletedAt: Date(),
            files: [RemoteDocument.File(name: "narration.mp3", bytes: 3, sha256: "abc")]
        )
        let fetcher = NarrationFetcher(client: Self.unreachableClient())

        let fetched = await fetcher.fetch(for: [tombstone])
        XCTAssertEqual(fetched, 0)
    }

    // MARK: - Fixtures

    /// A client pointed at a port nothing answers on, so every download fails
    /// the way an unreachable relay does.
    private static func unreachableClient() -> SyncServerClient {
        SyncServerClient(
            baseURL: URL(string: "http://127.0.0.1:1") ?? URL(fileURLWithPath: "/"),
            token: "test",
            transport: URLSessionServerTransport(requestTimeout: 1, resourceTimeout: 1)
        )
    }
}
