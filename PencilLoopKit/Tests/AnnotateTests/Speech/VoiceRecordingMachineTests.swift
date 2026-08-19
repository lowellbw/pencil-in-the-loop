//
//  VoiceRecordingMachineTests.swift
//  AnnotateTests · Speech
//
//  Transcription cannot be unit tested and Pencil input cannot be simulated, so
//  this is where the dictation feature is actually proved: the gesture rules
//  from docs/02-spec.md § S3 and docs/04-flows.md § F4, with no engine, no
//  audio session and no clock.
//

import XCTest
import Core
@testable import Annotate

final class VoiceRecordingMachineTests: XCTestCase {

    // Zero, so that `start.addingTimeInterval(x).timeIntervalSince(start)` is
    // exactly `x`. From any other epoch the boundary test below would be
    // measuring double rounding rather than the 0.3s rule.
    private let start = Date(timeIntervalSinceReferenceDate: 0)

    private func heldMachine(from moment: Date? = nil) -> VoiceRecordingMachine {
        var machine = VoiceRecordingMachine()
        let began = moment ?? start
        _ = machine.handle(.touchDown(at: began))
        _ = machine.handle(.holdRecognised(at: began))
        return machine
    }

    // MARK: Arming

    func testTouchDownPrewarmsWithoutRecording() {
        var machine = VoiceRecordingMachine()
        let effects = machine.handle(.touchDown(at: start))

        XCTAssertEqual(effects, [.prewarmCapture])
        XCTAssertFalse(machine.isRecording)
        XCTAssertFalse(machine.isFinished)
    }

    func testLiftBeforeTheHoldIsRecognisedLeavesNothingBehind() {
        var machine = VoiceRecordingMachine()
        _ = machine.handle(.touchDown(at: start))
        let effects = machine.handle(.touchUp(at: start.addingTimeInterval(0.2)))

        XCTAssertEqual(effects, [.releaseCapture])
        XCTAssertEqual(machine.phase, .idle)
        XCTAssertNil(machine.savedText)
    }

    func testSqueezeCanStartRecordingWithoutAPriorTouchDown() {
        var machine = VoiceRecordingMachine()
        let effects = machine.handle(.holdRecognised(at: start))

        XCTAssertEqual(effects, [.prewarmCapture, .startTranscribing])
        XCTAssertTrue(machine.isRecording)
    }

    // MARK: The 0.3s rule

    func testLiftUnderThreeHundredMillisecondsIsAMisTouchAndDiscards() {
        var machine = heldMachine()
        let effects = machine.handle(.touchUp(at: start.addingTimeInterval(0.29)))

        XCTAssertEqual(effects, [.stopTranscribing, .releaseCapture, .dismiss])
        XCTAssertFalse(effects.contains { effect in
            if case .commit = effect { return true }
            return false
        })
        guard case let .discarded(reason) = machine.phase else {
            return XCTFail("expected a discard, got \(machine.phase)")
        }
        guard case let .misTouch(held) = reason else {
            return XCTFail("expected a mis-touch, got \(reason)")
        }
        XCTAssertEqual(held, 0.29, accuracy: 0.001)
        XCTAssertNil(machine.savedText)
    }

    func testAMisTouchIgnoresAnyLateFinalText() {
        var machine = heldMachine()
        _ = machine.handle(.touchUp(at: start.addingTimeInterval(0.1)))
        let effects = machine.handle(.finalText("this should never be saved"))

        XCTAssertEqual(effects, [])
        XCTAssertNil(machine.savedText)
    }

    func testExactlyThreeHundredMillisecondsIsAHoldNotAMisTouch() {
        var machine = heldMachine()
        let effects = machine.handle(
            .touchUp(at: start.addingTimeInterval(GestureTiming.minimumHoldDuration))
        )

        XCTAssertEqual(effects, [.stopTranscribing])
        guard case .finishing = machine.phase else {
            return XCTFail("expected finishing, got \(machine.phase)")
        }
    }

    // MARK: Saving

    func testAHeldRecordingCommitsTheFinalText() {
        var machine = heldMachine()
        _ = machine.handle(.transcriptUpdated(
            TranscriptionUpdate(volatileText: " and the anchor", finalisedText: "This paragraph")
        ))
        _ = machine.handle(.touchUp(at: start.addingTimeInterval(2)))
        let effects = machine.handle(.finalText("This paragraph and the anchor drift."))

        XCTAssertEqual(
            effects,
            [.commit(text: "This paragraph and the anchor drift."), .releaseCapture]
        )
        XCTAssertEqual(machine.savedText, "This paragraph and the anchor drift.")
        XCTAssertTrue(machine.isFinished)
    }

    func testTheEngineFinalTextWinsOverTheLastStreamedUpdate() {
        var machine = heldMachine()
        _ = machine.handle(.transcriptUpdated(
            TranscriptionUpdate(volatileText: "check thi", finalisedText: "")
        ))
        _ = machine.handle(.touchUp(at: start.addingTimeInterval(1)))
        _ = machine.handle(.finalText("check this citation"))

        XCTAssertEqual(machine.savedText, "check this citation")
    }

    func testAnEmptyFinalTextFallsBackToWhatWasStreamed() {
        var machine = heldMachine()
        _ = machine.handle(.transcriptUpdated(
            TranscriptionUpdate(volatileText: "", finalisedText: "the fallback engine settled this")
        ))
        _ = machine.handle(.touchUp(at: start.addingTimeInterval(1)))
        _ = machine.handle(.finalText("   "))

        XCTAssertEqual(machine.savedText, "the fallback engine settled this")
    }

    func testSilenceDiscardsRatherThanSavingAnEmptyComment() {
        var machine = heldMachine()
        _ = machine.handle(.touchUp(at: start.addingTimeInterval(1)))
        let effects = machine.handle(.finalText(""))

        XCTAssertEqual(effects, [.releaseCapture, .dismiss])
        XCTAssertEqual(machine.phase, .discarded(reason: .nothingHeard))
        XCTAssertNil(machine.savedText)
    }

    func testAnUpdateArrivingAfterTheLiftIsStillKept() {
        var machine = heldMachine()
        _ = machine.handle(.touchUp(at: start.addingTimeInterval(1)))
        _ = machine.handle(.transcriptUpdated(
            TranscriptionUpdate(volatileText: "", finalisedText: "a trailing word")
        ))

        XCTAssertEqual(machine.update.finalisedText, "a trailing word")
    }

    // MARK: Failure and cancellation

    func testAFailureLeavesThePopoverOpenForScribble() {
        var machine = heldMachine()
        let effects = machine.handle(.failed(.speechUnavailable(reason: "No assets.")))

        XCTAssertEqual(effects, [.stopTranscribing, .releaseCapture])
        XCTAssertFalse(effects.contains(.dismiss))
        XCTAssertEqual(machine.phase, .failed(error: .speechUnavailable(reason: "No assets.")))
    }

    func testCancellingMidRecordingDiscards() {
        var machine = heldMachine()
        let effects = machine.handle(.cancelled)

        XCTAssertEqual(effects, [.stopTranscribing, .releaseCapture, .dismiss])
        XCTAssertEqual(machine.phase, .discarded(reason: .cancelled))
    }

    func testEveryTerminalPathReleasesTheMicrophone() {
        let endings: [[VoiceRecordingMachine.Event]] = [
            [.touchUp(at: start.addingTimeInterval(0.1))],
            [.touchUp(at: start.addingTimeInterval(1)), .finalText("saved")],
            [.touchUp(at: start.addingTimeInterval(1)), .finalText("")],
            [.cancelled],
            [.failed(.permissionDenied(what: "Microphone"))]
        ]

        for ending in endings {
            var machine = heldMachine()
            var effects: [VoiceRecordingMachine.Effect] = []
            for event in ending {
                effects += machine.handle(event)
            }
            XCTAssertTrue(
                effects.contains(.releaseCapture),
                "the microphone stayed open after \(ending)"
            )
        }
    }

    func testEventsAfterATerminalPhaseDoNothing() {
        var machine = heldMachine()
        _ = machine.handle(.touchUp(at: start.addingTimeInterval(1)))
        _ = machine.handle(.finalText("saved"))

        XCTAssertEqual(machine.handle(.touchUp(at: start.addingTimeInterval(3))), [])
        XCTAssertEqual(machine.handle(.cancelled), [])
        XCTAssertEqual(machine.handle(.finalText("something else")), [])
        XCTAssertEqual(machine.savedText, "saved")
    }
}
