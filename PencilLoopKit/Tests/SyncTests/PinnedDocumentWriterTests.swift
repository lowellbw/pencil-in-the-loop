//
//  PinnedDocumentWriterTests.swift
//  SyncTests
//
//  Container discipline, tested without a file provider or a server, because
//  neither has anything to do with it.
//
//  `InboxItemPinnerTests` is the regression net proving the extraction from
//  `InboxItemPinner` was behaviour-preserving; it was not edited by a character
//  and must not be. This file covers what that one could not reach directly:
//  the staging/commit/discard sequence both transports share, the whole-second
//  freshness comparison, and the sidecar's backwards compatibility.
//

import XCTest
import Foundation
import Core
@testable import Sync

final class PinnedDocumentWriterTests: XCTestCase {

    // MARK: - Staging and committing

    func testStagingIsHiddenAndInsideTheDestinationRoot() throws {
        let temp = try SyncTemporaryFolder()
        defer { temp.removeAll() }
        let writer = PinnedDocumentWriter(destinationRoot: temp.pinnedRootURL)

        let staging = try writer.beginStaging(forFolderNamed: "2026-08-19-staged")

        XCTAssertTrue(staging.path.hasPrefix(temp.pinnedRootURL.path))
        XCTAssertTrue(
            staging.lastPathComponent.hasPrefix("."),
            "a visible staging directory is a half-written document the library would show"
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: staging.path))
    }

    func testCommitPutsTheDirectoryInPlaceWithItsSidecar() throws {
        let temp = try SyncTemporaryFolder()
        defer { temp.removeAll() }
        let writer = PinnedDocumentWriter(destinationRoot: temp.pinnedRootURL)
        let staging = try writer.beginStaging(forFolderNamed: "2026-08-19-committed")
        try Data("%PDF-1.4 pretend".utf8)
            .write(to: staging.appendingPathComponent("document.pdf"))

        let destination = try writer.commit(
            staging: staging,
            snapshot: PinnedDocumentWriter.Snapshot(
                folderName: "2026-08-19-committed",
                modifiedAt: Date(timeIntervalSince1970: 1_000_000),
                byteCount: 16,
                pinnedAt: Date(timeIntervalSince1970: 1_000_001),
                fileNames: ["document.pdf"]
            )
        )

        XCTAssertEqual(destination, writer.pinnedDirectory(forFolderNamed: "2026-08-19-committed"))
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: destination.appendingPathComponent("document.pdf").path)
        )
        let snapshot = try XCTUnwrap(writer.pinnedSnapshot(forFolderNamed: "2026-08-19-committed"))
        XCTAssertEqual(snapshot.fileNames, ["document.pdf"])
        XCTAssertFalse(
            temp.names(in: temp.pinnedRootURL).contains { $0.hasPrefix(".") },
            "staging directories must not survive a commit"
        )
    }

    func testCommitReplacesAPreviousCopyWholesale() throws {
        let temp = try SyncTemporaryFolder()
        defer { temp.removeAll() }
        let writer = PinnedDocumentWriter(destinationRoot: temp.pinnedRootURL)
        try pin(writer, folderName: "2026-08-19-twice", text: "first", byteCount: 5)

        try pin(writer, folderName: "2026-08-19-twice", text: "second", byteCount: 6)

        let pinned = writer.pinnedDirectory(forFolderNamed: "2026-08-19-twice")
        XCTAssertEqual(temp.text(at: pinned.appendingPathComponent("document.pdf")), "second")
        XCTAssertEqual(writer.pinnedSnapshot(forFolderNamed: "2026-08-19-twice")?.byteCount, 6)
    }

    func testDiscardingLeavesThePreviousCopyExactlyAsItWas() throws {
        let temp = try SyncTemporaryFolder()
        defer { temp.removeAll() }
        let writer = PinnedDocumentWriter(destinationRoot: temp.pinnedRootURL)
        try pin(writer, folderName: "2026-08-19-kept", text: "the readable one", byteCount: 16)
        let pinned = writer.pinnedDirectory(forFolderNamed: "2026-08-19-kept")
        let before = try Data(contentsOf: pinned.appendingPathComponent("document.pdf"))

        // What a failed verification looks like: bytes staged, never committed.
        let staging = try writer.beginStaging(forFolderNamed: "2026-08-19-kept")
        try Data("truncated".utf8).write(to: staging.appendingPathComponent("document.pdf"))
        writer.discard(staging)

        let after = try Data(contentsOf: pinned.appendingPathComponent("document.pdf"))
        XCTAssertEqual(
            before,
            after,
            "a document readable yesterday is readable today, whatever went wrong with the newest copy"
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path))
    }

    // MARK: - Freshness

    func testASecondsPrecisionSidecarStillCountsAsCurrent() throws {
        let temp = try SyncTemporaryFolder()
        defer { temp.removeAll() }
        let writer = PinnedDocumentWriter(destinationRoot: temp.pinnedRootURL)
        // The sidecar can only hold whole seconds, so this reads back as
        // 1_000_000 — earlier than the date it was taken from. Comparing
        // without rounding calls every pinned document stale on every scan, and
        // the whole library is re-downloaded every fifteen seconds.
        let modifiedAt = Date(timeIntervalSince1970: 1_000_000.75)
        try pin(writer, folderName: "2026-08-19-fractional", text: "abc", byteCount: 3, modifiedAt: modifiedAt)

        XCTAssertTrue(
            writer.isPinnedAndCurrent(
                folderName: "2026-08-19-fractional",
                modifiedAt: modifiedAt,
                byteCount: 3
            ),
            "this is the bug that re-downloaded the whole library every poll"
        )
    }

    func testAFolderRewrittenInPlaceIsNotCurrent() throws {
        let temp = try SyncTemporaryFolder()
        defer { temp.removeAll() }
        let writer = PinnedDocumentWriter(destinationRoot: temp.pinnedRootURL)
        let modifiedAt = Date(timeIntervalSince1970: 1_000_000)
        try pin(writer, folderName: "2026-08-19-rewritten", text: "abc", byteCount: 3, modifiedAt: modifiedAt)

        XCTAssertFalse(writer.isPinnedAndCurrent(
            folderName: "2026-08-19-rewritten",
            modifiedAt: modifiedAt.addingTimeInterval(60),
            byteCount: 3
        ))
        XCTAssertFalse(writer.isPinnedAndCurrent(
            folderName: "2026-08-19-rewritten",
            modifiedAt: modifiedAt,
            byteCount: 4096
        ))
        XCTAssertFalse(writer.isPinnedAndCurrent(
            folderName: "2026-08-19-never-pinned",
            modifiedAt: modifiedAt,
            byteCount: 3
        ))
    }

    func testARevisionIsCurrentOnlyWhenItIsTheSameRevision() throws {
        let temp = try SyncTemporaryFolder()
        defer { temp.removeAll() }
        let writer = PinnedDocumentWriter(destinationRoot: temp.pinnedRootURL)
        try pin(writer, folderName: "2026-08-19-relayed", text: "abc", byteCount: 3, revision: "42")

        XCTAssertTrue(writer.isPinnedAndCurrent(folderName: "2026-08-19-relayed", revision: "42"))
        XCTAssertFalse(writer.isPinnedAndCurrent(folderName: "2026-08-19-relayed", revision: "43"))
    }

    func testAFolderPinnedWithoutARevisionIsNeverCurrentByRevision() throws {
        let temp = try SyncTemporaryFolder()
        defer { temp.removeAll() }
        let writer = PinnedDocumentWriter(destinationRoot: temp.pinnedRootURL)
        try pin(writer, folderName: "2026-08-19-from-a-folder", text: "abc", byteCount: 3)

        XCTAssertFalse(
            writer.isPinnedAndCurrent(folderName: "2026-08-19-from-a-folder", revision: "1"),
            "a folder-pinned copy has no server revision, so it is copied again rather than assumed to match"
        )
    }

    // MARK: - The sidecar's shape

    func testASidecarWrittenBeforeRevisionsExistedStillDecodes() throws {
        let old = """
        {
          "byteCount" : 4096,
          "fileNames" : ["document.pdf", "meta.json"],
          "folderName" : "2026-08-18-auth-refactor-plan",
          "modifiedAt" : "2026-08-18T18:22:04Z",
          "pinnedAt" : "2026-08-18T18:22:09Z"
        }
        """

        let snapshot = try ContractCoding.decoder().decode(
            PinnedDocumentWriter.Snapshot.self,
            from: Data(old.utf8)
        )

        XCTAssertNil(
            snapshot.revision,
            "a required field here would report every already-pinned document as unpinned"
        )
        XCTAssertEqual(snapshot.byteCount, 4096)
        XCTAssertEqual(snapshot.folderName, "2026-08-18-auth-refactor-plan")
    }

    // MARK: - Removing

    func testInvalidatingASnapshotKeepsEveryByte() throws {
        let temp = try SyncTemporaryFolder()
        defer { temp.removeAll() }
        let writer = PinnedDocumentWriter(destinationRoot: temp.pinnedRootURL)
        try pin(writer, folderName: "2026-08-19-unreflected", text: "abc", byteCount: 3)

        writer.invalidateSnapshot(forFolderNamed: "2026-08-19-unreflected")

        XCTAssertNil(writer.pinnedSnapshot(forFolderNamed: "2026-08-19-unreflected"))
        let pinned = writer.pinnedDirectory(forFolderNamed: "2026-08-19-unreflected")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: pinned.appendingPathComponent("document.pdf").path)
        )
    }

    func testRemovingAPinnedCopyRemovesTheDirectory() throws {
        let temp = try SyncTemporaryFolder()
        defer { temp.removeAll() }
        let writer = PinnedDocumentWriter(destinationRoot: temp.pinnedRootURL)
        try pin(writer, folderName: "2026-08-19-purged", text: "abc", byteCount: 3)

        writer.removePinnedCopy(forFolderNamed: "2026-08-19-purged")

        XCTAssertFalse(FileManager.default.fileExists(
            atPath: writer.pinnedDirectory(forFolderNamed: "2026-08-19-purged").path
        ))
    }

    // MARK: - Helper

    /// Stages one `document.pdf` and commits it, which is what both transports
    /// do around their own download step.
    private func pin(
        _ writer: PinnedDocumentWriter,
        folderName: String,
        text: String,
        byteCount: Int64,
        modifiedAt: Date = Date(timeIntervalSince1970: 1_000_000),
        revision: String? = nil
    ) throws {
        let staging = try writer.beginStaging(forFolderNamed: folderName)
        try Data(text.utf8).write(to: staging.appendingPathComponent("document.pdf"))
        try writer.commit(
            staging: staging,
            snapshot: PinnedDocumentWriter.Snapshot(
                folderName: folderName,
                modifiedAt: modifiedAt,
                byteCount: byteCount,
                pinnedAt: Date(timeIntervalSince1970: 1_000_100),
                fileNames: ["document.pdf"],
                revision: revision
            )
        )
    }
}
