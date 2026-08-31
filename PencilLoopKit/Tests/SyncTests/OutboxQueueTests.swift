//
//  OutboxQueueTests.swift
//  SyncTests
//
//  Offline behaviour (docs/04-flows.md § F7): the bundle is written locally and
//  goes when the connection returns. The failure mode is "will send when
//  online", never an error.
//

import XCTest
import Foundation
import Core
@testable import Sync

final class OutboxQueueTests: XCTestCase {

    func testAQueuedBundleRoundTrips() throws {
        let temp = try SyncTemporaryFolder()
        defer { temp.removeAll() }
        let queue = OutboxQueue(rootURL: temp.queueRootURL)
        let payload = OutboxQueueTests.payload()

        _ = try queue.enqueue(payload)
        let waiting = queue.queuedPayloads()

        XCTAssertEqual(waiting.count, 1)
        XCTAssertEqual(waiting[0].directoryName, payload.directoryName)
        XCTAssertEqual(waiting[0].documentId, payload.documentId)
        XCTAssertEqual(
            waiting[0].files.map { $0.relativePath }.sorted(),
            payload.files.map { $0.relativePath }.sorted()
        )
        let review = waiting[0].files.first { $0.relativePath == "review.md" }
        XCTAssertEqual(review?.data, Data("# Review — Auth refactor plan\n".utf8))
    }

    func testAQueuedBundleKeepsTheManifestLast() throws {
        let temp = try SyncTemporaryFolder()
        defer { temp.removeAll() }
        let queue = OutboxQueue(rootURL: temp.queueRootURL)

        _ = try queue.enqueue(OutboxQueueTests.payload())
        let waiting = queue.queuedPayloads()

        XCTAssertEqual(waiting[0].files.last?.relativePath, BundleManifest.fileName)
    }

    func testADirectoryWithNoTicketIsIgnored() throws {
        let temp = try SyncTemporaryFolder()
        defer { temp.removeAll() }
        let orphan = temp.queueRootURL.appendingPathComponent("2026-08-18-orphan.review", isDirectory: true)
        try FileManager.default.createDirectory(at: orphan, withIntermediateDirectories: true)
        try Data("# Review".utf8).write(to: orphan.appendingPathComponent("review.md"))

        let queue = OutboxQueue(rootURL: temp.queueRootURL)

        XCTAssertTrue(queue.queuedPayloads().isEmpty, "a copy that did not finish is not a review")
    }

    func testRemoveDropsTheBundle() throws {
        let temp = try SyncTemporaryFolder()
        defer { temp.removeAll() }
        let queue = OutboxQueue(rootURL: temp.queueRootURL)
        let payload = OutboxQueueTests.payload()
        _ = try queue.enqueue(payload)

        queue.remove(payload.directoryName)

        XCTAssertTrue(queue.isEmpty)
    }

    func testQueueingTheSameReviewTwiceKeepsOneCopy() throws {
        let temp = try SyncTemporaryFolder()
        defer { temp.removeAll() }
        let queue = OutboxQueue(rootURL: temp.queueRootURL)

        _ = try queue.enqueue(OutboxQueueTests.payload())
        _ = try queue.enqueue(OutboxQueueTests.payload(reviewMarkdown: "# Review — revised\n"))

        let waiting = queue.queuedPayloads()
        XCTAssertEqual(waiting.count, 1)
        let review = waiting[0].files.first { $0.relativePath == "review.md" }
        XCTAssertEqual(review?.data, Data("# Review — revised\n".utf8))
    }

    // MARK: - Fixtures

    /// A review bundle's worth of files.
    ///
    /// Moved here from `OutboxWriterTests` when the folder transport was
    /// removed and that case went with it. This suite was already borrowing it,
    /// and is now the only caller.
    static func payload(reviewMarkdown: String = "# Review — Auth refactor plan\n") -> OutboxPayload {
        let folderName = "2026-08-18-auth-refactor-plan"
        return OutboxPayload(
            directoryName: OutboxPayload.directoryName(forDocumentFolder: folderName),
            documentId: UUID(uuidString: "F7A1C0DE-0000-4000-8000-000000000001") ?? UUID(),
            files: [
                BundleFile(relativePath: "review.md", data: Data(reviewMarkdown.utf8)),
                BundleFile(relativePath: ReviewBundle.fileName, data: Data("{\"documentId\":\"F7A1\"}".utf8)),
                BundleFile(relativePath: InkImage.fileName(forPageIndex: 0), data: Data("pretend png".utf8)),
                BundleFile(relativePath: BundleManifest.fileName, data: Data("{\"version\":1}".utf8))
            ]
        )
    }
}
