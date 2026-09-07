//
//  ClipRecorderTests.swift
//  AnnotateTests
//
//  The clip survives the capture restarting underneath it.
//
//  `ContinuousTranscriber` restarts the engine whenever it finalises an
//  utterance mid-comment, and the capture begins the recorder again each time.
//  A recorder that reopened its file on the second `begin` kept only the last
//  segment of the comment — and an upgrade made from that would have replaced
//  the whole draft with a transcript of its final few seconds.
//
//  This is the one part of the clip path with no microphone in it, so it is the
//  one part that can be tested (STYLE.md § 10).
//

import XCTest
import AVFoundation
import Foundation
@testable import Annotate

final class ClipRecorderTests: XCTestCase {

    private var destination = URL(fileURLWithPath: "/dev/null")

    override func setUp() {
        super.setUp()
        destination = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("clip-\(UUID().uuidString).flac")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: destination)
        super.tearDown()
    }

    private static func format() throws -> AVAudioFormat {
        try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
    }

    /// Static, and not by preference: a buffer is not `Sendable`, and one made
    /// by an instance method shares the test case's isolation region, which
    /// the compiler will not let cross into the recorder. A fresh region can.
    private static func silence(_ format: AVAudioFormat, seconds: Double) throws -> AVAudioPCMBuffer {
        let frames = AVAudioFrameCount(format.sampleRate * seconds)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        return buffer
    }

    func testBeginningAgainKeepsAppendingToTheSameClip() async throws {
        let format = try Self.format()
        let recorder = ClipRecorder(url: destination)
        let firstHalf = try Self.silence(format, seconds: 0.5)
        let secondHalf = try Self.silence(format, seconds: 0.5)

        let began = await recorder.begin(format: format)
        XCTAssertTrue(began)
        await recorder.append(firstHalf)

        // The capture restarted mid-recording and begins on the same recorder.
        let beganAgain = await recorder.begin(format: format)
        XCTAssertTrue(beganAgain, "A recorder already writing must carry on, not refuse.")
        await recorder.append(secondHalf)

        let finished = await recorder.finish()
        XCTAssertEqual(finished, destination)
        let file = try AVAudioFile(forReading: destination)
        XCTAssertEqual(file.length, 48_000, "Both halves of the recording must be in the clip.")
    }

    func testAPressTooShortToBeACommentLeavesNoClip() async throws {
        let format = try Self.format()
        let recorder = ClipRecorder(url: destination)
        let blip = try Self.silence(format, seconds: 0.1)

        _ = await recorder.begin(format: format)
        await recorder.append(blip)

        let finished = await recorder.finish()
        XCTAssertNil(finished)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testADiscardedRecordingLeavesNoFile() async throws {
        let format = try Self.format()
        let recorder = ClipRecorder(url: destination)
        let half = try Self.silence(format, seconds: 0.5)

        _ = await recorder.begin(format: format)
        await recorder.append(half)
        await recorder.discard()

        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }
}
