//
//  InboxItemPinnerTests.swift
//  SyncTests
//
//  Download-and-pin. The waiting loop needs a file provider and cannot be
//  tested here; the two decisions it makes — "are the bytes here?" and "did the
//  copy land whole?" — are pure functions and are tested directly, which is
//  most of the value.
//
//  What to check by hand on device, because no test here can:
//
//    · Send a document from Cowork, put the iPad in aeroplane mode before it
//      finishes syncing, and confirm the row shows an error rather than a
//      spinner, and that a later refresh recovers it.
//    · Ingest a document, then evict it from iCloud Drive (Files.app →
//      Remove Download), then open it offline. It must open. If it does not,
//      the copy into the container is not happening and nothing else in this
//      file matters.
//

import XCTest
import Foundation
import Core
@testable import Sync

final class InboxItemPinnerTests: XCTestCase {

    // MARK: - The two decisions

    func testALocalFileIsMaterialisedByDefinition() {
        let status = InboxItemPinner.FileStatus(isUbiquitous: false, isDownloaded: false)

        XCTAssertTrue(InboxItemPinner.isMaterialised(status))
    }

    func testAProviderItemIsNotMaterialisedUntilItSaysSo() {
        let placeholder = InboxItemPinner.FileStatus(isUbiquitous: true, isDownloaded: false, reportedSize: 4_000_000)
        let downloaded = InboxItemPinner.FileStatus(isUbiquitous: true, isDownloaded: true, reportedSize: 4_000_000)

        XCTAssertFalse(
            InboxItemPinner.isMaterialised(placeholder),
            "a directory entry is not bytes; this is the whole point of the pin step"
        )
        XCTAssertTrue(InboxItemPinner.isMaterialised(downloaded))
    }

    func testAShortCopyIsNotAComplete() {
        XCTAssertTrue(InboxItemPinner.isCompleteCopy(reportedSize: 1024, copiedSize: 1024))
        XCTAssertFalse(InboxItemPinner.isCompleteCopy(reportedSize: 1024, copiedSize: 1023))
        XCTAssertFalse(InboxItemPinner.isCompleteCopy(reportedSize: 1024, copiedSize: 0))
    }

    func testACopyWithNoReportedSizeIsAccepted() {
        XCTAssertTrue(
            InboxItemPinner.isCompleteCopy(reportedSize: nil, copiedSize: 0),
            "an empty source.md is legitimate; a coordinated read throws rather than truncating"
        )
    }

    // MARK: - Pinning

    func testPinCopiesEveryFileIntoTheContainer() async throws {
        let temp = try SyncTemporaryFolder()
        defer { temp.removeAll() }
        try temp.writeInboxDirectory(
            named: "2026-08-18-auth-refactor-plan",
            markdown: "# Auth refactor plan\n",
            sourceMapJSON: "{\"version\":1,\"entries\":[]}"
        )
        let pinner = InboxItemPinner(destinationRoot: temp.pinnedRootURL)
        let scanned = try await InboxScanner().item(
            at: temp.folder.inboxURL.appendingPathComponent("2026-08-18-auth-refactor-plan", isDirectory: true)
        )
        let item = try XCTUnwrap(scanned)

        let pinned = try await pinner.pin(item)

        XCTAssertTrue(pinned.directoryURL.path.hasPrefix(temp.pinnedRootURL.path))
        for url in [pinned.pdfURL, pinned.sourceMarkdownURL, pinned.sourceMapURL, pinned.metaURL] {
            let unwrapped = try XCTUnwrap(url)
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: unwrapped.path),
                "\(unwrapped.lastPathComponent) is not in the container, so the document is not local"
            )
        }
    }

    func testPinnedBytesSurviveTheSourceGoingAway() async throws {
        let temp = try SyncTemporaryFolder()
        defer { temp.removeAll() }
        let directory = try temp.writeInboxDirectory(named: "2026-08-18-purged")
        let pinner = InboxItemPinner(destinationRoot: temp.pinnedRootURL)
        let scannedItem = try await InboxScanner().item(at: directory)
        let item = try XCTUnwrap(scannedItem)
        let pinned = try await pinner.pin(item)

        // What an iCloud purge looks like from the app's side.
        try FileManager.default.removeItem(at: directory)

        let pdf = try XCTUnwrap(pinned.pdfURL)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: pdf.path),
            "a document that stops opening when the folder goes away defeats the entire app"
        )
    }

    func testASnapshotIsWrittenAndSaysWhatWasCopied() async throws {
        let temp = try SyncTemporaryFolder()
        defer { temp.removeAll() }
        let directory = try temp.writeInboxDirectory(named: "2026-08-18-snapshot")
        let pinner = InboxItemPinner(destinationRoot: temp.pinnedRootURL)
        let scannedItem = try await InboxScanner().item(at: directory)
        let item = try XCTUnwrap(scannedItem)

        _ = try await pinner.pin(item)
        let snapshot = try XCTUnwrap(pinner.pinnedSnapshot(forFolderNamed: "2026-08-18-snapshot"))

        XCTAssertEqual(snapshot.folderName, "2026-08-18-snapshot")
        XCTAssertEqual(snapshot.fileNames.sorted(), ["document.pdf", "meta.json"])
        XCTAssertGreaterThan(snapshot.byteCount, 0)
    }

    func testADirectoryWithNoSnapshotIsNotTrusted() async throws {
        let temp = try SyncTemporaryFolder()
        defer { temp.removeAll() }
        let directory = try temp.writeInboxDirectory(named: "2026-08-18-half-copied")
        let pinner = InboxItemPinner(destinationRoot: temp.pinnedRootURL)
        let scannedItem = try await InboxScanner().item(at: directory)
        let item = try XCTUnwrap(scannedItem)
        _ = try await pinner.pin(item)

        // A copy that died before its sidecar was written looks exactly like
        // this, and must be redone rather than trusted.
        try FileManager.default.removeItem(
            at: pinner.pinnedDirectory(forFolderNamed: "2026-08-18-half-copied")
                .appendingPathComponent(InboxItemPinner.snapshotFileName)
        )

        XCTAssertNil(pinner.pinnedSnapshot(forFolderNamed: "2026-08-18-half-copied"))
        XCTAssertFalse(pinner.isPinnedAndCurrent(item))
    }

    func testInvalidatingASnapshotKeepsEveryByte() async throws {
        let temp = try SyncTemporaryFolder()
        defer { temp.removeAll() }
        let directory = try temp.writeInboxDirectory(named: "2026-08-18-ingest-failed")
        let pinner = InboxItemPinner(destinationRoot: temp.pinnedRootURL)
        let scannedItem = try await InboxScanner().item(at: directory)
        let item = try XCTUnwrap(scannedItem)
        _ = try await pinner.pin(item)

        // The copy landed and the ingest did not, so the library does not
        // reflect this directory: it must be pinned and ingested again rather
        // than skipped as current.
        pinner.invalidateSnapshot(forFolderNamed: "2026-08-18-ingest-failed")

        XCTAssertFalse(pinner.isPinnedAndCurrent(item), "an unreflected copy is not one to skip")
        let pinned = pinner.pinnedDirectory(forFolderNamed: "2026-08-18-ingest-failed")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: pinned.appendingPathComponent("document.pdf").path),
            "the bytes are the user's: a document readable yesterday is readable today"
        )
    }

    func testAFolderRewrittenInPlaceIsNoLongerCurrent() async throws {
        let temp = try SyncTemporaryFolder()
        defer { temp.removeAll() }
        let directory = try temp.writeInboxDirectory(named: "2026-08-18-regenerated")
        let pinner = InboxItemPinner(destinationRoot: temp.pinnedRootURL)
        let scanner = InboxScanner()
        let scannedItem = try await scanner.item(at: directory)
        let item = try XCTUnwrap(scannedItem)
        _ = try await pinner.pin(item)
        XCTAssertTrue(pinner.isPinnedAndCurrent(item))

        let rewritten = InboxItem(
            folderName: item.folderName,
            directoryURL: item.directoryURL,
            pdfURL: item.pdfURL,
            metaURL: item.metaURL,
            modifiedAt: item.modifiedAt.addingTimeInterval(60),
            byteCount: item.byteCount + 128
        )

        XCTAssertFalse(pinner.isPinnedAndCurrent(rewritten))
    }

    func testRepinningReplacesTheCopy() async throws {
        let temp = try SyncTemporaryFolder()
        defer { temp.removeAll() }
        let directory = try temp.writeInboxDirectory(named: "2026-08-18-twice")
        let pinner = InboxItemPinner(destinationRoot: temp.pinnedRootURL)
        let scanner = InboxScanner()
        let scannedFirst = try await scanner.item(at: directory)
        let first = try XCTUnwrap(scannedFirst)
        _ = try await pinner.pin(first)

        try Data("%PDF-1.4 the second version, which is longer".utf8)
            .write(to: directory.appendingPathComponent("document.pdf"))
        let scannedReread = try await scanner.item(at: directory)
        let reread = try XCTUnwrap(scannedReread)
        let second = try await pinner.pin(reread)

        let text = temp.text(at: try XCTUnwrap(second.pdfURL)) ?? ""
        XCTAssertTrue(text.contains("second version"))
        let leftovers = temp.names(in: temp.pinnedRootURL).filter { $0.hasPrefix(".") }
        XCTAssertTrue(leftovers.isEmpty, "staging directories must not survive a pin")
    }
}
