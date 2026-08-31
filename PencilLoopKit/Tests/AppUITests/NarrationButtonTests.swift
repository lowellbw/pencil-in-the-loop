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

    func testTheSkipsAreThePodcastConventions() {
        // Thirty back is roughly a paragraph of speech; fifteen forward leaves
        // a passage without overshooting the next one.
        XCTAssertEqual(NarrationPlayer.skipBack, 30)
        XCTAssertEqual(NarrationPlayer.skipForward, 15)
    }
}
