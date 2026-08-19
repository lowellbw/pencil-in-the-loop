//
//  ContinuousTranscriberTests.swift
//  AnnotateTests · Speech
//
//  The reported bug, as a test: a voice note that stops on its own.
//
//  Both engines finish their stream *normally* when they decide an utterance is
//  over — no error, nothing thrown — so every `for try await` in the app fell
//  out of its loop with neither `catch` running, and the recording state was
//  never told. The row kept saying "Listening…" and the words went nowhere.
//
//  A real engine cannot be made to do that on demand, so the double below does
//  exactly it: yields a couple of updates, then finishes, exactly as
//  `SFSpeechRecognizer` does at end-of-speech.
//

import XCTest
import Foundation
import Core
@testable import Annotate

final class ContinuousTranscriberTests: XCTestCase {

    /// The bug. An engine that gives up after one utterance must not end the
    /// recording, and nothing said afterwards may be lost.
    func testAnEngineThatStopsOnItsOwnIsRestarted() async throws {
        let engine = SegmentedTranscriberDouble(segments: ["Hello there", "second thought", "third one"])
        let transcriber = ContinuousTranscriber(engine: engine)

        var seen: [String] = []
        for try await update in transcriber.transcribe(contextualTerms: []) {
            seen.append(update.displayText)
            if seen.count == 3 { break }
        }

        let starts = await engine.startCount
        XCTAssertEqual(starts, 3, "the engine should have been restarted twice")
        XCTAssertEqual(seen.last, "Hello there second thought third one")
    }

    /// Every update carries the whole recording, not the current segment. The
    /// consumers replace the field with `displayText` on each update, so a
    /// segment-relative value would erase everything said before it.
    func testEachUpdateCarriesEverythingSaidSoFar() async throws {
        let engine = SegmentedTranscriberDouble(segments: ["one", "two"])
        let transcriber = ContinuousTranscriber(engine: engine)

        var seen: [String] = []
        for try await update in transcriber.transcribe(contextualTerms: []) {
            seen.append(update.displayText)
            if seen.count == 2 { break }
        }

        XCTAssertEqual(seen, ["one", "one two"])
    }

    /// Stopping returns everything, across however many restarts happened.
    func testStopReturnsTheWholeRecording() async throws {
        let engine = SegmentedTranscriberDouble(segments: ["first part", "second part"])
        let transcriber = ContinuousTranscriber(engine: engine)

        let stream = transcriber.transcribe(contextualTerms: [])
        var iterator = stream.makeAsyncIterator()
        _ = try await iterator.next()
        _ = try await iterator.next()

        let everything = await transcriber.stop()
        XCTAssertEqual(everything, "first part second part")
    }

    /// A restart must not be able to spin. An engine failing instantly — the
    /// audio route taken by a call, permission revoked mid-recording — would
    /// otherwise be restarted for ever.
    func testAnEngineThatNeverTranscribesAnythingIsGivenUpOn() async throws {
        let engine = SegmentedTranscriberDouble(segments: [])
        let transcriber = ContinuousTranscriber(engine: engine)

        for try await _ in transcriber.transcribe(contextualTerms: []) {
            XCTFail("an engine transcribing nothing should yield nothing")
        }

        let started = await engine.startCount
        XCTAssertGreaterThan(started, 0, "it should have tried")
        XCTAssertLessThanOrEqual(started, 4, "but it must not retry for ever")
    }

    /// An engine that cannot start will not start on the second attempt either,
    /// so the error goes straight through rather than being retried.
    func testAFailureIsPassedThroughRatherThanRetried() async {
        let engine = SegmentedTranscriberDouble(segments: [], failure: .permissionDenied(what: "Microphone"))
        let transcriber = ContinuousTranscriber(engine: engine)

        do {
            for try await _ in transcriber.transcribe(contextualTerms: []) {}
            XCTFail("the failure should have been rethrown")
        } catch {
            let started = await engine.startCount
            XCTAssertEqual(started, 1, "a refusal should not be retried")
        }
    }

    /// An engine that yields one word per segment, then finishes normally —
    /// which is precisely what the real ones do at end-of-speech.
    private actor SegmentedTranscriberDouble: SpeechTranscribing {

        private let segments: [String]
        private let failure: PencilLoopError?
        private var index = 0
        private(set) var startCount = 0
        private var settled = ""

        init(segments: [String], failure: PencilLoopError? = nil) {
            self.segments = segments
            self.failure = failure
        }

        private func take() -> String? {
            guard index < segments.count else { return nil }
            defer { index += 1 }
            return segments[index]
        }

        private func remember(_ text: String) { settled = text }

        private func claimFailure() -> PencilLoopError? {
            startCount += 1
            return failure
        }

        nonisolated func transcribe(
            contextualTerms: [String]
        ) -> AsyncThrowingStream<TranscriptionUpdate, Error> {
            AsyncThrowingStream { continuation in
                Task {
                    if let failure = await self.claimFailure() {
                        continuation.finish(throwing: failure)
                        return
                    }
                    if let text = await self.take() {
                        await self.remember(text)
                        continuation.yield(TranscriptionUpdate(volatileText: "", finalisedText: text))
                    }
                    // And now the engine loses interest, without an error.
                    continuation.finish()
                }
            }
        }

        func stop() async -> String {
            let text = settled
            settled = ""
            return text
        }

        func assetState() async -> SpeechAssetState { .ready }
        func prepareAssets() async {}
        func prewarm() async {}
        func supportedLocales() async -> [Locale] { [] }
    }
}
