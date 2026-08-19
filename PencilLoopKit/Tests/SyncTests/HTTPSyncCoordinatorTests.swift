//
//  HTTPSyncCoordinatorTests.swift
//  SyncTests
//
//  A deliberate port of `SyncCoordinatorTests`, with the same test names where
//  the behaviour is the same, so the two files diff cleanly and a rule that
//  holds on one transport can be seen to hold on the other.
//
//  The one that matters most is
//  `testIngestIsHandedPinnedLocalFilesOnly` — the executable form of CLAUDE.md
//  non-negotiable 2. A server makes fetch-on-open tempting in a way a folder
//  never did, and this is the test that would catch someone taking that path.
//

import XCTest
import Foundation
import Core
@testable import Sync

final class HTTPSyncCoordinatorTests: XCTestCase {

    private var root: URL!
    private var transport: SyncTestHTTPTransport!
    private var client: SyncServerClient!
    private var store: SyncTestStore!
    private var ingester: SyncTestIngester!

    private let base = URL(string: "https://relay.example.com")!

    override func setUp() async throws {
        try await super.setUp()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        transport = SyncTestHTTPTransport()
        client = SyncServerClient(baseURL: base, token: "test-token", transport: transport)
        store = SyncTestStore()
        ingester = SyncTestIngester()
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
        try await super.tearDown()
    }

    // MARK: - Fixtures

    private var pinnedRoot: URL { root.appendingPathComponent("pinned", isDirectory: true) }
    private var cursorRoot: URL { root.appendingPathComponent("cursor", isDirectory: true) }
    private var queueRoot: URL { root.appendingPathComponent("queue", isDirectory: true) }

    private func coordinator(pollInterval: TimeInterval = 3600) -> HTTPSyncCoordinator {
        HTTPSyncCoordinator(
            client: client,
            store: store,
            ingester: ingester,
            pinner: RemoteDocumentPinner(
                client: client,
                writer: PinnedDocumentWriter(destinationRoot: pinnedRoot)
            ),
            cursors: SyncCursorStore(rootURL: cursorRoot),
            queue: OutboxQueue(rootURL: queueRoot),
            pollInterval: pollInterval
        )
    }

    /// One document in the feed, with its two files routed and hashed so the
    /// pinner's verification has something real to check.
    @discardableResult
    private func offerDocument(
        folderName: String = "2026-08-18-auth-refactor-plan",
        seq: Int = 2,
        epoch: String = "epoch-1",
        cursor: Int? = nil
    ) async -> (source: Data, meta: Data) {
        let source = Data("# Auth refactor plan\n\nBody.\n".utf8)
        let meta = Data(#"{"id":"F7A1","title":"Auth refactor plan"}"#.utf8)

        await transport.route("/v1/documents/\(folderName)/files/source.md", bytes: source)
        await transport.route("/v1/documents/\(folderName)/files/meta.json", bytes: meta)
        await transport.route("/v1/changes", json: """
        {
          "epoch": "\(epoch)",
          "cursor": \(cursor ?? seq),
          "hasMore": false,
          "documents": [{
            "folderName": "\(folderName)",
            "documentId": "F7A1",
            "title": "Auth refactor plan",
            "seq": \(seq),
            "deletedAt": null,
            "files": [
              {"name": "source.md", "bytes": \(source.count), "sha256": "\(Self.hash(source))"},
              {"name": "meta.json", "bytes": \(meta.count), "sha256": "\(Self.hash(meta))"}
            ]
          }],
          "replies": []
        }
        """)
        return (source, meta)
    }

    private func emptyFeed(epoch: String = "epoch-1", cursor: Int = 0) async {
        await transport.route("/v1/changes", json: """
        {"epoch":"\(epoch)","cursor":\(cursor),"hasMore":false,"documents":[],"replies":[]}
        """)
    }

    private static func hash(_ data: Data) -> String {
        RemoteDocumentPinner.sha256Hex(data)
    }

    // MARK: - Non-negotiable 2

    func testIngestIsHandedPinnedLocalFilesOnly() async throws {
        await offerDocument()
        let ingested = try await coordinator().refresh()
        XCTAssertEqual(ingested, 1)

        let underPinnedRoot = await ingester.everyReceivedItemIsUnder(pinnedRoot)
        XCTAssertTrue(
            underPinnedRoot,
            "Ingest must never be handed a URL that points at the relay rather than the container"
        )
        let everyFileExists = await ingester.everyReceivedFileExists()
        XCTAssertTrue(everyFileExists, "Every byte must be on this device before ingest sees it")
    }

    func testABodyThatDoesNotMatchItsHashIsRefusedAndNothingIsIngested() async throws {
        await offerDocument()
        // The same size, different bytes — so only the hash can catch it.
        await transport.route(
            "/v1/documents/2026-08-18-auth-refactor-plan/files/source.md",
            bytes: Data("# Auth refactor plan\n\nBoby.\n".utf8)
        )

        let ingested = try await coordinator().refresh()
        XCTAssertEqual(ingested, 0)
        let received = await ingester.received
        XCTAssertTrue(received.isEmpty, "A corrupted download must not reach ingest")
    }

    // MARK: - Scanning

    func testADocumentInTheFeedIsIngestedAndStored() async throws {
        await offerDocument()
        let ingested = try await coordinator().refresh()

        XCTAssertEqual(ingested, 1)
        let upserted = await store.upserted
        XCTAssertEqual(upserted.count, 1)
        XCTAssertEqual(upserted.first?.folderName, "2026-08-18-auth-refactor-plan")
    }

    func testAnUnchangedDocumentIsNotIngestedTwice() async throws {
        await offerDocument()
        let subject = coordinator()

        let first = try await subject.refresh()
        let second = try await subject.refresh()

        XCTAssertEqual(first, 1)
        XCTAssertEqual(second, 0, "isPinnedAndCurrent must short-circuit before any byte is fetched")
        let attempts = await ingester.attempts(forFolderName: "2026-08-18-auth-refactor-plan")
        XCTAssertEqual(attempts, 1)
    }

    func testAFailedIngestBecomesAnErrorRowRatherThanADisappearance() async throws {
        await offerDocument()
        await ingester.fail(folderName: "2026-08-18-auth-refactor-plan", reason: "The PDF is truncated.")

        let ingested = try await coordinator().refresh()
        XCTAssertEqual(ingested, 0)

        // The recorded reason is the error's own display text, which is what the
        // library row shows — so it carries the folder name as well as the
        // cause, and the row reads as a sentence rather than a fragment.
        let failures = await store.failures
        let recorded = try XCTUnwrap(failures["2026-08-18-auth-refactor-plan"])
        XCTAssertTrue(recorded.contains("The PDF is truncated."), recorded)
    }

    func testAnUnusableFolderNameIsReportedRatherThanWritten() async throws {
        await offerDocument(folderName: "..")
        await transport.route("/v1/changes", json: """
        {"epoch":"e","cursor":2,"hasMore":false,"documents":[
          {"folderName":"../escape","documentId":"X","seq":2,"deletedAt":null,"files":[]}
        ],"replies":[]}
        """)

        let ingested = try await coordinator().refresh()
        XCTAssertEqual(ingested, 0)
        let received = await ingester.received
        XCTAssertTrue(received.isEmpty)
    }

    // MARK: - The cursor

    func testTheCursorAdvancesOnlyAfterACleanPage() async throws {
        await offerDocument()
        await ingester.fail(folderName: "2026-08-18-auth-refactor-plan", reason: "Not this time.")

        let subject = coordinator()
        _ = try? await subject.refresh()

        let cursors = SyncCursorStore(rootURL: cursorRoot)
        XCTAssertNil(
            cursors.cursor(forBaseURL: base, epoch: nil),
            "A page in which something failed must be re-listed, not skipped past"
        )
    }

    func testACleanPageSavesTheCursorAndTheEpoch() async throws {
        await offerDocument(seq: 7, epoch: "epoch-9", cursor: 7)
        _ = try await coordinator().refresh()

        let state = SyncCursorStore(rootURL: cursorRoot).state(forBaseURL: base)
        XCTAssertEqual(state?.cursor, 7)
        XCTAssertEqual(state?.epoch, "epoch-9")
    }

    func testAReindexedRelayIsReListedFromTheStart() async throws {
        await offerDocument(seq: 4, epoch: "epoch-1", cursor: 4)
        let subject = coordinator()
        _ = try await subject.refresh()

        // The relay rebuilt its index: same document, new epoch and renumbered.
        await offerDocument(seq: 1, epoch: "epoch-2", cursor: 1)
        _ = try await subject.start()

        let state = SyncCursorStore(rootURL: cursorRoot).state(forBaseURL: base)
        XCTAssertEqual(state?.epoch, "epoch-2", "An unfamiliar epoch must reset the cursor")
    }

    // MARK: - Offline

    func testAnUnreachableRelayReportsItselfRatherThanThrowingAtTheReader() async throws {
        await emptyFeed()
        let subject = coordinator()
        let stream = subject.events()
        await transport.set(mode: .offline)

        // Explicitly typed, because the first `return` would otherwise infer a
        // non-optional and the fallthrough could not compile.
        let listening = Task<String?, Never> {
            for await event in stream {
                if case let .folderUnavailable(reason) = event { return reason }
            }
            return nil
        }

        _ = try? await subject.refresh()

        // A guard against hanging the suite for ever if the event never comes:
        // cancelling ends the `for await`, so `value` always resolves.
        let deadline = Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            listening.cancel()
        }
        let reason = await listening.value
        deadline.cancel()

        XCTAssertNotNil(reason, "Losing the relay is a sentence in the status line, not a throw")
        XCTAssertFalse(reason?.isEmpty ?? true, "and it has to actually say something")
    }

    func testAReviewThatCannotBeSentIsQueuedRatherThanLost() async throws {
        await transport.set(mode: .offline)

        let written = try await coordinator().send(Self.reviewPayload())

        XCTAssertTrue(written.isQueued, "The sheet shows 'will send when online' from this flag")
        let waiting = OutboxQueue(rootURL: queueRoot).queuedPayloads()
        XCTAssertEqual(waiting.count, 1)
        XCTAssertEqual(waiting.first?.directoryName, "2026-08-18-auth-refactor-plan.review")
    }

    func testAQueuedReviewIsFlushedOnTheNextScan() async throws {
        await transport.set(mode: .offline)
        let subject = coordinator()
        _ = try await subject.send(Self.reviewPayload())

        await transport.set(mode: .routed)
        await emptyFeed()
        await transport.route("/v1/documents/2026-08-18-auth-refactor-plan/review", json: "{}")
        await transport.route(
            "/v1/reviews/2026-08-18-auth-refactor-plan/files/ink/page-01.png",
            json: "{}"
        )

        _ = try await subject.refresh()

        let waiting = OutboxQueue(rootURL: queueRoot).queuedPayloads()
        XCTAssertTrue(waiting.isEmpty, "A delivered bundle must leave the queue")
    }

    func testTheServerQueueIsSeparateFromTheFolderQueue() {
        XCTAssertNotEqual(
            HTTPSyncCoordinator.defaultQueueRootURL(),
            OutboxQueue.defaultRootURL(),
            "A review queued on one transport must never flush to the other"
        )
    }

    // MARK: - Sending

    func testAReviewIsDeclaredBeforeItsInkIsUploaded() async throws {
        await emptyFeed()
        await transport.route("/v1/documents/2026-08-18-auth-refactor-plan/review", json: "{}")
        await transport.route(
            "/v1/reviews/2026-08-18-auth-refactor-plan/files/ink/page-01.png",
            json: "{}"
        )

        let written = try await coordinator().send(Self.reviewPayload())
        XCTAssertFalse(written.isQueued)

        let paths = await transport.requestedPaths
        let declaration = paths.firstIndex(of: "/v1/documents/2026-08-18-auth-refactor-plan/review")
        let ink = paths.firstIndex(of: "/v1/reviews/2026-08-18-auth-refactor-plan/files/ink/page-01.png")
        XCTAssertNotNil(declaration)
        XCTAssertNotNil(ink)
        if let declaration, let ink {
            XCTAssertLessThan(declaration, ink, "The manifest is the parts list; it goes first")
        }
    }

    func testABundleWithoutAManifestIsRefusedRatherThanHalfSent() async throws {
        let payload = OutboxPayload(
            directoryName: "2026-08-18-auth-refactor-plan.review",
            documentId: UUID(),
            files: [BundleFile(relativePath: "review.md", data: Data("# Review\n".utf8))]
        )
        do {
            _ = try await coordinator().send(payload)
            XCTFail("A bundle with no manifest must not be uploaded")
        } catch let error as PencilLoopError {
            guard case .outboxWriteFailed = error else {
                return XCTFail("Expected .outboxWriteFailed, got \(error)")
            }
        }
    }

    // MARK: - Naming

    func testAReviewDirectoryNameResolvesToItsDocument() {
        XCTAssertEqual(
            HTTPSyncCoordinator.documentFolderName(fromReviewDirectory: "2026-08-18-plan.review"),
            "2026-08-18-plan"
        )
        XCTAssertEqual(
            HTTPSyncCoordinator.documentFolderName(fromReviewDirectory: "2026-08-18-plan"),
            "2026-08-18-plan"
        )
    }

    func testAReplyTitleDropsTheDatePrefix() {
        XCTAssertEqual(
            HTTPSyncCoordinator.replyTitle(for: "2026-08-18-auth-refactor-plan"),
            "Reply — auth refactor plan"
        )
    }

    // MARK: - Helpers

    private static func reviewPayload() -> OutboxPayload {
        let review = Data("# Review — Auth refactor plan\n".utf8)
        let ink = Data("\u{89}PNG fake".utf8)
        let manifest = Data("""
        {"version":1,"documentId":"F7A1","reviewFolder":"2026-08-18-auth-refactor-plan.review",
         "files":[{"path":"review.md"},{"path":"ink/page-01.png"}]}
        """.utf8)
        return OutboxPayload(
            directoryName: "2026-08-18-auth-refactor-plan.review",
            documentId: UUID(),
            files: [
                BundleFile(relativePath: "review.md", data: review),
                BundleFile(relativePath: "manifest.json", data: manifest),
                BundleFile(relativePath: "ink/page-01.png", data: ink),
            ]
        )
    }
}
