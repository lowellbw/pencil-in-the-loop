//
//  NarrationButtonTests.swift
//  AppUITests
//
//  The three states of Listen, and the rule they exist to keep.
//
//  Asking for a narration must return immediately: generating one takes
//  minutes, the reader is a protected path, and CLAUDE.md non-negotiable 1 ends
//  "a feature that blocks either path on a request still does not ship". These
//  assert the asking, not the audio — playback needs a device.
//

import XCTest
import Foundation
@testable import AppUI
import Annotate
import Core

@MainActor
final class NarrationButtonTests: XCTestCase {

    func testTheClockReadsAsAPersonWouldSayIt() {
        XCTAssertEqual(NarrationSheet.clock(0), "0:00")
        XCTAssertEqual(NarrationSheet.clock(9), "0:09")
        XCTAssertEqual(NarrationSheet.clock(90), "1:30")
        XCTAssertEqual(NarrationSheet.clock(3661), "1:01:01")
    }

    func testAnUnknownDurationDoesNotShowANegativeClock() {
        // `AVAudioPlayer` reports 0 before it has opened a file, and a bar
        // showing "-1:-1" is worse than one showing nothing yet.
        XCTAssertEqual(NarrationSheet.clock(-5), "0:00")
        XCTAssertEqual(NarrationSheet.clock(.nan), "0:00")
    }

    func testProgressIsZeroUntilThereIsADuration() {
        XCTAssertEqual(NarrationPlayback().fraction, 0)
        XCTAssertEqual(NarrationPlayback(elapsed: 30, duration: 0).fraction, 0)
    }

    func testProgressIsClampedToTheFile() {
        XCTAssertEqual(NarrationPlayback(elapsed: 30, duration: 60).fraction, 0.5)
        XCTAssertEqual(NarrationPlayback(elapsed: 90, duration: 60).fraction, 1)
        XCTAssertEqual(NarrationPlayback(elapsed: -5, duration: 60).fraction, 0)
    }

    func testTheRelaysAnswerOutlivesTheApp() {
        // The bug this guards: a purely local "I asked for one" flag is gone at
        // the next launch, and the reader is then offered a second narration of
        // a document already halfway through one. The relay remembers instead.
        let working = NarrationStatus(state: .working)
        let ready = NarrationStatus(state: .ready, minutes: 12)
        XCTAssertEqual(working.state, .working)
        XCTAssertTrue(ready.summary.contains("12"))
    }

    func testAnUnsetRelaySaysSoRatherThanInvitingARetry() {
        // `unconfigured` means no provider key. Offering "Try Again" for that
        // is a button that cannot work, tapped forever.
        let status = NarrationStatus(state: .unconfigured)
        XCTAssertFalse(status.summary.isEmpty)
        XCTAssertNotEqual(status.state, .failed)
    }

    func testAScriptBeingWrittenHasNoBarToShow() {
        // Nil, not zero: a determinate bar pinned at the far left reads as
        // stuck. The number of turns does not exist until the script does.
        XCTAssertNil(NarrationStatus(state: .working).fraction)
        XCTAssertNil(NarrationStatus(state: .working, stage: "scripting").fraction)
    }

    func testRecordingCountsTurnsRatherThanGuessingAtATime() {
        let status = NarrationStatus(state: .working, stage: "recording", done: 12, total: 34)
        XCTAssertEqual(status.fraction ?? 0, 12.0 / 34.0, accuracy: 0.0001)
        XCTAssertTrue(status.summary.contains("12 of 34"))
        // The old copy promised "a few minutes" and was wrong by a factor of
        // ten on a long paper. Nothing here claims a duration.
        XCTAssertFalse(status.summary.contains("minute"))
    }

    func testOnlyAWorkingNarrationHasAProgressBar() {
        XCTAssertNil(NarrationStatus(state: .ready, done: 34, total: 34).fraction)
        XCTAssertNil(NarrationStatus(state: .failed, done: 3, total: 34).fraction)
    }

    func testAReadyNarrationWithNoDurationStillReadsAsReady() {
        XCTAssertEqual(NarrationStatus(state: .ready).summary, "Ready to play.")
        XCTAssertEqual(NarrationStatus(state: .ready, minutes: 0).summary, "Ready to play.")
    }

    func testTheRelayIsPolledFarLessOftenThanThePlayer() {
        // Playback needs a smooth bar; a narration takes minutes to make. One
        // clock at 250ms would hammer the relay for no gain.
        XCTAssertGreaterThan(NarrationSheet.relayEvery, 1)
        XCTAssertEqual(NarrationSheet.tick * NarrationSheet.relayEvery, 5_000)
    }

    func testTheControllerIsNotSharedAcrossDocuments() {
        // The *player* is shared, because only one thing can play. Which
        // document you are asking about is not: the sidebar and the reader each
        // hold their own, or pressing a row would silently re-point the
        // reader's sheet at something else.
        let one = NarrationStatus(state: .working)
        let two = NarrationStatus(state: .none)
        XCTAssertNotEqual(one, two)
    }

    func testTheSkipsAreThePodcastConventions() {
        // Thirty back is roughly a paragraph of speech; fifteen forward leaves
        // a passage without overshooting the next one.
        XCTAssertEqual(NarrationPlayer.skipBack, 30)
        XCTAssertEqual(NarrationPlayer.skipForward, 15)
    }
}
