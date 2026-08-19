//
//  ReplyScannerTests.swift
//  SyncTests
//
//  Reply detection (docs/04-flows.md § F6).
//

import XCTest
import Foundation
import Core
@testable import Sync

final class ReplyScannerTests: XCTestCase {

    func testAReplyIsFoundAndMappedBackToItsDocument() throws {
        let temp = try SyncTemporaryFolder()
        defer { temp.removeAll() }
        try temp.writeReply(
            inReviewDirectoryNamed: "2026-08-18-auth-refactor-plan.review",
            text: "Reworked phase 2."
        )

        let replies = ReplyScanner().scan(temp.folder)

        XCTAssertEqual(replies.count, 1)
        XCTAssertEqual(replies[0].reviewDirectoryName, "2026-08-18-auth-refactor-plan.review")
        XCTAssertEqual(replies[0].documentFolderName, "2026-08-18-auth-refactor-plan")
        XCTAssertEqual(replies[0].replyURL.lastPathComponent, "reply.md")
    }

    func testAReviewDirectoryWithNoReplyIsNotOne() throws {
        let temp = try SyncTemporaryFolder()
        defer { temp.removeAll() }
        let directory = temp.folder.outboxURL
            .appendingPathComponent("2026-08-18-auth-refactor-plan.review", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("# Review".utf8).write(to: directory.appendingPathComponent("review.md"))

        XCTAssertTrue(ReplyScanner().scan(temp.folder).isEmpty)
    }

    func testSomethingThatIsNotAReviewDirectoryIsIgnored() throws {
        let temp = try SyncTemporaryFolder()
        defer { temp.removeAll() }
        let directory = temp.folder.outboxURL.appendingPathComponent("notes", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("hello".utf8).write(to: directory.appendingPathComponent("reply.md"))

        XCTAssertTrue(ReplyScanner().scan(temp.folder).isEmpty)
    }

    func testAMissingOutboxIsNoRepliesRatherThanAFailure() throws {
        let temp = try SyncTemporaryFolder()
        defer { temp.removeAll() }
        try FileManager.default.removeItem(at: temp.folder.outboxURL)

        XCTAssertTrue(ReplyScanner().scan(temp.folder).isEmpty)
    }

    func testTheReviewSuffixIsStrippedInOnePlace() {
        XCTAssertEqual(
            ReplyScanner.documentFolderName(forReviewDirectory: "2026-08-18-plan.review"),
            "2026-08-18-plan"
        )
        XCTAssertEqual(
            ReplyScanner.documentFolderName(forReviewDirectory: "2026-08-18-plan"),
            "2026-08-18-plan"
        )
        XCTAssertEqual(
            OutboxPayload.directoryName(forDocumentFolder: "2026-08-18-plan"),
            "2026-08-18-plan" + OutboxPayload.reviewDirectorySuffix
        )
    }
}
