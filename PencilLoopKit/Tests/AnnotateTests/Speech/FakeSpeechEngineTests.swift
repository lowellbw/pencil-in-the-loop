//
//  FakeSpeechEngineTests.swift
//  AnnotateTests · Speech
//
//  Two jobs. It checks the awkward corners of the `SpeechTranscribing` contract
//  that Wave 2 will rely on, and it wires a scripted engine to
//  `VoiceRecordingMachine` and `TermListCorrector` so the whole F4 flow is
//  exercised end to end without a microphone.
//

import XCTest
import Core
@testable import Annotate

final class FakeSpeechEngineTests: XCTestCase {

    // MARK: Asset state

    func testAssetStateWalksFromUnavailableToReady() async {
        let engine = FakeSpeechEngine(script: .init(states: [
            .unavailable(reason: "The British English dictation model hasn't downloaded yet."),
            .downloading(progress: nil),
            .downloading(progress: 0.6),
            .ready
        ]))

        guard case .unavailable = await engine.assetState() else {
            return XCTFail("expected the first state to be unavailable")
        }

        await engine.prepareAssets()
        await engine.advanceAssetState()
        let queued = await engine.assetState()
        XCTAssertEqual(queued, .downloading(progress: nil))

        await engine.advanceAssetState()
        let running = await engine.assetState()
        XCTAssertEqual(running, .downloading(progress: 0.6))

        await engine.advanceAssetState()
        let ready = await engine.assetState()
        XCTAssertEqual(ready, .ready)
    }

    func testPreparingAssetsTwiceIsHarmless() async {
        let engine = FakeSpeechEngine()
        await engine.prepareAssets()
        await engine.prepareAssets()

        let calls = await engine.prepareCount
        let state = await engine.assetState()
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(state, .ready)
    }

    func testAssetStateIsPollableWithoutARecording() async {
        let engine = FakeSpeechEngine()
        for _ in 0..<5 {
            let state = await engine.assetState()
            XCTAssertEqual(state, .ready)
        }
        let started = await engine.startCount
        XCTAssertEqual(started, 0)
    }

    // MARK: Lifecycle

    func testStoppingWhenNothingIsRunningReturnsNothing() async {
        let engine = FakeSpeechEngine(script: .init(finalText: "never spoken"))
        let text = await engine.stop()
        XCTAssertEqual(text, "")
    }

    func testTheDocumentTermsReachTheEngine() async {
        let engine = FakeSpeechEngine()
        _ = engine.transcribe(contextualTerms: ["AnchorResolver", "normalisedRect"])
        _ = await engine.waitForStart(1)

        let received = await engine.receivedTerms
        XCTAssertEqual(received, ["AnchorResolver", "normalisedRect"])
    }

    func testTheStreamYieldsTheScriptAndStopReturnsTheFinalText() async throws {
        let engine = FakeSpeechEngine(script: .init(
            updates: [
                TranscriptionUpdate(volatileText: "this par", finalisedText: ""),
                TranscriptionUpdate(volatileText: "", finalisedText: "this paragraph")
            ],
            finalText: "this paragraph is unclear"
        ))

        var iterator = engine.transcribe(contextualTerms: []).makeAsyncIterator()
        let first = try await iterator.next()
        let second = try await iterator.next()

        let settled = await engine.stop()
        XCTAssertEqual(first?.displayText, "this par")
        XCTAssertEqual(second?.displayText, "this paragraph")
        XCTAssertEqual(settled, "this paragraph is unclear")
    }

    func testAnEngineThatCannotStartThrowsRatherThanHanging() async {
        let engine = FakeSpeechEngine(script: .init(
            failure: .permissionDenied(what: "Microphone")
        ))

        do {
            for try await _ in engine.transcribe(contextualTerms: []) {
                XCTFail("a failing engine must not yield")
            }
            XCTFail("the stream should have thrown")
        } catch let error as PencilLoopError {
            XCTAssertEqual(error, .permissionDenied(what: "Microphone"))
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testASecondRecordingFinishesTheFirstStream() async {
        let engine = FakeSpeechEngine(script: .init(finalText: "second"))

        let first = engine.transcribe(contextualTerms: ["one"])
        let drained = Task { () -> Error? in
            do {
                for try await _ in first {}
                return nil
            } catch {
                return error
            }
        }
        _ = await engine.waitForStart(1)

        _ = engine.transcribe(contextualTerms: ["two"])
        _ = await engine.waitForStart(2)

        let outcome = await drained.value
        let received = await engine.receivedTerms
        XCTAssertEqual(
            outcome as? PencilLoopError,
            .speechUnavailable(reason: "Another recording started.")
        )
        XCTAssertEqual(received, ["two"])
    }

    // MARK: The whole of F4

    func testAHeldRecordingBecomesACorrectedComment() async throws {
        let terms = ["AnchorResolver", "normalisedRect"]
        let engine = FakeSpeechEngine(script: .init(
            updates: [
                TranscriptionUpdate(volatileText: "the anchorresolvor", finalisedText: ""),
                TranscriptionUpdate(volatileText: "", finalisedText: "the anchorresolvor step")
            ],
            finalText: "the anchorresolvor step"
        ))

        var machine = VoiceRecordingMachine()
        let press = Date(timeIntervalSinceReferenceDate: 2_000)
        _ = machine.handle(.touchDown(at: press))
        XCTAssertTrue(machine.handle(.holdRecognised(at: press)).contains(.startTranscribing))

        var iterator = engine.transcribe(contextualTerms: terms).makeAsyncIterator()
        for _ in 0..<2 {
            if let update = try await iterator.next() {
                _ = machine.handle(.transcriptUpdated(update))
            }
        }
        XCTAssertEqual(machine.update.displayText, "the anchorresolvor step")

        _ = machine.handle(.touchUp(at: press.addingTimeInterval(1.2)))
        let settled = await engine.stop()
        _ = machine.handle(.finalText(settled))

        let saved = try XCTUnwrap(machine.savedText)
        let corrected = TermListCorrector().correct(saved, against: terms)
        XCTAssertEqual(corrected, "the AnchorResolver step")
    }

    func testAMisTouchNeverReachesTheCorrectorOrTheStore() async {
        let engine = FakeSpeechEngine(script: .init(finalText: "half a word"))

        var machine = VoiceRecordingMachine()
        let press = Date(timeIntervalSinceReferenceDate: 3_000)
        _ = machine.handle(.touchDown(at: press))
        _ = machine.handle(.holdRecognised(at: press))
        _ = engine.transcribe(contextualTerms: [])
        _ = await engine.waitForStart(1)

        let effects = machine.handle(.touchUp(at: press.addingTimeInterval(0.12)))
        _ = await engine.stop()

        let stops = await engine.stopCount
        XCTAssertTrue(effects.contains(.dismiss))
        XCTAssertNil(machine.savedText)
        XCTAssertEqual(stops, 1)
    }
}
