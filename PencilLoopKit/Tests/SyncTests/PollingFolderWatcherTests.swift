//
//  PollingFolderWatcherTests.swift
//  SyncTests
//
//  The watcher's diffing is a pure function and is tested directly. The loop
//  itself gets one end-to-end test at a very short interval, because a timer
//  test that runs for fifteen seconds is a test nobody runs.
//
//  What to check by hand on device, because no test here can:
//
//    · Send a document from a Mac into an iCloud Drive folder while the app is
//      in the foreground, and time how long it takes to appear. It should be
//      under the poll interval, and often immediate — that is the presenter
//      doing its job.
//    · Do the same with the app backgrounded, then foreground it. The document
//      must be there within a second of the app appearing, from `start()`.
//

import XCTest
import Foundation
import Core
@testable import Sync

final class PollingFolderWatcherTests: XCTestCase {

    // MARK: - Diffing

    func testANewDirectoryIsAChange() {
        let entry = PollingFolderWatcher.Fingerprint.Entry(
            url: URL(fileURLWithPath: "/sync/inbox/2026-08-18-plan"),
            modifiedAt: Date(timeIntervalSince1970: 100),
            byteCount: 10
        )
        let current = PollingFolderWatcher.Fingerprint(entries: ["2026-08-18-plan": entry])

        let events = PollingFolderWatcher.inboxChanges(from: .empty, to: current)

        XCTAssertEqual(events, [.inboxChanged(directoryURL: entry.url)])
    }

    func testAnUnchangedDirectoryIsSilent() {
        let entry = PollingFolderWatcher.Fingerprint.Entry(
            url: URL(fileURLWithPath: "/sync/inbox/2026-08-18-plan"),
            modifiedAt: Date(timeIntervalSince1970: 100),
            byteCount: 10
        )
        let fingerprint = PollingFolderWatcher.Fingerprint(entries: ["2026-08-18-plan": entry])

        XCTAssertTrue(PollingFolderWatcher.inboxChanges(from: fingerprint, to: fingerprint).isEmpty)
    }

    func testBytesArrivingWithoutAModificationDateStillCount() {
        let url = URL(fileURLWithPath: "/sync/inbox/2026-08-18-plan")
        let before = PollingFolderWatcher.Fingerprint(entries: [
            "2026-08-18-plan": .init(url: url, modifiedAt: Date(timeIntervalSince1970: 100), byteCount: 0)
        ])
        let after = PollingFolderWatcher.Fingerprint(entries: [
            "2026-08-18-plan": .init(url: url, modifiedAt: Date(timeIntervalSince1970: 100), byteCount: 4_000_000)
        ])

        XCTAssertEqual(
            PollingFolderWatcher.inboxChanges(from: before, to: after),
            [.inboxChanged(directoryURL: url)],
            "a provider can deliver bytes without moving the modification date"
        )
    }

    func testADisappearedDirectoryIsReportedAsRemoved() {
        let url = URL(fileURLWithPath: "/sync/inbox/2026-08-18-plan")
        let before = PollingFolderWatcher.Fingerprint(entries: [
            "2026-08-18-plan": .init(url: url, modifiedAt: Date(timeIntervalSince1970: 100), byteCount: 10)
        ])

        XCTAssertEqual(
            PollingFolderWatcher.inboxChanges(from: before, to: .empty),
            [.inboxRemoved(folderName: "2026-08-18-plan")]
        )
    }

    func testANewReplyIsReported() {
        let url = URL(fileURLWithPath: "/sync/outbox/2026-08-18-plan.review/reply.md")
        let current = PollingFolderWatcher.Fingerprint(entries: [
            "2026-08-18-plan.review": .init(url: url, modifiedAt: Date(timeIntervalSince1970: 200), byteCount: 40)
        ])

        XCTAssertEqual(
            PollingFolderWatcher.replyChanges(from: .empty, to: current),
            [.replyAppeared(reviewFolderName: "2026-08-18-plan.review", replyURL: url)]
        )
    }

    func testAVanishedReplyIsNotAnEvent() {
        let url = URL(fileURLWithPath: "/sync/outbox/2026-08-18-plan.review/reply.md")
        let before = PollingFolderWatcher.Fingerprint(entries: [
            "2026-08-18-plan.review": .init(url: url, modifiedAt: Date(timeIntervalSince1970: 200), byteCount: 40)
        ])

        XCTAssertTrue(PollingFolderWatcher.replyChanges(from: before, to: .empty).isEmpty)
    }

    // MARK: - Sampling

    func testSamplingARealFolder() throws {
        let temp = try SyncTemporaryFolder()
        defer { temp.removeAll() }
        try temp.writeInboxDirectory(named: "2026-08-18-plan")
        try temp.writeHiddenStagingDirectory(named: ".2026-08-18-plan.tmp")
        try temp.writeReply(inReviewDirectoryNamed: "2026-08-17-earlier.review", text: "Done.")

        let sample = PollingFolderWatcher.sample(of: temp.folder)

        XCTAssertTrue(sample.isReachable)
        XCTAssertEqual(Set(sample.inbox.entries.keys), ["2026-08-18-plan"])
        XCTAssertEqual(Set(sample.replies.entries.keys), ["2026-08-17-earlier.review"])
    }

    func testSamplingAFolderThatIsNotThere() throws {
        let temp = try SyncTemporaryFolder()
        temp.removeAll()

        XCTAssertFalse(PollingFolderWatcher.sample(of: temp.folder).isReachable)
    }

    // MARK: - The loop

    func testTheWatcherReportsADocumentThatArrivesWhileItIsRunning() async throws {
        let temp = try SyncTemporaryFolder()
        defer { temp.removeAll() }
        let watcher = PollingFolderWatcher(pollInterval: 0.2)
        let arrived = expectation(description: "the new inbox directory is reported")

        let stream = watcher.events(for: temp.folder)
        let consumer = Task {
            for await event in stream {
                if case .inboxChanged = event {
                    arrived.fulfill()
                    return
                }
            }
        }

        try await Task.sleep(nanoseconds: 300_000_000)
        try temp.writeInboxDirectory(named: "2026-08-18-arrived")

        await fulfillment(of: [arrived], timeout: 10)
        consumer.cancel()
        await watcher.stop()
    }

    func testAFolderThatGoesAwayIsReportedAndTheStreamStaysOpen() async throws {
        let temp = try SyncTemporaryFolder()
        let watcher = PollingFolderWatcher(pollInterval: 0.2)
        let reported = expectation(description: "the folder is reported unavailable")

        let stream = watcher.events(for: temp.folder)
        let consumer = Task {
            for await event in stream {
                if case .folderUnavailable = event {
                    reported.fulfill()
                    return
                }
            }
        }

        try await Task.sleep(nanoseconds: 300_000_000)
        temp.removeAll()

        await fulfillment(of: [reported], timeout: 10)
        consumer.cancel()
        await watcher.stop()
    }

    func testStopIsIdempotent() async throws {
        let temp = try SyncTemporaryFolder()
        defer { temp.removeAll() }
        let watcher = PollingFolderWatcher(pollInterval: 0.2)
        _ = watcher.events(for: temp.folder)

        await watcher.stop()
        await watcher.stop()
    }
}
