//
//  TapRouter.swift
//  Annotate · Speech
//
//  Where the microphone tap's buffers go, switchable without touching the tap.
//
//  The tap goes up when a comment becomes plausible and the recording starts a
//  moment later — and until this existed, that moment was where the first word
//  went. The tap block is the audio render thread: it may copy a buffer, take
//  one short lock and yield into a stream, and it may do nothing else. So the
//  decision of *where* a buffer goes is made here, under that lock, and the
//  actor that owns the tap changes the answer from outside it.
//
//  Two modes. **Buffering** keeps the newest second of audio in a ring, for the
//  recording that has not started yet (notes/pencil-loop-cloud-dictation.md,
//  "capture a little before the trigger"). **Streaming** hands every buffer to
//  the recording's stream and, when there is one, the clip's. Switching from
//  the first to the second replays the ring first, under the same lock, so
//  nothing is reordered and nothing is dropped.
//
//  Nothing in the ring is transcribed, written or kept unless a recording
//  follows. `reset()` forgets it, and `MicrophoneCapture.stop()` calls that.
//

import Foundation
import os

/// The switch between "keep the newest second" and "hand everything on".
final class TapRouter: @unchecked Sendable {

    /// How much audio to keep for a recording that has not started yet.
    ///
    /// One second, per the design note. The hold resolves a few hundred
    /// milliseconds after a press, a squeeze completes a few hundred after it
    /// begins, and a person who starts talking on the click is well inside
    /// that. More would hold more of a conversation nobody asked to record.
    static let preRollSeconds: Double = 1.0

    private struct State: Sendable {
        var engine: AsyncStream<MicrophoneCapture.Chunk>.Continuation?
        var clip: AsyncStream<MicrophoneCapture.Chunk>.Continuation?
        var ring: [MicrophoneCapture.Chunk] = []

        /// Counted in frames, not seconds: a tenth of a second is not exactly
        /// representable, and a ring trimmed on summed seconds dropped one
        /// chunk too many on a boundary it should have kept. Frames are
        /// integers and one tap has one sample rate.
        var ringFrames: Int = 0
        var sampleRate: Double = 0

        var ringSeconds: Double {
            sampleRate > 0 ? Double(ringFrames) / sampleRate : 0
        }
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let preRoll: Double

    init(preRollSeconds: Double = TapRouter.preRollSeconds) {
        self.preRoll = preRollSeconds
    }

    /// From the tap block. One lock, no allocation beyond the ring's growth,
    /// and never a wait on anything else.
    func deliver(_ chunk: MicrophoneCapture.Chunk) {
        state.withLock { state in
            if let engine = state.engine {
                engine.yield(chunk)
                state.clip?.yield(chunk)
                return
            }
            state.ring.append(chunk)
            state.ringFrames += Int(chunk.buffer.frameLength)
            state.sampleRate = chunk.buffer.format.sampleRate
            let limit = Int(preRoll * state.sampleRate)
            while state.ringFrames > limit, state.ring.count > 1 {
                state.ringFrames -= Int(state.ring.removeFirst().buffer.frameLength)
            }
        }
    }

    /// Points every buffer from now on at a recording, after replaying what
    /// was buffered — in order, under the lock, so a buffer arriving during
    /// the replay lands after it and not among it.
    ///
    /// - Returns: how much audio was replayed, for the log.
    @discardableResult
    func beginStreaming(
        engine: AsyncStream<MicrophoneCapture.Chunk>.Continuation,
        clip: AsyncStream<MicrophoneCapture.Chunk>.Continuation?
    ) -> Double {
        state.withLock { state in
            for chunk in state.ring {
                engine.yield(chunk)
                clip?.yield(chunk)
            }
            let replayed = state.ringSeconds
            state.ring.removeAll(keepingCapacity: true)
            state.ringFrames = 0
            state.engine = engine
            state.clip = clip
            return replayed
        }
    }

    /// Back to buffering, keeping what arrives: one recording's streams are
    /// about to be finished and the next one started on the same tap.
    ///
    /// Without this the tap would go on yielding into streams that had already
    /// finished, and whatever it delivered during the hand-over would be lost.
    /// Here it goes to the ring, and the next `beginStreaming` replays it.
    func hold() {
        state.withLock { state in
            state.engine = nil
            state.clip = nil
        }
    }

    /// Back to buffering, with nothing kept: the tap is coming down, or the
    /// recording it fed has ended.
    func reset() {
        state.withLock { state in
            state.engine = nil
            state.clip = nil
            state.ring.removeAll()
            state.ringFrames = 0
        }
    }

    /// How much audio is waiting for a recording. For tests.
    var bufferedSeconds: Double {
        state.withLock { $0.ringSeconds }
    }
}
