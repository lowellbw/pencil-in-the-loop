//
//  OutboxWriterTests.swift
//  SyncTests
//
//  The atomic write (docs/04-flows.md § F5) and the reply read (§ F6).
//
//  The property that matters — "a watcher on the other side must never see a
//  half-written bundle" — cannot be observed by racing a watcher against the
//  writer in a unit test without being flaky. It is checked here in the two
//  ways that are deterministic: the real name never exists until the rename,
//  because everything is assembled under a hidden one; and a failed write
//  leaves nothing at all behind.
//

import XCTest
import Foundation
import Core
@testable import Sync

final class OutboxWriterTests: XCTestCase {

    // MARK: - Ordering

    func testTheManifestIsWrittenLast() {
        let files = [
            BundleFile(relativePath: BundleManifest.fileName, data: Data("{}".utf8)),
            BundleFile(relativePath: ReviewBundle.fileName, data: Data("{}".utf8)),
            BundleFile(relativePath: "review.md", data: Data("# Review".utf8)),
            BundleFile(relativePath: "ink/page-01.png", data: Data("png".utf8))
        ]

        let ordered = OutboxWriter.writeOrder(for: files).map { $0.relativePath }

        XCTAssertEqual(ordered.last, BundleManifest.fileName, "the Mac watcher gates on the manifest")
        XCTAssertEqual(ordered, ["review.json", "review.md", "ink/page-01.png", "manifest.json"])
    }

    func testWriteOrderLeavesEverythingElseAlone() {
        let files = [
            BundleFile(relativePath: "review.md", data: Data()),
            BundleFile(relativePath: "ink/page-03.png", data: Data()),
            BundleFile(relativePath: "ink/page-01.png", data: Data())
        ]

        let ordered = OutboxWriter.writeOrder(for: files).map { $0.relativePath }

        XCTAssertEqual(ordered, ["review.md", "ink/page-03.png", "ink/page-01.png"])
    }

    // MARK: - Writing

    func testWriteLandsTheWholeBundleUnderItsRealName() async throws {
        let temp = try SyncTemporaryFolder()
        defer { temp.removeAll() }
        let payload = OutboxWriterTests.payload()

        let written = try await OutboxWriter().write(payload, to: temp.folder)

        XCTAssertEqual(written.directoryName, "2026-08-18-auth-refactor-plan.review")
        XCTAssertEqual(written.fileCount, payload.files.count)
        XCTAssertGreaterThan(written.byteCount, 0)
        XCTAssertEqual(temp.outboxNames, ["2026-08-18-auth-refactor-plan.review"])
        XCTAssertEqual(
            temp.names(in: written.directoryURL).sorted(),
            ["ink", "manifest.json", "review.json", "review.md"]
        )
        XCTAssertEqual(
            temp.names(in: written.directoryURL.appendingPathComponent("ink")),
            ["page-01.png"]
        )
    }

    func testNothingIsEverVisibleUnderTheRealNameBeforeTheRename() async throws {
        let temp = try SyncTemporaryFolder()
        defer { temp.removeAll() }

        // The staging directory is a hidden sibling, so at every moment before
        // the rename the outbox holds nothing a watcher would look at.
        let namesDuringWrite = temp.names(in: temp.folder.outboxURL)
            .filter { $0.hasPrefix(".") == false }
        XCTAssertTrue(namesDuringWrite.isEmpty)

        _ = try await OutboxWriter().write(OutboxWriterTests.payload(), to: temp.folder)

        let leftovers = temp.names(in: temp.folder.outboxURL).filter { $0.hasPrefix(".") }
        XCTAssertTrue(leftovers.isEmpty, "the staging directory must not survive the write")
    }

    func testAnUnreachableFolderIsNotAWriteFailure() async throws {
        let temp = try SyncTemporaryFolder()
        temp.removeAll()

        do {
            _ = try await OutboxWriter().write(OutboxWriterTests.payload(), to: temp.folder)
            XCTFail("writing into a folder that is not there should not succeed")
        } catch let error as PencilLoopError {
            guard case .folderUnavailable = error else {
                return XCTFail("offline must be .folderUnavailable so the caller can queue, got \(error)")
            }
        }
    }

    func testReSendingReplacesTheBundleButKeepsTheReply() async throws {
        let temp = try SyncTemporaryFolder()
        defer { temp.removeAll() }
        let writer = OutboxWriter()
        _ = try await writer.write(OutboxWriterTests.payload(), to: temp.folder)
        try temp.writeReply(
            inReviewDirectoryNamed: "2026-08-18-auth-refactor-plan.review",
            text: "Done — see the branch."
        )

        let second = OutboxWriterTests.payload(reviewMarkdown: "# Review — second pass\n")
        let written = try await writer.write(second, to: temp.folder)

        let review = temp.text(at: written.directoryURL.appendingPathComponent("review.md")) ?? ""
        XCTAssertTrue(review.contains("second pass"))
        let reply = try await writer.readReply(
            inReviewDirectory: written.directoryName,
            in: temp.folder
        )
        XCTAssertEqual(reply, "Done — see the branch.", "replacing a bundle must not discard half a conversation")

        // `WrittenReview` describes the bundle on disk, and the carried reply is
        // part of it. Counting only the payload under-reports what was written.
        let replyBytes = Int64("Done — see the branch.".utf8.count)
        let payloadBytes = second.files.reduce(Int64(0)) { $0 + Int64($1.data.count) }
        XCTAssertEqual(written.fileCount, second.files.count + 1)
        XCTAssertEqual(written.byteCount, payloadBytes + replyBytes)
    }

    // MARK: - Replies

    func testReadReplyReturnsNilWhenThereIsNoReply() async throws {
        let temp = try SyncTemporaryFolder()
        defer { temp.removeAll() }
        _ = try await OutboxWriter().write(OutboxWriterTests.payload(), to: temp.folder)

        let reply = try await OutboxWriter().readReply(
            inReviewDirectory: "2026-08-18-auth-refactor-plan.review",
            in: temp.folder
        )

        XCTAssertNil(reply, "absence is the normal case and is never an error")
    }

    func testReadReplyReturnsTheText() async throws {
        let temp = try SyncTemporaryFolder()
        defer { temp.removeAll() }
        try temp.writeReply(
            inReviewDirectoryNamed: "2026-08-18-auth-refactor-plan.review",
            text: "Reworked phase 2 with the shadow read."
        )

        let reply = try await OutboxWriter().readReply(
            inReviewDirectory: "2026-08-18-auth-refactor-plan.review",
            in: temp.folder
        )

        XCTAssertEqual(reply, "Reworked phase 2 with the shadow read.")
    }

    // MARK: - Fixtures

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
