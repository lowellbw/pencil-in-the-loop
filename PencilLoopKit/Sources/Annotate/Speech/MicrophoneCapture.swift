//
//  MicrophoneCapture.swift
//  Annotate · Speech
//
//  One audio session and one input tap, shared by both engines. It exists
//  separately from either of them for two reasons: the 400ms budget
//  (docs/03-architecture.md § Performance targets) is spent almost entirely
//  here, and whichever engine gets deleted, this survives.
//
//  ─── WHAT TO CHECK BY HAND, ON A DEVICE ──────────────────────────────────────
//  None of this can be unit tested: there is no audio session, no input node
//  and no microphone anywhere but a real iPad, and a fake of any of them would
//  prove nothing (STYLE.md § 10). So, with music playing:
//
//  1. Hold the Pencil to pre-warm. The music ducks once, and stays ducked.
//  2. Commit to the comment. The music must **not** unduck and re-duck at the
//     press — that is `start()` deactivating the session `prewarm()` activated,
//     which is the whole cost the split exists to avoid.
//  3. Speak. The first words must be in the transcript: the tap is installed
//     before the analyser is built, and the stream holds 64 buffers.
//  4. Release. The music unducks once, when the recording ends.
//  5. Record for a minute and read the transcript back: repeated or garbled
//     phrases are the tap's buffers being reused underneath a backlog, which is
//     what `Chunk.copying(_:)` exists to rule out.
//  ─────────────────────────────────────────────────────────────────────────────
//

import Foundation
import AVFoundation
import os
import Core

/// The microphone, as an actor.
///
/// **Pre-warming is the whole point.** Configuring and activating an
/// `AVAudioSession` and starting an `AVAudioEngine` are the slow parts of
/// starting to record, and they are slow in the tens of milliseconds, which is
/// most of a 400ms budget that also has to cover the recogniser producing its
/// first hypothesis. So the work is split: `prewarm()` does everything that can
/// be done before the user has committed to speaking, and `start()` does only
/// what cannot.
///
/// **The trade-off, stated plainly.** Pre-warming activates the audio session
/// early, which ducks other audio and can show the system recording indicator
/// before a word is said, and it holds the session until `stop()`. That is why
/// `VoiceRecordingMachine` only pre-warms on a gesture that is already
/// plausibly a comment, never on every Pencil touch, and why every path out of
/// the machine ends in `.releaseCapture`.
///
/// **On failure:** throws `PencilLoopError.speechUnavailable`. Never traps; a
/// microphone that will not start is a comment written by hand instead.
actor MicrophoneCapture {

    /// One buffer, on its way from the audio thread to an engine.
    ///
    // SAFETY: `buffer` is a private copy, made inside the tap block by
    // `Chunk.copying(_:)` and handed to nobody else — so the audio unit's own
    // storage, whose lifetime past the callback is not documented and cannot be
    // checked here, is never what crosses the isolation boundary. That matters
    // because the stream buffers up to 64 chunks: the callbacks that produced
    // them have long returned by the time the engine's task reads them, and a
    // tap that reuses one backing buffer would deliver garbled or repeated
    // audio with nothing to show for it in a crash log. One memcpy of 2048
    // frames is cheap next to that; the ink path, which is the one that cannot
    // afford work, does not go through here.
    struct Chunk: @unchecked Sendable {

        let buffer: AVAudioPCMBuffer

        /// A chunk owning its own copy of `buffer`'s samples.
        ///
        /// - Returns: nil for a PCM layout with no typed accessor, which the
        ///   caller drops. `AVAudioEngine`'s input node is 32-bit float on
        ///   every device this runs on, so this is a guard rather than a path.
        static func copying(_ buffer: AVAudioPCMBuffer) -> Chunk? {
            guard let copy = AVAudioPCMBuffer(
                pcmFormat: buffer.format,
                frameCapacity: max(buffer.frameLength, 1)
            ) else { return nil }
            copy.frameLength = buffer.frameLength

            // Interleaved layouts put every channel in one allocation and say so
            // through `stride`; non-interleaved ones give a pointer per channel.
            // Both are covered by "as many pointers as there are, each holding
            // frameLength × stride samples".
            let pointerCount = buffer.format.isInterleaved ? 1 : Int(buffer.format.channelCount)
            let sampleCount = Int(buffer.frameLength) * buffer.stride
            guard pointerCount > 0, sampleCount > 0 else { return Chunk(buffer: copy) }

            if let source = buffer.floatChannelData, let destination = copy.floatChannelData {
                for channel in 0 ..< pointerCount {
                    destination[channel].update(from: source[channel], count: sampleCount)
                }
                return Chunk(buffer: copy)
            }
            if let source = buffer.int16ChannelData, let destination = copy.int16ChannelData {
                for channel in 0 ..< pointerCount {
                    destination[channel].update(from: source[channel], count: sampleCount)
                }
                return Chunk(buffer: copy)
            }
            if let source = buffer.int32ChannelData, let destination = copy.int32ChannelData {
                for channel in 0 ..< pointerCount {
                    destination[channel].update(from: source[channel], count: sampleCount)
                }
                return Chunk(buffer: copy)
            }
            return nil
        }
    }

    private let engine = AVAudioEngine()
    private let logger = Logger(subsystem: "co.pencil-loop", category: "speech")

    private var isSessionActive = false
    private var isTapped = false
    private var continuation: AsyncStream<Chunk>.Continuation?

    init() {}

    /// The input node's native format. Engines convert from this to whatever
    /// they want.
    var inputFormat: AVAudioFormat {
        engine.inputNode.outputFormat(forBus: 0)
    }

    /// Everything that can be done before the user commits: category, session
    /// activation, and the engine's own graph preparation.
    ///
    /// Idempotent, and cheap on the second call.
    func prewarm() throws {
        guard isSessionActive == false else { return }

        // **Everything below the permission check can kill the process.**
        // `AVAudioEngine` resolves its input node by asking the audio session
        // for a route, and when there is not one — no permission, or the
        // instant after the permission sheet is dismissed, before the route
        // exists — it raises an Objective-C exception. Swift cannot catch one
        // of those, so the app does not get an error: it aborts, mid-press,
        // with the popover open.
        //
        // The user reaching this without permission is the *normal* path, not
        // a corner: the sheet appears on the first press, and the first press
        // is also the first thing that wants a microphone.
        guard SpeechAvailability.microphone() == .granted else {
            throw PencilLoopError.speechUnavailable(
                reason: "PencilLoop does not have permission to use the microphone yet."
            )
        }

        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.record, mode: .measurement, options: [.duckOthers])
            try session.setActive(true, options: [])
        } catch {
            throw PencilLoopError.speechUnavailable(
                reason: "The microphone could not be started. \(error.localizedDescription)"
            )
        }
        isSessionActive = true

        // Granted permission is not the same as an input that is ready. A route
        // negotiated moments ago reports zero channels at zero hertz, and
        // `prepare()` on that raises rather than returns.
        guard session.isInputAvailable else {
            throw PencilLoopError.speechUnavailable(
                reason: "This iPad has no microphone available right now."
            )
        }
        let format = engine.inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw PencilLoopError.speechUnavailable(
                reason: "The microphone is not ready yet. Try holding again in a moment."
            )
        }

        // Resolves the input node and allocates its render resources, so
        // `start()` does not have to.
        engine.prepare()
    }

    /// Starts capture, giving a freshly granted microphone a moment to arrive.
    ///
    /// Permission being granted is not the same as an input route existing.
    /// In the instant after the permission sheet is dismissed — which is
    /// exactly when the first press happens — the session reports no input,
    /// and `AVAudioEngine` raises rather than returns. Waiting briefly turns
    /// "the first hold after granting silently does nothing" into "the first
    /// hold works", which is the difference between a feature that seems
    /// broken and one that does not.
    ///
    /// - Throws: `.speechUnavailable` if the input never appears. The caller
    ///   falls back to handwriting, which is what docs/02-spec.md § S3 asks
    ///   for and is never a dead end.
    func startWaitingForInput(
        attempts: Int = 6,
        gap: Duration = .milliseconds(120)
    ) async throws -> AsyncStream<Chunk> {
        var lastError: (any Error)?
        for attempt in 0..<max(1, attempts) {
            do {
                return try start()
            } catch {
                lastError = error
                if attempt < attempts - 1 {
                    try? await Task.sleep(for: gap)
                }
            }
        }
        throw lastError ?? PencilLoopError.speechUnavailable(
            reason: "The microphone did not become available."
        )
    }

    /// Installs the tap and starts the engine, returning the buffer stream.
    ///
    /// Calling this while a capture is running replaces it: the previous stream
    /// is finished, because there is one microphone and one recording at a time
    /// (Protocols.swift § SpeechTranscribing, Lifecycle).
    ///
    /// **It does not give the audio session back first.** Tearing the tap and
    /// the engine down is cheap; `setActive(true)` and the route negotiation
    /// behind it are the tens of milliseconds this class is split in two to
    /// avoid, and deactivating a session `prewarm()` has already activated
    /// would pay for them again here — with other audio unducking and re-ducking
    /// between the press and the first word to show for it
    /// (docs/03-architecture.md § Performance targets).
    func start() throws -> AsyncStream<Chunk> {
        stopCapture()
        try prewarm()

        let (stream, continuation) = AsyncStream<Chunk>.makeStream(
            bufferingPolicy: .bufferingNewest(64)
        )
        self.continuation = continuation

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            continuation.finish()
            self.continuation = nil
            throw PencilLoopError.speechUnavailable(
                reason: "No microphone input is available."
            )
        }

        let logger = self.logger
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { buffer, _ in
            guard let chunk = Chunk.copying(buffer) else {
                logger.debug("A microphone buffer in an unsupported PCM layout was dropped.")
                return
            }
            continuation.yield(chunk)
        }
        isTapped = true

        do {
            try engine.start()
        } catch {
            stop()
            throw PencilLoopError.speechUnavailable(
                reason: "The microphone could not be started. \(error.localizedDescription)"
            )
        }
        return stream
    }

    /// Stops capture and gives the audio session back. Idempotent, and safe to
    /// call from a stream's termination handler.
    ///
    /// This is the end of a recording, not the start of the next one — see
    /// `start()`, which tears the graph down without touching the session.
    func stop() {
        stopCapture()
        releaseSession()
    }

    /// Removes the tap, stops the engine and finishes the stream, leaving the
    /// audio session exactly as it found it.
    private func stopCapture() {
        if isTapped {
            engine.inputNode.removeTap(onBus: 0)
            isTapped = false
        }
        if engine.isRunning {
            engine.stop()
        }
        continuation?.finish()
        continuation = nil
    }

    /// Deactivates the audio session, letting other audio unduck.
    private func releaseSession() {
        guard isSessionActive else { return }
        do {
            try AVAudioSession.sharedInstance().setActive(
                false,
                options: .notifyOthersOnDeactivation
            )
        } catch {
            logger.debug("Audio session stayed active: \(error.localizedDescription, privacy: .public)")
        }
        isSessionActive = false
    }
}
