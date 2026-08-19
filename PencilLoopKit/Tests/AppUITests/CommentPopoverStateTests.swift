//
//  CommentPopoverStateTests.swift
//  AppUITests
//
//  The popover's own value type. Dictation cannot be run here — there is no
//  microphone and no device — but what the popover *shows* for each state is
//  pure, and that is what this checks (docs/02-spec.md § S3).
//

import CoreGraphics
import XCTest
@testable import AppUI
import Core

@MainActor
final class CommentPopoverStateTests: XCTestCase {

    private func state(
        mode: CommentPopoverState.Mode = .voice,
        stage: CommentPopoverState.Stage = .waiting,
        volatileText: String = "",
        finalisedText: String = "",
        scribbleText: String = "",
        isSpeechAvailable: Bool = true
    ) -> CommentPopoverState {
        CommentPopoverState(
            anchor: Anchor(
                quoted: "the retry loop",
                pageIndex: 0,
                normalisedRect: NormalisedRect(x: 0.1, y: 0.2, width: 0.6, height: 0.02)
            ),
            anchorPoint: CGPoint(x: 100, y: 200),
            mode: mode,
            stage: stage,
            update: TranscriptionUpdate(volatileText: volatileText, finalisedText: finalisedText),
            scribbleText: scribbleText,
            isSpeechAvailable: isSpeechAvailable
        )
    }

    // MARK: - What the transcript area reads

    func testVoiceShowsSettledTextFollowedByTheHypothesis() {
        let popover = state(volatileText: " and a 429", finalisedText: "What happens on a timeout")
        XCTAssertEqual(popover.displayText, "What happens on a timeout and a 429")
    }

    func testScribbleShowsTheScribbleFieldAndIgnoresTheTranscript() {
        let popover = state(
            mode: .scribble,
            volatileText: "left over",
            finalisedText: "from the recording",
            scribbleText: "No dual-write window."
        )
        XCTAssertEqual(
            popover.displayText,
            "No dual-write window.",
            "Switching to scribble discards what was spoken; showing it would be a lie about what will be saved."
        )
    }

    // MARK: - Emptiness

    func testAPopoverWithNothingInItIsEmpty() {
        XCTAssertTrue(state().isEmpty)
    }

    func testWhitespaceAndNewlinesAloneStillCountAsEmpty() {
        XCTAssertTrue(state(volatileText: "  \n\t ").isEmpty, "A placeholder is better than a gap that looks broken.")
    }

    func testOneRealCharacterIsNotEmpty() {
        XCTAssertFalse(state(finalisedText: " x ").isEmpty)
    }

    func testAScribbledSpaceIsEmptyToo() {
        XCTAssertTrue(state(mode: .scribble, scribbleText: "   ").isEmpty)
    }

    // MARK: - Stages

    func testOnlyRecordingIsRecording() {
        XCTAssertTrue(state(stage: .recording).isRecording)
        for stage in [
            CommentPopoverState.Stage.waiting,
            .finishing,
            .saving,
            .failed(message: "No.")
        ] {
            XCTAssertFalse(state(stage: stage).isRecording)
        }
    }

    func testAFailureCarriesItsSentenceAndNothingElseDoes() {
        XCTAssertEqual(state(stage: .failed(message: "Microphone access is off.")).failureMessage, "Microphone access is off.")
        XCTAssertNil(state(stage: .recording).failureMessage)
        XCTAssertNil(state(stage: .saving).failureMessage)
    }

    func testAFailedPopoverStillHasItsAnchorAndItsText() {
        // Not a dead end: the words stay on screen and the scribble hint is
        // still there (Protocols.swift § SpeechTranscribing).
        let popover = state(stage: .failed(message: "The engine stopped."), finalisedText: "Shadow read for a day")
        XCTAssertEqual(popover.displayText, "Shadow read for a day")
        XCTAssertEqual(popover.anchor.quoted, "the retry loop")
    }

    // MARK: - Identity

    func testTwoPopoversAreTwoPopovers() {
        XCTAssertNotEqual(state().id, state().id, "SwiftUI has to treat a second popover as a second popover.")
    }
}
