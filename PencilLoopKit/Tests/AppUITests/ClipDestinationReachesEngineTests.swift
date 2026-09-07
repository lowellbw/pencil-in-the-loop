//
//  ClipDestinationReachesEngineTests.swift
//  AppUITests
//
//  The clip destination reaches the engine that records.
//
//  The comment popover sets it and then starts the recording — as two tasks,
//  back to back — and `DeferredSpeechTranscriber` used to store the destination
//  and never hand it to the engine it resolved. No audio was kept, nothing was
//  queued, and no voice comment was ever upgraded: the on-device draft was
//  silently the final transcript for a fortnight, with a relay waiting for
//  clips that never came (notes/pencil-loop-cloud-dictation.md).
//

import Foundation
import XCTest
@testable import AppUI
import Core

final class ClipDestinationReachesEngineTests: XCTestCase {

    /// Set the destination, then record. The engine the recording resolves to
    /// must receive it — the contract says the destination applies to the
    /// next recording (Protocols.swift § setClipDestination).
    func testDestinationSetBeforeRecordingReachesTheEngine() async throws {
        let factory = AppUITestEngineFactory()
        let transcriber = DeferredSpeechTranscriber(
            settings: PreviewSettingsStore(),
            makeEngine: factory.makeEngine()
        )
        let destination = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("clip-before.flac")

        await transcriber.setClipDestination(destination)

        let stream = transcriber.transcribe(contextualTerms: [])
        let consumer = Task { for try await _ in stream {} }
        await factory.waitForBuilds(1)
        let built = await factory.engine(1)
        let engine = try XCTUnwrap(built)
        await engine.waitUntilTranscribing()

        let seen = await engine.clipDestination
        XCTAssertEqual(seen, destination, "The engine that records must be told where to write the clip.")

        _ = await transcriber.stop()
        _ = await consumer.result
    }

    /// The shape `CommentCaptureModel.startTranscribing()` actually uses: the
    /// destination and the recording are two tasks started back to back, and
    /// which lands first is up to the scheduler.
    func testDestinationSetAlongsideRecordingReachesTheEngine() async throws {
        let factory = AppUITestEngineFactory()
        let transcriber = DeferredSpeechTranscriber(
            settings: PreviewSettingsStore(),
            makeEngine: factory.makeEngine()
        )
        let destination = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("clip-alongside.flac")

        let setting = Task { await transcriber.setClipDestination(destination) }
        let stream = transcriber.transcribe(contextualTerms: [])
        let consumer = Task { for try await _ in stream {} }
        await setting.value
        await factory.waitForBuilds(1)
        let built = await factory.engine(1)
        let engine = try XCTUnwrap(built)
        await engine.waitUntilTranscribing()

        let seen = await engine.clipDestination
        XCTAssertEqual(seen, destination, "The engine that records must be told where to write the clip.")

        _ = await transcriber.stop()
        _ = await consumer.result
    }

    /// Collecting the clip clears the destination, so the recording after it —
    /// the review sheet's closing instruction, say — writes no file.
    func testCollectingTheClipClearsTheDestinationForTheNextRecording() async throws {
        let factory = AppUITestEngineFactory()
        let transcriber = DeferredSpeechTranscriber(
            settings: PreviewSettingsStore(),
            makeEngine: factory.makeEngine()
        )
        let destination = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("clip-collected.flac")

        await transcriber.setClipDestination(destination)
        let first = transcriber.transcribe(contextualTerms: [])
        let firstConsumer = Task { for try await _ in first {} }
        await factory.waitForBuilds(1)
        let built = await factory.engine(1)
        let engine = try XCTUnwrap(built)
        await engine.waitUntilTranscribing()
        _ = await transcriber.stop()
        _ = await firstConsumer.result

        let collected = await transcriber.finishedClip()
        XCTAssertEqual(collected, destination)

        let second = transcriber.transcribe(contextualTerms: [])
        let secondConsumer = Task { for try await _ in second {} }
        await engine.waitUntilTranscribing(times: 2)
        _ = await transcriber.stop()
        _ = await secondConsumer.result

        let afterwards = await engine.clipDestination
        XCTAssertNil(afterwards, "A collected clip's destination must not be reused by the next recording.")
    }
}
