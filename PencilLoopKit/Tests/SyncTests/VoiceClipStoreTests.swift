//
//  VoiceClipStoreTests.swift
//  SyncTests
//
//  The upgrade queue, which is a directory
//  (notes/pencil-loop-cloud-dictation.md).
//
//  The behaviour worth pinning is what happens when things go wrong halfway:
//  audio written but the app killed before the sidecar, a sidecar naming audio
//  that is gone, a provider down for a day. None of those may cost a comment,
//  because the comment is already saved by the time any of this runs.
//

import XCTest
import Foundation
import Core
@testable import Sync

final class VoiceClipStoreTests: XCTestCase {

    private var root = URL(fileURLWithPath: "/dev/null")
    private var store = VoiceClipStore()

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("clips-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = VoiceClipStore(root: root)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    private func writeAudio(_ commentId: UUID) throws {
        try Data([0x66, 0x4C, 0x61, 0x43]).write(to: store.audioURL(forCommentId: commentId))
    }

    private func clip(
        _ commentId: UUID = UUID(),
        draft: String = "Ofgem's framework doesn't cover this.",
        createdAt: Date = Date()
    ) -> VoiceClip {
        VoiceClip(
            commentId: commentId,
            documentId: UUID(),
            draft: draft,
            language: "en-GB",
            keyterms: ["Ofgem", "RIIO-3"],
            createdAt: createdAt
        )
    }

    // MARK: - Queueing

    func testAClipWithAudioIsQueuedAndComesBack() throws {
        let pending = clip()
        try writeAudio(pending.commentId)

        XCTAssertTrue(store.enqueue(pending))

        let found = store.pending()
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.first?.commentId, pending.commentId)
        XCTAssertEqual(found.first?.keyterms, ["Ofgem", "RIIO-3"])
    }

    func testAClipWithNoAudioIsRefused() {
        XCTAssertFalse(
            store.enqueue(clip()),
            "A sidecar naming audio that is not there is a queue entry nothing can ever satisfy."
        )
        XCTAssertEqual(store.pending(), [])
    }

    func testTheQueueDrainsOldestFirst() throws {
        let old = clip(draft: "older", createdAt: Date(timeIntervalSince1970: 1_787_000_000))
        let new = clip(draft: "newer", createdAt: Date(timeIntervalSince1970: 1_787_000_900))
        try writeAudio(old.commentId)
        try writeAudio(new.commentId)
        store.enqueue(new)
        store.enqueue(old)

        XCTAssertEqual(store.pending().map(\.draft), ["older", "newer"])
    }

    func testAnEmptyQueueIsEmptyRatherThanAnError() {
        XCTAssertEqual(store.pending(), [])
    }

    func testAQueueDirectoryThatIsNotThereIsEmptyRatherThanAnError() {
        let missing = VoiceClipStore(root: root.appendingPathComponent("nope", isDirectory: true))

        XCTAssertEqual(missing.pending(), [])
        XCTAssertEqual(missing.sweep(), 0)
    }

    func testUnreadableSidecarsAreSkippedRatherThanHidingTheRest() throws {
        let good = clip(draft: "readable")
        try writeAudio(good.commentId)
        store.enqueue(good)
        let broken = UUID()
        try writeAudio(broken)
        try Data("{ not json".utf8).write(to: store.sidecarURL(forCommentId: broken))

        XCTAssertEqual(store.pending().map(\.draft), ["readable"])
    }

    // MARK: - Removing

    func testRemovingTakesBothFiles() throws {
        let done = clip()
        try writeAudio(done.commentId)
        store.enqueue(done)

        store.remove(commentId: done.commentId)

        XCTAssertEqual(store.pending(), [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.audioURL(forCommentId: done.commentId).path))
    }

    // MARK: - Sweeping

    func testAudioWithNoSidecarIsSweptAway() throws {
        // A recording whose comment was never saved: the reader cancelled, or
        // the save threw.
        let abandoned = UUID()
        try writeAudio(abandoned)

        XCTAssertEqual(store.sweep(), 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.audioURL(forCommentId: abandoned).path))
    }

    func testASidecarWithNoAudioIsSweptAway() throws {
        let orphan = clip()
        try writeAudio(orphan.commentId)
        store.enqueue(orphan)
        try FileManager.default.removeItem(at: store.audioURL(forCommentId: orphan.commentId))

        XCTAssertEqual(store.sweep(), 1)
        XCTAssertEqual(store.pending(), [])
    }

    func testSweepingLeavesCompletePairsAlone() throws {
        let waiting = clip()
        try writeAudio(waiting.commentId)
        store.enqueue(waiting)

        XCTAssertEqual(store.sweep(), 0)
        XCTAssertEqual(store.pending().count, 1)
    }

    // MARK: - Backoff

    func testAFailedAttemptComesBackLaterRatherThanImmediately() throws {
        let failing = clip()
        try writeAudio(failing.commentId)
        store.enqueue(failing)
        let now = Date()

        store.defer_(failing, at: now)

        let again = try XCTUnwrap(store.pending().first)
        XCTAssertEqual(again.attempts, 1)
        XCTAssertFalse(again.isDue(at: now), "A retry that is due immediately is not a backoff.")
        XCTAssertTrue(again.isDue(at: now.addingTimeInterval(3)))
    }

    func testBackoffLengthensWithEachAttempt() {
        let first = clip()
        let now = Date()
        let second = first.deferred(from: now)
        let third = second?.deferred(from: now)

        let firstGap = second?.nextAttemptAt.timeIntervalSince(now) ?? 0
        let secondGap = third?.nextAttemptAt.timeIntervalSince(now) ?? 0
        XCTAssertGreaterThan(secondGap, firstGap)
    }

    func testAfterADayOfTryingTheDraftStandsAndTheClipGoes() throws {
        let stale = clip(createdAt: Date(timeIntervalSinceNow: -VoiceClip.giveUpAfter - 60))
        try writeAudio(stale.commentId)
        store.enqueue(stale)

        XCTAssertNil(stale.deferred(), "A day of failing is enough; the draft is the transcript.")
        store.defer_(stale)

        XCTAssertEqual(store.pending(), [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.audioURL(forCommentId: stale.commentId).path))
    }
}
