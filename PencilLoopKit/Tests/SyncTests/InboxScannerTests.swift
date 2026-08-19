//
//  InboxScannerTests.swift
//  SyncTests
//
//  Scanning `inbox/`: what counts as a document, what is skipped, and what
//  happens when `meta.json` is missing or wrong — which per docs/04-flows.md
//  § F1 must be "nothing bad".
//

import XCTest
import Foundation
import Core
@testable import Sync

final class InboxScannerTests: XCTestCase {

    func testScanFindsADirectoryWithAPDF() async throws {
        let temp = try SyncTemporaryFolder()
        defer { temp.removeAll() }
        try temp.writeInboxDirectory(named: "2026-08-18-auth-refactor-plan")

        let items = try await InboxScanner().scan(temp.folder, knownFolderNames: []).items

        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].folderName, "2026-08-18-auth-refactor-plan")
        XCTAssertNotNil(items[0].pdfURL)
        XCTAssertNotNil(items[0].metaURL)
        XCTAssertTrue(items[0].isIngestible)
        XCTAssertGreaterThan(items[0].byteCount, 0)
    }

    func testADirectoryWithNoMetaJSONStillScans() async throws {
        let temp = try SyncTemporaryFolder()
        defer { temp.removeAll() }
        try temp.writeInboxDirectory(named: "2026-08-18-no-metadata", metaJSON: nil)

        let items = try await InboxScanner().scan(temp.folder, knownFolderNames: []).items

        XCTAssertEqual(items.count, 1)
        XCTAssertNil(items[0].metaURL)
        XCTAssertTrue(items[0].isIngestible, "a missing meta.json must never block ingest")
    }

    func testADirectoryWithATruncatedMetaJSONStillScans() async throws {
        let temp = try SyncTemporaryFolder()
        defer { temp.removeAll() }
        try temp.writeInboxDirectory(
            named: "2026-08-18-truncated",
            metaJSON: SyncTemporaryFolder.truncatedMetaJSON
        )

        let items = try await InboxScanner().scan(temp.folder, knownFolderNames: []).items

        XCTAssertEqual(items.count, 1)
        XCTAssertTrue(items[0].isIngestible)
    }

    func testMarkdownWithoutAPDFIsIngestible() async throws {
        let temp = try SyncTemporaryFolder()
        defer { temp.removeAll() }
        try temp.writeInboxDirectory(
            named: "2026-08-18-markdown-only",
            pdf: nil,
            markdown: "# Auth refactor plan\n\nBody.\n"
        )

        let items = try await InboxScanner().scan(temp.folder, knownFolderNames: []).items

        XCTAssertEqual(items.count, 1)
        XCTAssertNil(items[0].pdfURL)
        XCTAssertNotNil(items[0].sourceMarkdownURL)
        XCTAssertTrue(items[0].isIngestible)
    }

    func testADirectoryWithNothingIngestibleIsSkipped() async throws {
        let temp = try SyncTemporaryFolder()
        defer { temp.removeAll() }
        try temp.writeInboxDirectory(named: "2026-08-18-meta-only", pdf: nil)

        let items = try await InboxScanner().scan(temp.folder, knownFolderNames: []).items

        XCTAssertTrue(items.isEmpty, "a folder with only a meta.json is one somebody is still writing")
    }

    func testHiddenStagingDirectoriesAreInvisible() async throws {
        let temp = try SyncTemporaryFolder()
        defer { temp.removeAll() }
        try temp.writeHiddenStagingDirectory(named: ".2026-08-18-plan.4F2C.tmp")
        try temp.writeInboxDirectory(named: "2026-08-18-plan")

        let items = try await InboxScanner().scan(temp.folder, knownFolderNames: []).items

        XCTAssertEqual(items.map { $0.folderName }, ["2026-08-18-plan"])
    }

    func testItemsComeBackInFolderNameOrder() async throws {
        let temp = try SyncTemporaryFolder()
        defer { temp.removeAll() }
        try temp.writeInboxDirectory(named: "2026-08-19-second")
        try temp.writeInboxDirectory(named: "2026-08-17-first")
        try temp.writeInboxDirectory(named: "2026-08-18-middle")

        let items = try await InboxScanner().scan(temp.folder, knownFolderNames: []).items

        XCTAssertEqual(items.map { $0.folderName }, [
            "2026-08-17-first",
            "2026-08-18-middle",
            "2026-08-19-second"
        ])
    }

    func testAKnownFolderIsReportedUntilItHasBeenHandled() async throws {
        let temp = try SyncTemporaryFolder()
        defer { temp.removeAll() }
        try temp.writeInboxDirectory(named: "2026-08-18-known")
        let scanner = InboxScanner()

        let first = try await scanner.scan(temp.folder, knownFolderNames: ["2026-08-18-known"]).items
        let second = try await scanner.scan(temp.folder, knownFolderNames: ["2026-08-18-known"]).items
        let handled = try XCTUnwrap(first.first)
        await scanner.markHandled(handled)
        let third = try await scanner.scan(temp.folder, knownFolderNames: ["2026-08-18-known"]).items

        XCTAssertEqual(first.count, 1, "a cold scanner has no memory, so it reports and lets the pin check decide")
        XCTAssertEqual(
            second.count,
            1,
            "scanning is not handling: nothing has ingested it yet, so it is still outstanding"
        )
        XCTAssertTrue(third.isEmpty, "handled at this modification date, so there is nothing to look at again")
    }

    func testAFolderWhoseIngestFailedIsReportedAgain() async throws {
        let temp = try SyncTemporaryFolder()
        defer { temp.removeAll() }
        try temp.writeInboxDirectory(named: "2026-08-18-broken")
        let scanner = InboxScanner()

        // The coordinator scans, tries to ingest, fails — and therefore never
        // calls `markHandled(_:)`. The next scan has to offer it again, or the
        // retry `InboxItemPinner` promises the user cannot happen at all.
        _ = try await scanner.scan(temp.folder, knownFolderNames: ["2026-08-18-broken"])
        let again = try await scanner.scan(temp.folder, knownFolderNames: ["2026-08-18-broken"]).items

        XCTAssertEqual(again.map { $0.folderName }, ["2026-08-18-broken"])
    }

    func testAKnownFolderRewrittenInPlaceIsReportedAgain() async throws {
        let temp = try SyncTemporaryFolder()
        defer { temp.removeAll() }
        let directory = try temp.writeInboxDirectory(named: "2026-08-18-rewritten")
        let scanner = InboxScanner()
        let first = try await scanner.scan(temp.folder, knownFolderNames: ["2026-08-18-rewritten"]).items
        let handled = try XCTUnwrap(first.first)
        await scanner.markHandled(handled)

        let pdf = directory.appendingPathComponent("document.pdf")
        try Data("%PDF-1.4 regenerated, longer than before".utf8).write(to: pdf)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(60)],
            ofItemAtPath: pdf.path
        )

        let again = try await scanner.scan(temp.folder, knownFolderNames: ["2026-08-18-rewritten"]).items

        XCTAssertEqual(again.map { $0.folderName }, ["2026-08-18-rewritten"])
    }

    func testForgettingSeenFoldersReportsEverythingAgain() async throws {
        let temp = try SyncTemporaryFolder()
        defer { temp.removeAll() }
        try temp.writeInboxDirectory(named: "2026-08-18-known")
        let scanner = InboxScanner()
        let first = try await scanner.scan(temp.folder, knownFolderNames: ["2026-08-18-known"]).items
        let handled = try XCTUnwrap(first.first)
        await scanner.markHandled(handled)

        await scanner.forgetSeenFolders()
        let again = try await scanner.scan(temp.folder, knownFolderNames: ["2026-08-18-known"]).items

        XCTAssertEqual(again.count, 1)
    }

    func testAMissingInboxIsFolderUnavailable() async throws {
        let temp = try SyncTemporaryFolder()
        defer { temp.removeAll() }
        try FileManager.default.removeItem(at: temp.folder.inboxURL)

        do {
            _ = try await InboxScanner().scan(temp.folder, knownFolderNames: [])
            XCTFail("a missing inbox is a folder problem, not an empty result")
        } catch let error as PencilLoopError {
            guard case .folderUnavailable = error else {
                return XCTFail("expected .folderUnavailable, got \(error)")
            }
        }
    }

    func testItemAtReturnsNilForADirectoryWithNothingInIt() async throws {
        let temp = try SyncTemporaryFolder()
        defer { temp.removeAll() }
        let directory = temp.folder.inboxURL.appendingPathComponent("2026-08-18-empty", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let item = try await InboxScanner().item(at: directory)

        XCTAssertNil(item)
    }

    func testFolderNamesListsWhatIsThere() throws {
        let temp = try SyncTemporaryFolder()
        defer { temp.removeAll() }
        try temp.writeInboxDirectory(named: "2026-08-18-one")
        try temp.writeInboxDirectory(named: "2026-08-18-two")
        try temp.writeHiddenStagingDirectory(named: ".2026-08-18-three.tmp")

        let names = InboxScanner.folderNames(in: temp.folder)

        XCTAssertEqual(names, ["2026-08-18-one", "2026-08-18-two"])
    }
}
