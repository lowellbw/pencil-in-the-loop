//
//  SyncCoordinatorTests.swift
//  SyncTests
//
//  The loop end to end, with a real folder, a fake store and a fake ingester:
//  scan, pin, ingest, record, write, queue, reply.
//
//  Every coordinator here is built with `importsAppGroupStaging: false` unless
//  the test is about staging, and with the pin and queue roots pointed at the
//  temp directory — the defaults write into Application Support, which a test
//  has no business touching.
//

import XCTest
import Foundation
import Core
@testable import Sync

final class SyncCoordinatorTests: XCTestCase {

    func testRefreshIngestsWhatIsInTheInbox() async throws {
        let temp = try SyncTemporaryFolder()
        defer { temp.removeAll() }
        try temp.writeInboxDirectory(named: "2026-08-17-first")
        try temp.writeInboxDirectory(named: "2026-08-18-second", metaJSON: nil)
        let store = SyncTestStore()
        let ingester = SyncTestIngester()
        let coordinator = SyncCoordinatorTests.coordinator(temp: temp, store: store, ingester: ingester)

        let count = try await coordinator.refresh()

        XCTAssertEqual(count, 2)
        let seen = await ingester.received.map { $0.folderName }
        XCTAssertEqual(seen, ["2026-08-17-first", "2026-08-18-second"])
        let known = try await store.knownFolderNames()
        XCTAssertEqual(known, ["2026-08-17-first", "2026-08-18-second"])
    }

    func testIngestIsHandedPinnedLocalFilesOnly() async throws {
        let temp = try SyncTemporaryFolder()
        defer { temp.removeAll() }
        try temp.writeInboxDirectory(named: "2026-08-18-pinned")
        let store = SyncTestStore()
        let ingester = SyncTestIngester()
        let coordinator = SyncCoordinatorTests.coordinator(temp: temp, store: store, ingester: ingester)

        _ = try await coordinator.refresh()

        let underPinnedRoot = await ingester.everyReceivedItemIsUnder(temp.pinnedRootURL)
        let filesExist = await ingester.everyReceivedFileExists()
        XCTAssertTrue(underPinnedRoot, "Ingest must never be handed a file-provider URL")
        XCTAssertTrue(filesExist)
    }

    func testAMissingMetaJSONDoesNotBlockIngest() async throws {
        let temp = try SyncTemporaryFolder()
        defer { temp.removeAll() }
        try temp.writeInboxDirectory(named: "2026-08-18-anonymous", metaJSON: nil)
        let store = SyncTestStore()
        let coordinator = SyncCoordinatorTests.coordinator(temp: temp, store: store)

        let count = try await coordinator.refresh()

        XCTAssertEqual(count, 1)
        let upserted = await store.upserted
        XCTAssertEqual(upserted.first?.origin.kind, .manual)
        XCTAssertEqual(upserted.first?.title, "2026-08-18-anonymous")
    }

    func testAnUnchangedDocumentIsNotIngestedTwice() async throws {
        let temp = try SyncTemporaryFolder()
        defer { temp.removeAll() }
        try temp.writeInboxDirectory(named: "2026-08-18-once")
        let store = SyncTestStore()
        let ingester = SyncTestIngester()
        let coordinator = SyncCoordinatorTests.coordinator(temp: temp, store: store, ingester: ingester)

        let first = try await coordinator.refresh()
        let second = try await coordinator.refresh()

        XCTAssertEqual(first, 1)
        XCTAssertEqual(second, 0)
        let seen = await ingester.received.count
        XCTAssertEqual(seen, 1)
    }

    func testAFailedIngestBecomesAnErrorRowRatherThanADisappearance() async throws {
        let temp = try SyncTemporaryFolder()
        defer { temp.removeAll() }
        try temp.writeInboxDirectory(named: "2026-08-18-good")
        try temp.writeInboxDirectory(named: "2026-08-18-broken")
        let store = SyncTestStore()
        let ingester = SyncTestIngester()
        await ingester.fail(folderName: "2026-08-18-broken", reason: "PDFKit will not open it.")
        let coordinator = SyncCoordinatorTests.coordinator(temp: temp, store: store, ingester: ingester)

        let count = try await coordinator.refresh()

        XCTAssertEqual(count, 1)
        let failures = await store.failures
        XCTAssertNotNil(failures["2026-08-18-broken"])
        XCTAssertEqual(temp.inboxNames.contains("2026-08-18-broken"), true, "the folder is never deleted")
    }

    func testAFolderThatFailedIsRetriedOnTheNextRefresh() async throws {
        let temp = try SyncTemporaryFolder()
        defer { temp.removeAll() }
        try temp.writeInboxDirectory(named: "2026-08-18-flaky")
        let store = SyncTestStore()
        let ingester = SyncTestIngester()
        await ingester.fail(folderName: "2026-08-18-flaky", reason: "The provider blinked.")
        let coordinator = SyncCoordinatorTests.coordinator(temp: temp, store: store, ingester: ingester)

        let failed = try await coordinator.refresh()
        XCTAssertEqual(failed, 0)
        let failures = await store.failures
        XCTAssertNotNil(failures["2026-08-18-flaky"], "the failure is recorded, so the folder is now known")

        // Whatever was wrong has passed. Pull-to-refresh is the user asking us
        // to look again, and it has to actually look — the folder is in
        // `knownFolderNames()` now, which is exactly the state that used to make
        // the scanner skip it for the rest of the session.
        await ingester.succeed(folderName: "2026-08-18-flaky")
        let recovered = try await coordinator.refresh()

        XCTAssertEqual(recovered, 1, "a transient failure must not be permanent")
        let attempts = await ingester.attempts(forFolderName: "2026-08-18-flaky")
        XCTAssertEqual(attempts, 2)
        let upserted = await store.upserted
        XCTAssertEqual(upserted.map { $0.folderName }, ["2026-08-18-flaky"])
    }

    func testABackgroundScanDoesNotRepeatAFailureUntilSomethingChanges() async throws {
        let temp = try SyncTemporaryFolder()
        defer { temp.removeAll() }
        try temp.writeInboxDirectory(named: "2026-08-18-broken")
        let store = SyncTestStore()
        let ingester = SyncTestIngester()
        await ingester.fail(folderName: "2026-08-18-broken", reason: "PDFKit will not open it.")
        let coordinator = SyncCoordinatorTests.coordinator(temp: temp, store: store, ingester: ingester)

        _ = try await coordinator.refresh()
        // `start()` scans without the user asking, which is what the timer does.
        await coordinator.start()
        await coordinator.stop()

        let attempts = await ingester.attempts(forFolderName: "2026-08-18-broken")
        XCTAssertEqual(
            attempts,
            1,
            "a document that cannot be read is not re-downloaded every fifteen seconds; the retry is the user's gesture"
        )
    }

    func testAnUnreachableFolderIsAThrowingRefresh() async throws {
        let temp = try SyncTemporaryFolder()
        temp.removeAll()
        let coordinator = SyncCoordinatorTests.coordinator(temp: temp, store: SyncTestStore())

        do {
            _ = try await coordinator.refresh()
            XCTFail("pull-to-refresh on a folder that is not there has something to report")
        } catch let error as PencilLoopError {
            guard case .folderUnavailable = error else {
                return XCTFail("expected .folderUnavailable, got \(error)")
            }
        }
    }

    func testEventsDescribeTheScan() async throws {
        let temp = try SyncTemporaryFolder()
        defer { temp.removeAll() }
        try temp.writeInboxDirectory(named: "2026-08-18-watched")
        let coordinator = SyncCoordinatorTests.coordinator(temp: temp, store: SyncTestStore())

        let stream = coordinator.events()
        let finished = expectation(description: "the scan finishes")
        let collector = Task { () -> [SyncEvent] in
            var collected: [SyncEvent] = []
            for await event in stream {
                collected.append(event)
                if case .scanFinished = event {
                    finished.fulfill()
                    return collected
                }
            }
            return collected
        }
        // Give the listener registration, which hops onto the actor, a moment.
        try await Task.sleep(nanoseconds: 100_000_000)

        _ = try await coordinator.refresh()
        await fulfillment(of: [finished], timeout: 10)
        collector.cancel()
        let events = await collector.value

        XCTAssertTrue(events.contains(.scanStarted(pending: 1)))
        XCTAssertTrue(events.contains(.scanFinished(ingestedCount: 1)))
        XCTAssertTrue(events.contains { if case .ingested = $0 { return true } else { return false } })
    }

    // MARK: - Sending

    func testSendWritesTheBundle() async throws {
        let temp = try SyncTemporaryFolder()
        defer { temp.removeAll() }
        let coordinator = SyncCoordinatorTests.coordinator(temp: temp, store: SyncTestStore())

        let written = try await coordinator.send(OutboxWriterTests.payload())

        XCTAssertEqual(temp.outboxNames, ["2026-08-18-auth-refactor-plan.review"])
        XCTAssertEqual(written.directoryURL.lastPathComponent, "2026-08-18-auth-refactor-plan.review")
    }

    func testSendQueuesWhenTheFolderIsAwayAndSendsWhenItReturns() async throws {
        let temp = try SyncTemporaryFolder()
        defer { temp.removeAll() }
        let missingRoot = temp.rootURL.appendingPathComponent("later", isDirectory: true)
        let folder = SyncFolder(rootURL: missingRoot)
        let queue = OutboxQueue(rootURL: temp.queueRootURL)
        let coordinator = SyncCoordinator(
            folder: folder,
            store: SyncTestStore(),
            ingester: SyncTestIngester(),
            pinner: InboxItemPinner(destinationRoot: temp.pinnedRootURL),
            queue: queue,
            importsAppGroupStaging: false
        )

        let queued = try await coordinator.send(OutboxWriterTests.payload())

        XCTAssertTrue(
            queued.directoryURL.path.hasPrefix(temp.queueRootURL.path),
            "offline is 'will send when online', not a failure"
        )
        XCTAssertTrue(
            queued.isQueued,
            "the Sent screen reads this to say 'will send when online' rather than 'sent' (DTOs.swift)"
        )
        XCTAssertEqual(queue.queuedPayloads().count, 1)

        // The connection comes back.
        try FileManager.default.createDirectory(
            at: folder.inboxURL,
            withIntermediateDirectories: true
        )
        _ = try await coordinator.refresh()

        let outbox = (try? FileManager.default.contentsOfDirectory(atPath: folder.outboxURL.path)) ?? []
        XCTAssertEqual(outbox.filter { $0.hasPrefix(".") == false }, ["2026-08-18-auth-refactor-plan.review"])
        XCTAssertTrue(queue.isEmpty, "a sent review does not stay queued")
    }

    /// The gap this test exists for: the review sheet the user queued from has
    /// been closed for hours by the time the folder comes back, so nobody was
    /// left to record the delivery. The reply text still landed — Sync calls
    /// `recordReply` itself — but the directory name never did, and "Open reply
    /// as document" needs exactly that (`ReviewStatus.directoryName`), so a
    /// review sent this way could never be reopened.
    func testAFlushedQueueIsRecordedAsSentWithNoSheetOpen() async throws {
        let temp = try SyncTemporaryFolder()
        defer { temp.removeAll() }
        let missingRoot = temp.rootURL.appendingPathComponent("later", isDirectory: true)
        let folder = SyncFolder(rootURL: missingRoot)
        let store = SyncTestStore()
        let payload = OutboxWriterTests.payload()
        let coordinator = SyncCoordinator(
            folder: folder,
            store: store,
            ingester: SyncTestIngester(),
            pinner: InboxItemPinner(destinationRoot: temp.pinnedRootURL),
            queue: OutboxQueue(rootURL: temp.queueRootURL),
            importsAppGroupStaging: false
        )

        let queued = try await coordinator.send(payload)
        XCTAssertTrue(queued.isQueued)
        let beforeFlush = await store.reviewsSent
        XCTAssertTrue(
            beforeFlush.isEmpty,
            "nothing has reached outbox/ yet, so there is no delivery to record (docs/04-flows.md § F7)"
        )

        // The folder comes back, and the scan that notices flushes the queue.
        try FileManager.default.createDirectory(at: folder.inboxURL, withIntermediateDirectories: true)
        _ = try await coordinator.refresh()

        let sent = await store.reviewsSent
        XCTAssertEqual(sent.count, 1, "the bundle is in outbox/ now, and that is a review that has been sent")
        XCTAssertEqual(sent.first?.documentId, payload.documentId)
        XCTAssertEqual(
            sent.first?.directoryName,
            payload.directoryName,
            "the directory an agent's reply will come back in, which is the whole point of recording it"
        )

        let states = await store.stateChanges
        XCTAssertEqual(
            states.map { $0.state },
            [.read],
            "the sheet moves a delivered review to Read on the equivalent path; the two must not disagree"
        )

        let status = try await store.reviewStatus(documentId: payload.documentId)
        XCTAssertEqual(
            status?.directoryName,
            payload.directoryName,
            "'Open reply as document' reads this and used to find nothing"
        )
    }

    // MARK: - Replies

    func testAReplyIsRecordedAgainstItsDocument() async throws {
        let temp = try SyncTemporaryFolder()
        defer { temp.removeAll() }
        try temp.writeInboxDirectory(named: "2026-08-18-auth-refactor-plan")
        let store = SyncTestStore()
        let coordinator = SyncCoordinatorTests.coordinator(temp: temp, store: store)
        _ = try await coordinator.refresh()

        try temp.writeReply(
            inReviewDirectoryNamed: "2026-08-18-auth-refactor-plan.review",
            text: "Reworked phase 2 with the shadow read."
        )
        _ = try await coordinator.refresh()

        let replies = await store.replies
        XCTAssertEqual(replies.count, 1)
        XCTAssertEqual(replies.values.first, "Reworked phase 2 with the shadow read.")
    }

    func testOpeningAReplyAsADocumentInheritsTheOrigin() async throws {
        let temp = try SyncTemporaryFolder()
        defer { temp.removeAll() }
        try temp.writeInboxDirectory(named: "2026-08-18-auth-refactor-plan")
        try temp.writeReply(
            inReviewDirectoryNamed: "2026-08-18-auth-refactor-plan.review",
            text: "# Phase 2, reworked\n\nShadow read for a day, then cut over.\n"
        )
        let store = SyncTestStore()
        let ingester = SyncTestIngester()
        let coordinator = SyncCoordinatorTests.coordinator(temp: temp, store: store, ingester: ingester)
        _ = try await coordinator.refresh()

        let newId = try await coordinator.ingestReply(
            fromReviewDirectory: "2026-08-18-auth-refactor-plan.review"
        )

        let upserted = await store.upserted
        let reply = try XCTUnwrap(upserted.first { $0.id == newId })
        XCTAssertTrue(reply.title.hasPrefix("Reply — "))
        XCTAssertEqual(reply.origin.kind, .cowork, "the thread carries forward or the loop is not a loop")
        XCTAssertEqual(reply.origin.sessionId, "8f3c1d")
        XCTAssertEqual(reply.origin.returnPath?.type, .poke)

        let names = temp.inboxNames
        XCTAssertEqual(names.count, 2, "the reply is a document in the inbox like any other")
        let newFolder = try XCTUnwrap(names.first { $0 != "2026-08-18-auth-refactor-plan" })
        let directory = temp.folder.inboxURL.appendingPathComponent(newFolder, isDirectory: true)
        XCTAssertEqual(temp.names(in: directory).sorted(), ["meta.json", "source.md"])
    }

    func testOpeningAReplyThatIsNotThereThrows() async throws {
        let temp = try SyncTemporaryFolder()
        defer { temp.removeAll() }
        let coordinator = SyncCoordinatorTests.coordinator(temp: temp, store: SyncTestStore())

        do {
            _ = try await coordinator.ingestReply(fromReviewDirectory: "2026-08-18-nothing.review")
            XCTFail("there is nothing to open")
        } catch let error as PencilLoopError {
            guard case .nothingToIngest = error else {
                return XCTFail("expected .nothingToIngest, got \(error)")
            }
        }
    }

    // MARK: - Staging

    func testRefreshImportsWhatTheShareExtensionLeft() async throws {
        let temp = try SyncTemporaryFolder()
        defer { temp.removeAll() }
        try temp.writeStagedDirectory(named: "2026-08-18-shared-paper")
        let store = SyncTestStore()
        let coordinator = SyncCoordinator(
            folder: temp.folder,
            store: store,
            ingester: SyncTestIngester(),
            watcher: PollingFolderWatcher(pollInterval: 60),
            pinner: InboxItemPinner(destinationRoot: temp.pinnedRootURL),
            stagingImporter: AppGroupStagingImporter(stagingURL: temp.stagingURL),
            queue: OutboxQueue(rootURL: temp.queueRootURL),
            importsAppGroupStaging: true
        )

        let count = try await coordinator.refresh()

        XCTAssertEqual(count, 1)
        XCTAssertEqual(temp.inboxNames, ["2026-08-18-shared-paper"])
        let upserted = await store.upserted
        XCTAssertEqual(upserted.first?.folderName, "2026-08-18-shared-paper")
    }

    // MARK: - Fixtures

    static func coordinator(
        temp: SyncTemporaryFolder,
        store: SyncTestStore,
        ingester: SyncTestIngester = SyncTestIngester()
    ) -> SyncCoordinator {
        SyncCoordinator(
            folder: temp.folder,
            store: store,
            ingester: ingester,
            watcher: PollingFolderWatcher(pollInterval: 60),
            pinner: InboxItemPinner(destinationRoot: temp.pinnedRootURL),
            queue: OutboxQueue(rootURL: temp.queueRootURL),
            importsAppGroupStaging: false
        )
    }
}
