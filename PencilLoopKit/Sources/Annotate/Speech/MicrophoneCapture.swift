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
//  6. Start talking the instant the popover appears — and, with a Pencil Pro,
//     the instant the squeeze clicks. The first word must be in the transcript
//     and in the clip: that is the pre-roll (`TapRouter`), and before it
//     existed the first word was reliably lost to setup.
//  7. Press and lift before the hold resolves. The recording indicator must go
//     out: a pre-warm that never became a recording has been given back.
//  8. Dictate a dozen comments back to back, some of them with a lift the
//     instant the popover opens. Every one that was held must transcribe; none
//     may sit at "Starting…". That was the September hang: a recording started
//     on a capture nobody had stopped waited for ever on the last clip's drain.
//  9. Mid-comment, raise Siri or take a call, then dictate again. The next
//     comment must hear you: a warm tap whose engine the system stopped is
//     started again rather than trusted.
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
/// and starts the microphone early, which ducks other audio, shows the system
/// recording indicator before a word is said, and keeps the newest second of
/// audio in memory (`TapRouter`); it holds all of that until `stop()`. That is
/// why `VoiceRecordingMachine` only pre-warms on a gesture that is already
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

    /// Where the tap's buffers go. The tap is installed once, at pre-warm, and
    /// this is switched from buffering to a recording's stream without touching
    /// it — the whole of how the first word survives (`TapRouter`).
    private let router = TapRouter()

    private var isSessionActive = false
    private var isTapped = false
    private var continuation: AsyncStream<Chunk>.Continuation?

    /// Bumped by `stop()`. A `prewarm()` that began before a stop must not
    /// finish after it and leave the microphone running with nobody left to
    /// give it back — a lift during session activation is a real sequence.
    private var generation = 0

    /// The second consumer of every buffer: the file the clip is written to,
    /// so a better transcript can be made from it later
    /// (notes/pencil-loop-cloud-dictation.md). Nil when nothing asked for one.
    private var recorder: ClipRecorder?

    /// Drains the recorder's stream. Separate from the engine's so that a slow
    /// disk cannot stall recognition, and so neither consumer can starve the
    /// other of buffers.
    private var recordingTask: Task<Void, Never>?

    private var recordingContinuation: AsyncStream<Chunk>.Continuation?

    init() {}

    /// The input node's native format. Engines convert from this to whatever
    /// they want.
    var inputFormat: AVAudioFormat {
        engine.inputNode.outputFormat(forBus: 0)
    }

    /// Everything that can be done before the user commits: category, session
    /// activation, the engine's own graph preparation — and, since the first
    /// word kept going missing, the microphone itself.
    ///
    /// The tap goes up here and audio starts flowing into a one-second ring
    /// (`TapRouter`). A recording that starts a moment later begins with what
    /// is in the ring, so the word spoken as the hold resolves is in the
    /// transcript rather than lost to setup. Nothing in the ring is ever
    /// transcribed unless a recording follows; `stop()` throws it away.
    ///
    /// Idempotent, and cheap on the second call.
    func prewarm() async throws {
        if isTapped, engine.isRunning == false {
            // Warm on paper, silent in fact. The system stops the engine
            // underneath a tap it has not been told about — a call, Siri, a
            // route change — and everything here still says the microphone is
            // live. A recording started on that would stream nothing for as
            // long as the Pencil was held, so start again from the top.
            logger.notice("The audio engine had stopped under a warm tap; starting it again.")
            await stop()
        }
        try await activateSessionIfNeeded()
        guard isTapped == false else { return }
        do {
            try startTap()
        } catch {
            await stop()
            throw error
        }
    }

    /// The session half of `prewarm()`: category, activation, and the graph.
    private func activateSessionIfNeeded() async throws {
        guard isSessionActive == false else { return }
        let started = generation

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

        // Asked for, not taken. This used to set the category itself, which was
        // safe only while nothing in the app played anything — a narration
        // running when the Pencil touched down would have gone silent
        // (`AudioSessionArbiter`).
        try await AudioSessionArbiter.shared.beginRecording()
        guard generation == started else {
            // Stopped while the session was being activated. Hand it straight
            // back: nobody is left who would.
            await AudioSessionArbiter.shared.endRecording()
            throw CancellationError()
        }
        let session = AVAudioSession.sharedInstance()
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
        clipURL: URL? = nil,
        attempts: Int = 6,
        gap: Duration = .milliseconds(120)
    ) async throws -> AsyncStream<Chunk> {
        var lastError: (any Error)?
        for attempt in 0..<max(1, attempts) {
            do {
                return try await start(clipURL: clipURL)
            } catch let stopped as CancellationError {
                // `stop()` overtook the start. The recording this was for is
                // over before it began, and trying again would bring the
                // microphone back up after the hand that asked for it had let
                // go — with nobody left to give it back.
                throw stopped
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

    /// Begins a recording on the tap `prewarm()` put up, returning the buffer
    /// stream — which starts with the pre-roll.
    ///
    /// Calling this while a capture is running replaces it: the previous stream
    /// is finished, because there is one microphone and one recording at a time
    /// (Protocols.swift § SpeechTranscribing, Lifecycle).
    ///
    /// **It gives nothing back first.** `setActive(true)` and the route
    /// negotiation behind it are the tens of milliseconds this class is split
    /// in two to avoid, and the tap that has been running since pre-warm is
    /// holding the second of audio the recording is about to start with.
    /// Deactivating either would pay for the first again and throw the second
    /// away (docs/03-architecture.md § Performance targets).
    ///
    /// - Parameter clipURL: where to also write the audio, or nil to keep none.
    ///   Writing is best-effort in one direction only: a clip that cannot be
    ///   written costs a later upgrade and never the recording in progress.
    /// - Throws: `CancellationError` when `stop()` lands while this is still
    ///   starting — the recording is over before it began, and nothing here is
    ///   left running for it.
    func start(clipURL: URL? = nil) async throws -> AsyncStream<Chunk> {
        // Whatever the previous recording was feeding ends here — both of its
        // streams, not only the recogniser's. The tap stays up: tearing it down
        // to put it straight back would cost the buffers in between, so it
        // goes back to the ring for the moment it takes to start this one.
        //
        // **The clip's stream is the one that matters.** Its drain task is
        // awaited below, and that task ends only when its stream does. This
        // used to call `stopCapture()`, which finished it; when that call was
        // dropped to keep the tap up, the finish went with it. A capture that
        // reached here without a `stop()` since its last recording — an
        // engine that failed mid-comment, a lift that landed while the last
        // one was still starting — then waited on that task for ever, and
        // every comment after it sat at "Starting…" with nothing transcribed.
        router.hold()
        continuation?.finish()
        continuation = nil
        recordingContinuation?.finish()
        recordingContinuation = nil

        try await prewarm()
        let started = generation

        // Whatever the previous tap was still draining lands before this
        // segment's first buffer, so the file stays in order. Its stream was
        // finished above, so this is the tail of a queue and not a wait on
        // anything.
        await recordingTask?.value
        recordingTask = nil

        // The recorder outlives the tap. `ContinuousTranscriber` restarts the
        // engine whenever it finalises an utterance mid-comment, and every
        // restart comes back through here. A fresh recorder each time would
        // reopen the same file and keep only the last few seconds of the
        // comment — which an upgrade would then confidently transcribe as the
        // whole of it. So a recorder already writing to this destination is
        // kept and appended to; only a *different* destination starts a file.
        let recorder: ClipRecorder?
        if let clipURL, let current = self.recorder, current.url == clipURL {
            recorder = current
        } else {
            // A different clip, or none: a recording nobody collected,
            // abandoned before it was saved. Its file is not this recording's
            // and must not be handed on as it.
            if let stale = self.recorder {
                self.recorder = nil
                await stale.discard()
            }
            recorder = clipURL.map { ClipRecorder(url: $0) }
            self.recorder = recorder
        }

        // Stopped while this was starting. `stop()` has already taken the tap
        // down and given the session back; carrying on would hand the engine a
        // stream nothing feeds, and open a clip nothing would ever close.
        guard generation == started else {
            throw CancellationError()
        }

        // Deep enough to hold the pre-roll and everything the tap delivers
        // while the recogniser is still being built — which, cold, is seconds.
        let (stream, continuation) = AsyncStream<Chunk>.makeStream(
            bufferingPolicy: .bufferingNewest(128)
        )
        self.continuation = continuation

        // The clip's own stream, drained by a task rather than written here:
        // the tap block is the render thread and must not touch a file.
        var clipContinuation: AsyncStream<Chunk>.Continuation?
        if let recorder {
            let format = engine.inputNode.outputFormat(forBus: 0)
            let (clipStream, clipInput) = AsyncStream<Chunk>.makeStream(
                bufferingPolicy: .bufferingNewest(128)
            )
            clipContinuation = clipInput
            self.recordingContinuation = clipInput
            self.recordingTask = Task {
                guard await recorder.begin(format: format) else { return }
                for await chunk in clipStream {
                    await recorder.append(chunk.buffer)
                }
            }
        }

        // Everything buffered since pre-warm goes first, then live audio, in
        // one step under the router's lock — so a buffer arriving during the
        // hand-over lands after the pre-roll and not among it.
        let replayed = router.beginStreaming(engine: continuation, clip: clipContinuation)
        if replayed > 0 {
            logger.debug("Recording began with \(replayed, format: .fixed(precision: 2))s of pre-roll.")
        }
        return stream
    }

    /// Installs the tap and starts the engine, feeding the router.
    ///
    /// The tap block is the audio render thread. It copies the buffer and hands
    /// it to the router, which takes one short lock; it must never do more.
    private func startTap() throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw PencilLoopError.speechUnavailable(
                reason: "No microphone input is available."
            )
        }
        let router = self.router
        let logger = self.logger
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { buffer, _ in
            guard let chunk = Chunk.copying(buffer) else {
                logger.debug("A microphone buffer in an unsupported PCM layout was dropped.")
                return
            }
            // One copy, and the router hands the same one to the recogniser
            // and the clip. `Chunk` is only ever read, so one memcpy still
            // covers the reuse the copy exists to prevent.
            router.deliver(chunk)
        }
        isTapped = true
        do {
            try engine.start()
        } catch {
            throw PencilLoopError.speechUnavailable(
                reason: "The microphone could not be started. \(error.localizedDescription)"
            )
        }
    }

    /// Closes the clip and says where it landed.
    ///
    /// - Returns: the clip's URL, or nil when there is nothing worth keeping —
    ///   no clip was asked for, the write failed, or the press was too short to
    ///   be a comment. Call after `stop()`, so the last buffers are in.
    ///   Nil, and nothing touched, while a recording is running: a collector
    ///   that arrives then is a late one from the comment before, and closing
    ///   the file now would cut the live recording's clip short and hand its
    ///   audio to a comment it does not belong to.
    func finishClip() async -> URL? {
        guard continuation == nil else { return nil }
        recordingContinuation?.finish()
        recordingContinuation = nil
        await recordingTask?.value
        recordingTask = nil
        let clip = await recorder?.finish()
        recorder = nil
        return clip
    }

    /// Throws away the clip for a recording nobody kept.
    func discardClip() async {
        recordingContinuation?.finish()
        recordingContinuation = nil
        await recordingTask?.value
        recordingTask = nil
        await recorder?.discard()
        recorder = nil
    }

    /// Stops capture and gives the audio session back. Idempotent, and safe to
    /// call from a stream's termination handler.
    ///
    /// This is the end of a recording, not the start of the next one — see
    /// `start()`, which hands the tap from one recording to the next without
    /// taking it down or touching the session. A `start()` still in flight when
    /// this lands gives up (`CancellationError`) rather than finishing after it.
    func stop() async {
        stopCapture()
        await releaseSession()
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
        // Whatever the ring held is nobody's now, and a pre-warm still in
        // flight must not bring the microphone back up (`generation`).
        generation += 1
        router.reset()
        continuation?.finish()
        continuation = nil
        // Not `finishClip()`: this is called from stream teardown and cannot
        // await. Finishing the continuation lets the drain task run to the end
        // of the buffers it already has; the caller collects the file.
        recordingContinuation?.finish()
        recordingContinuation = nil
    }

    /// Deactivates the audio session, letting other audio unduck.
    /// Hands the session back. The arbiter decides what happens to it — a
    /// narration that was ducked for this recording is resumed rather than
    /// left silent, which is why this no longer deactivates directly.
    private func releaseSession() async {
        guard isSessionActive else { return }
        await AudioSessionArbiter.shared.endRecording()
        isSessionActive = false
    }
}
