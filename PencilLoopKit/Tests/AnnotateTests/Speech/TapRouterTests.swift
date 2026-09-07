//
//  TapRouterTests.swift
//  AnnotateTests · Speech
//
//  The pre-roll, without a microphone: the newest second is kept, a recording
//  starts with it and not without it, and what was kept comes out in order.
//
//  The tap block itself cannot be exercised here (STYLE.md § 10), but every
//  decision it defers to the router can be, and those are the ones that decide
//  whether the first word of a comment is in the transcript.
//

import XCTest
import AVFoundation
import Foundation
@testable import Annotate

final class TapRouterTests: XCTestCase {

    private static let sampleRate: Double = 48_000

    /// One chunk of silence, `frames` long. Static so the chunk's region is not
    /// the test case's and it can be handed to the router.
    private static func chunk(frames: AVAudioFrameCount) throws -> MicrophoneCapture.Chunk {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        return MicrophoneCapture.Chunk(buffer: buffer)
    }

    /// Reads a finished stream back as frame counts, which is how the chunks
    /// are told apart.
    private static func lengths(of stream: AsyncStream<MicrophoneCapture.Chunk>) async -> [AVAudioFrameCount] {
        var seen: [AVAudioFrameCount] = []
        for await chunk in stream {
            seen.append(chunk.buffer.frameLength)
        }
        return seen
    }

    // MARK: - Buffering

    func testTheRingKeepsTheNewestSecondAndNoMore() throws {
        let router = TapRouter(preRollSeconds: 1.0)

        for _ in 0..<15 {
            let tenth = try Self.chunk(frames: 4_800)
            router.deliver(tenth)
        }

        XCTAssertEqual(router.bufferedSeconds, 1.0, accuracy: 0.001)
    }

    func testTheRingDropsTheOldestFirst() async throws {
        let router = TapRouter(preRollSeconds: 0.5)

        // 0.1s, 0.2s, 0.3s: the first must go to fit the last two in half a second.
        for frames in [4_800, 9_600, 14_400] as [AVAudioFrameCount] {
            let chunk = try Self.chunk(frames: frames)
            router.deliver(chunk)
        }

        let (stream, continuation) = AsyncStream<MicrophoneCapture.Chunk>.makeStream()
        router.beginStreaming(engine: continuation, clip: nil)
        continuation.finish()

        let replayed = await Self.lengths(of: stream)
        XCTAssertEqual(replayed, [9_600, 14_400])
    }

    func testAnEmptyRingReplaysNothing() async throws {
        let router = TapRouter()
        let (stream, continuation) = AsyncStream<MicrophoneCapture.Chunk>.makeStream()

        let replayed = router.beginStreaming(engine: continuation, clip: nil)
        continuation.finish()

        XCTAssertEqual(replayed, 0)
        let seen = await Self.lengths(of: stream)
        XCTAssertEqual(seen, [])
    }

    // MARK: - Starting a recording

    func testARecordingStartsWithThePreRollThenLiveAudioInOrder() async throws {
        let router = TapRouter(preRollSeconds: 1.0)

        // Twelve chunks of growing length, 0.78s in all, so every one is kept
        // and every one is distinguishable.
        for step in 1...12 {
            let chunk = try Self.chunk(frames: AVAudioFrameCount(step * 480))
            router.deliver(chunk)
        }

        let (stream, continuation) = AsyncStream<MicrophoneCapture.Chunk>.makeStream(
            bufferingPolicy: .bufferingNewest(128)
        )
        let replayed = router.beginStreaming(engine: continuation, clip: nil)
        let live = try Self.chunk(frames: 96_000)
        router.deliver(live)
        continuation.finish()

        XCTAssertEqual(replayed, 0.78, accuracy: 0.001)
        let seen = await Self.lengths(of: stream)
        XCTAssertEqual(seen, (1...12).map { AVAudioFrameCount($0 * 480) } + [96_000])
    }

    func testTheClipGetsExactlyWhatTheRecogniserGets() async throws {
        let router = TapRouter(preRollSeconds: 1.0)
        let buffered = try Self.chunk(frames: 4_800)
        router.deliver(buffered)

        let (engineStream, engine) = AsyncStream<MicrophoneCapture.Chunk>.makeStream()
        let (clipStream, clip) = AsyncStream<MicrophoneCapture.Chunk>.makeStream()
        router.beginStreaming(engine: engine, clip: clip)
        let live = try Self.chunk(frames: 9_600)
        router.deliver(live)
        engine.finish()
        clip.finish()

        let heard = await Self.lengths(of: engineStream)
        let kept = await Self.lengths(of: clipStream)
        XCTAssertEqual(heard, [4_800, 9_600])
        XCTAssertEqual(kept, heard, "The upgrade is made from the clip; it must hear what the recogniser heard.")
    }

    func testStartingASecondRecordingReplaysNothingFromTheFirst() async throws {
        let router = TapRouter(preRollSeconds: 1.0)
        let first = try Self.chunk(frames: 4_800)
        router.deliver(first)
        let (firstStream, firstContinuation) = AsyncStream<MicrophoneCapture.Chunk>.makeStream()
        router.beginStreaming(engine: firstContinuation, clip: nil)
        firstContinuation.finish()
        _ = await Self.lengths(of: firstStream)

        let (secondStream, secondContinuation) = AsyncStream<MicrophoneCapture.Chunk>.makeStream()
        let replayed = router.beginStreaming(engine: secondContinuation, clip: nil)
        secondContinuation.finish()

        XCTAssertEqual(replayed, 0, "What went into one recording is not the start of the next.")
        let seen = await Self.lengths(of: secondStream)
        XCTAssertEqual(seen, [])
    }

    // MARK: - Giving it back

    func testResetForgetsTheRingAndStopsStreaming() async throws {
        let router = TapRouter(preRollSeconds: 1.0)
        let buffered = try Self.chunk(frames: 4_800)
        router.deliver(buffered)
        let (stream, continuation) = AsyncStream<MicrophoneCapture.Chunk>.makeStream()
        router.beginStreaming(engine: continuation, clip: nil)

        router.reset()
        let afterwards = try Self.chunk(frames: 9_600)
        router.deliver(afterwards)
        continuation.finish()

        let seen = await Self.lengths(of: stream)
        XCTAssertEqual(seen, [4_800], "Nothing delivered after a reset reaches a stream that was reset away.")
        XCTAssertEqual(router.bufferedSeconds, 0.2, accuracy: 0.001, "After a reset the router is buffering again.")
    }

    func testResetWithNothingStartedForgetsTheRing() throws {
        let router = TapRouter(preRollSeconds: 1.0)
        let buffered = try Self.chunk(frames: 4_800)
        router.deliver(buffered)

        router.reset()

        XCTAssertEqual(router.bufferedSeconds, 0)
    }
}
