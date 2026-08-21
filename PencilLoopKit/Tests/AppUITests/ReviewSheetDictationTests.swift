//
//  ReviewSheetDictationTests.swift
//  AppUITests
//
//  What the review sheet does when a hold ends.
//
//  ─── THE BUG THIS EXISTS FOR ─────────────────────────────────────────────────
//  Holding to talk on the closing instruction and letting go reported
//  "Dictation is unavailable. Dictation stopped." and put back the text that had
//  just been spoken — every time, not intermittently.
//
//  Stopping an engine finishes its stream *normally*. The streaming task fell
//  out of its `for try await` loop, found `isDictatingInstruction` still true —
//  it is cleared by the stop task, which at that moment is still awaiting the
//  engine — and took the branch written for a recogniser that had died with the
//  user still talking. Whichever task won the race decided whether the user saw
//  an error, and the error usually won because `stop()` has real work to do.
//
//  Dictation itself cannot be unit tested (STYLE.md § 10). This is not a test of
//  dictation: it is a test of which of the two ways a stream can finish the
//  model treats as a failure, which is a rule, and which was wrong.
//  ─────────────────────────────────────────────────────────────────────────────
//

import Foundation
import XCTest
@testable import AppUI
import Core

@MainActor
final class ReviewSheetDictationTests: XCTestCase {

    /// The ordinary case: hold, speak, let go.
    func testReleasingAHoldKeepsWhatWasSaidAndReportsNothing() async {
        let engine = AppUITestSpeechEngine(name: "review", finalText: "Ship it on Friday.")
        let environment = AppUITestEnvironment(store: AppUITestStore(), transcriber: engine)
        let model = ReviewSheetModel(document: AppUITestSamples.detail())

        model.beginInstructionDictation(environment: environment)
        await engine.waitUntilTranscribing()
        model.endInstructionDictation(environment: environment)
        await settle(model)

        XCTAssertNil(
            model.failureMessage,
            "Letting go is how a hold ends. It is not a failure and must not read as one."
        )
        XCTAssertEqual(
            model.closingInstruction,
            "Ship it on Friday.",
            "The settled text is what the engine heard; the release must keep it."
        )
        XCTAssertFalse(model.isDictatingInstruction)
    }

    /// Whatever was typed before the hold is still there afterwards, with the
    /// spoken sentence added to it rather than replacing it.
    func testDictationAddsToWhatWasAlreadyTyped() async {
        let engine = AppUITestSpeechEngine(name: "review", finalText: "And check the migration.")
        let environment = AppUITestEnvironment(store: AppUITestStore(), transcriber: engine)
        let model = ReviewSheetModel(document: AppUITestSamples.detail())
        model.closingInstruction = "Read the comments in order."

        model.beginInstructionDictation(environment: environment)
        await engine.waitUntilTranscribing()
        model.endInstructionDictation(environment: environment)
        await settle(model)

        XCTAssertEqual(
            model.closingInstruction,
            "Read the comments in order. And check the migration."
        )
    }

    /// The failure that *is* one: the stream finishes with the user still
    /// holding. `PreviewSpeechTranscriber` finishes its stream immediately,
    /// which is exactly that shape.
    func testAStreamThatEndsOnItsOwnIsStillReported() async {
        let environment = AppUITestEnvironment(store: AppUITestStore())
        let model = ReviewSheetModel(document: AppUITestSamples.detail())
        model.closingInstruction = "Read the comments in order."

        model.beginInstructionDictation(environment: environment)
        await settle(model)

        XCTAssertNotNil(
            model.failureMessage,
            "A recogniser that stops while somebody is talking has to say so, or the row lies."
        )
        XCTAssertEqual(
            model.closingInstruction,
            "Read the comments in order.",
            "A recording that failed leaves the field exactly as it found it."
        )
    }

    /// A second press while the first is still handing the microphone back is
    /// ignored rather than raced. Two recordings resolve to one engine, and the
    /// second used to be refused with "Another recording is already running" —
    /// an error message for a double tap.
    func testAPressWhileStoppingIsIgnored() async {
        let engine = AppUITestSpeechEngine(name: "review", finalText: "Ship it.")
        let environment = AppUITestEnvironment(store: AppUITestStore(), transcriber: engine)
        let model = ReviewSheetModel(document: AppUITestSamples.detail())

        model.beginInstructionDictation(environment: environment)
        await engine.waitUntilTranscribing()
        model.endInstructionDictation(environment: environment)
        model.beginInstructionDictation(environment: environment)
        await settle(model)

        XCTAssertNil(model.failureMessage)
        let transcribes = await engine.transcribeCount
        XCTAssertEqual(transcribes, 1, "The second press must not start a second recording.")
    }

    /// Waits for the stop task to finish, bounded so a regression is a failed
    /// assertion rather than a hung suite. The model exposes no completion —
    /// nothing on device waits for one either.
    private func settle(_ model: ReviewSheetModel) async {
        for _ in 0..<400 {
            if model.isDictatingInstruction == false { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }
}
