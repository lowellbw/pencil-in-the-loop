//
//  TranscriptUpgradeQueueTests.swift
//  SyncTests
//
//  Draft, then upgrade (notes/pencil-loop-cloud-dictation.md) — the half that
//  runs on the iPad, against a relay that only exists in memory.
//
//  What is pinned: a better transcript replaces the draft and says which
//  document it was on; a comment the reader has edited by hand is left alone;
//  a provider that fails costs a retry and never the draft; and the coordinator
//  tells its listeners, because the reader is still showing the old words.
//

import XCTest
import Foundation
import Core
@testable import Sync

final class TranscriptUpgradeQueueTests: XCTestCase {

    private var root: URL!
    private var transport: SyncTestHTTPTransport!
    private var client: SyncServerClient!
    private var store: SyncTestStore!
    private var clips: VoiceClipStore!

    private let base = URL(string: "https://relay.example.com")!
    private let documentId = UUID()

    override func setUp() async throws {
        try await super.setUp()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("upgrade-tests-" + UUID().uuidString, isDirectory: true)
        let clipsRoot = root.appendingPathComponent("Clips", isDirectory: true)
        try FileManager.default.createDirectory(at: clipsRoot, withIntermediateDirectories: true)
        transport = SyncTestHTTPTransport()
        client = SyncServerClient(baseURL: base, token: "test-token", transport: transport)
        store = SyncTestStore()
        clips = VoiceClipStore(root: clipsRoot)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
        try await super.tearDown()
    }

    // MARK: - Fixtures

    private static let anchor = Anchor(
        quoted: "the price control",
        prefix: "conflicts with ",
        suffix: " in force",
        pageIndex: 0,
        normalisedRect: NormalisedRect(x: 0.1, y: 0.2, width: 0.3, height: 0.04),
        sourceRange: nil
    )

    /// A voice comment in the store, and its recording in the queue.
    ///
    /// - Parameter storedText: what the comment says now, when the reader has
    ///   edited it since the draft was saved.
    @discardableResult
    private func queueComment(
        draft: String = "Ofcom's R I O three framework",
        storedText: String? = nil
    ) async throws -> VoiceClip {
        let comment = CommentSnapshot(
            id: UUID(),
            createdAt: Date(timeIntervalSince1970: 0),
            text: storedText ?? draft,
            source: .voice,
            anchor: Self.anchor,
            resolvedOnPage: 0
        )
        await store.seed(comment, documentId: documentId)
        try Data([0x66, 0x4C, 0x61, 0x43]).write(to: clips.audioURL(forCommentId: comment.id))
        let clip = VoiceClip(
            commentId: comment.id,
            documentId: documentId,
            draft: draft,
            language: "en-GB",
            keyterms: ["Ofgem", "RIIO-3"]
        )
        XCTAssertTrue(clips.enqueue(clip))
        return clip
    }

    /// The relay accepting the declaration and answering the upload with `text`.
    private func relayAnswers(_ text: String, for clip: VoiceClip) async {
        await transport.route(
            "/v1/clips",
            json: #"{"clipId":"\#(clip.commentId.uuidString)"}"#,
            status: 201
        )
        await transport.route(
            "/v1/clips/\(clip.commentId.uuidString)/audio",
            json: #"{"ok":true,"text":"\#(text)"}"#
        )
    }

    private func queue() -> TranscriptUpgradeQueue {
        TranscriptUpgradeQueue(client: client, store: store, clips: clips)
    }

    // MARK: - Applying

    func testABetterTranscriptReplacesTheDraftAndNamesTheDocument() async throws {
        let clip = try await queueComment()
        await relayAnswers("Ofgem's RIIO-3 framework", for: clip)

        let applied = await queue().drain()

        XCTAssertEqual(applied, [documentId: [clip.commentId]])
        let stored = try await store.comments(documentId: documentId)
        XCTAssertEqual(stored.first?.text, "Ofgem's RIIO-3 framework")
        XCTAssertTrue(clips.pending().isEmpty, "An upgraded clip is done with.")
        let paths = await transport.requestedPaths
        XCTAssertEqual(paths, ["/v1/clips", "/v1/clips/\(clip.commentId.uuidString)/audio"])
    }

    func testACommentEditedByHandIsLeftAlone() async throws {
        let edited = "Ofgem's framework — I rewrote this myself"
        let clip = try await queueComment(storedText: edited)
        await relayAnswers("Ofgem's RIIO-3 framework", for: clip)

        let applied = await queue().drain()

        XCTAssertEqual(applied, [:])
        let stored = try await store.comments(documentId: documentId)
        XCTAssertEqual(stored.first?.text, edited)
        XCTAssertTrue(clips.pending().isEmpty, "A late upgrade for an edited comment is dropped, not retried.")
    }

    func testTheSameWordsBackChangesNothing() async throws {
        let clip = try await queueComment(draft: "Already right.")
        await relayAnswers("Already right.", for: clip)

        let applied = await queue().drain()

        XCTAssertEqual(applied, [:])
        XCTAssertTrue(clips.pending().isEmpty)
    }

    // MARK: - Failing

    func testAProviderFailureKeepsTheDraftAndTheClipForLater() async throws {
        let clip = try await queueComment()
        await transport.set(mode: .everythingFails(status: 502))

        let applied = await queue().drain()

        XCTAssertEqual(applied, [:])
        let stored = try await store.comments(documentId: documentId)
        XCTAssertEqual(stored.first?.text, clip.draft)
        let waiting = clips.pending()
        XCTAssertEqual(waiting.map(\.commentId), [clip.commentId])
        XCTAssertEqual(waiting.first?.attempts, 1)
        XCTAssertFalse(waiting.first?.isDue() ?? true, "A failed clip backs off rather than retrying at once.")
    }

    func testAnEmptyAnswerIsAFailureNotAnEmptyComment() async throws {
        let clip = try await queueComment()
        await relayAnswers("", for: clip)

        let applied = await queue().drain()

        XCTAssertEqual(applied, [:])
        let stored = try await store.comments(documentId: documentId)
        XCTAssertEqual(stored.first?.text, clip.draft)
        XCTAssertEqual(clips.pending().count, 1)
    }

    // MARK: - Telling the reader

    func testTheCoordinatorAnnouncesAnUpgradeToItsListeners() async throws {
        let clip = try await queueComment()
        await relayAnswers("Ofgem's RIIO-3 framework", for: clip)
        await transport.route(
            "/v1/changes",
            json: #"{"epoch":"epoch-1","cursor":0,"hasMore":false,"documents":[],"replies":[]}"#
        )

        let coordinator = HTTPSyncCoordinator(
            client: client,
            store: store,
            ingester: SyncTestIngester(),
            pinner: RemoteDocumentPinner(
                client: client,
                writer: PinnedDocumentWriter(destinationRoot: root.appendingPathComponent("pinned"))
            ),
            cursors: SyncCursorStore(rootURL: root.appendingPathComponent("cursor")),
            queue: OutboxQueue(rootURL: root.appendingPathComponent("queue")),
            upgrades: queue(),
            pollInterval: 3600
        )
        let stream = coordinator.events()
        let listening = Task<(UUID, [UUID])?, Never> {
            for await event in stream {
                if case let .transcriptsUpgraded(documentId, commentIds) = event {
                    return (documentId, commentIds)
                }
            }
            return nil
        }

        _ = try await coordinator.refresh()

        // A guard against hanging the suite if the event never comes:
        // cancelling ends the `for await`, so `value` always resolves.
        let deadline = Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            listening.cancel()
        }
        let announced = await listening.value
        deadline.cancel()

        XCTAssertEqual(announced?.0, documentId)
        XCTAssertEqual(announced?.1, [clip.commentId])
    }
}
