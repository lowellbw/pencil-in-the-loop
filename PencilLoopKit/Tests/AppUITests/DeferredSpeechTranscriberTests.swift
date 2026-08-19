//
//  DeferredSpeechTranscriberTests.swift
//  AppUITests
//
//  The two guarantees that make deferred engine building safe: one engine per
//  language however many callers ask at once, and a `stop()` that reaches the
//  engine the running stream is bound to.
//
//  Both were broken in the same way. `current()` suspended twice — the settings
//  read, then the factory — before assigning the engine, so the three calls the
//  comment popover makes within about 400ms (`assetState()` on present,
//  `prewarm()` on arming, `transcribe(contextualTerms:)` on the hold) each built
//  their own and the last assignment won. The mild cost was a pre-warm that
//  warmed an engine nobody used. The real one was a recording bound to one
//  engine and a `stop()` that read the field and reached another: it returned
//  "", `VoiceRecordingMachine` read that as `.nothingHeard`, and the comment the
//  user had just dictated was dropped.
//

import Foundation
import XCTest
@testable import AppUI
import Core

final class DeferredSpeechTranscriberTests: XCTestCase {

    // MARK: - One build, however many callers

    /// The popover's three calls, overlapping exactly as they do on device.
    func testConcurrentCallersShareOneBuild() async {
        let factory = AppUITestEngineFactory()
        let transcriber = DeferredSpeechTranscriber(
            settings: PreviewSettingsStore(),
            makeEngine: factory.makeEngine()
        )

        async let state = transcriber.assetState()
        async let warmed: Void = transcriber.prewarm()
        let stream = transcriber.transcribe(contextualTerms: [])
        let consumer = Task { for try await _ in stream {} }

        _ = await state
        await warmed
        await factory.waitForBuilds(1)
        let engine = await factory.engine(1)
        await engine?.waitUntilTranscribing()

        let built = await factory.buildCount
        XCTAssertEqual(built, 1, "Three overlapping callers must share one engine, not build three.")

        let warmCount = await engine?.prewarmCount
        XCTAssertEqual(warmCount, 1, "The pre-warm must land on the engine the recording then uses.")

        _ = await transcriber.stop()
        _ = await consumer.result
    }

    /// Nothing has been asked for, so there is nothing to stop and nothing to
    /// build in order to find that out.
    func testStopBeforeAnythingIsBuiltBuildsNothing() async {
        let factory = AppUITestEngineFactory()
        let transcriber = DeferredSpeechTranscriber(
            settings: PreviewSettingsStore(),
            makeEngine: factory.makeEngine()
        )

        let settled = await transcriber.stop()

        XCTAssertEqual(settled, "")
        let built = await factory.buildCount
        XCTAssertEqual(built, 0, "A stop with nothing running must not build an engine to ask.")
    }

    // MARK: - The engine a recording is bound to

    /// The language changes while a recording is running. The rebuild must not
    /// stop the engine the recording is on, and `stop()` must reach that engine
    /// rather than the one the field now holds.
    func testStopReachesTheRecordingEngineAcrossALanguageChange() async throws {
        let factory = AppUITestEngineFactory()
        let settings = PreviewSettingsStore(
            settings: AppSettings(transcriptionLocaleIdentifier: "en-GB")
        )
        let transcriber = DeferredSpeechTranscriber(
            settings: settings,
            makeEngine: factory.makeEngine()
        )

        let stream = transcriber.transcribe(contextualTerms: [])
        let consumer = Task { for try await _ in stream {} }
        await factory.waitForBuilds(1)
        let recordingEngine = try XCTUnwrap(await factory.engine(1))
        await recordingEngine.waitUntilTranscribing()

        // Settings, mid-dictation.
        try await settings.update(AppSettings(transcriptionLocaleIdentifier: "fr-FR"))
        await transcriber.prewarm()
        await factory.waitForBuilds(2)
        let replacement = try XCTUnwrap(await factory.engine(2))

        let stoppedDuringRebuild = await recordingEngine.stopCount
        XCTAssertEqual(
            stoppedDuringRebuild,
            0,
            "Rebuilding for a new language must not stop the engine a recording is on."
        )

        let settled = await transcriber.stop()
        XCTAssertEqual(
            settled,
            recordingEngine.name,
            "stop() must reach the engine the stream resolved, not whatever the field holds."
        )
        let replacementStops = await replacement.stopCount
        XCTAssertEqual(replacementStops, 0, "The new engine was never recording; stopping it says nothing.")

        _ = await consumer.result
    }

    /// With nothing recording, a language change does retire the old engine —
    /// a pre-warmed one holds the audio session, and leaking it is how the
    /// microphone indicator stays lit.
    func testALanguageChangeStopsAnIdleEngine() async throws {
        let factory = AppUITestEngineFactory()
        let settings = PreviewSettingsStore(
            settings: AppSettings(transcriptionLocaleIdentifier: "en-GB")
        )
        let transcriber = DeferredSpeechTranscriber(
            settings: settings,
            makeEngine: factory.makeEngine()
        )

        await transcriber.prewarm()
        let first = try XCTUnwrap(await factory.engine(1))

        try await settings.update(AppSettings(transcriptionLocaleIdentifier: "fr-FR"))
        await transcriber.prewarm()

        let built = await factory.buildCount
        XCTAssertEqual(built, 2, "A language the engine was not built for needs a new engine.")
        let stops = await first.stopCount
        XCTAssertEqual(stops, 1, "The engine the language change replaced must be stopped exactly once.")
    }
}
