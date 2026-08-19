//
//  VoiceRecordingMachine.swift
//  Annotate · Speech
//
//  The press-and-hold recording gesture from docs/02-spec.md § S3 and
//  docs/04-flows.md § F4, as a plain value type with no UIKit in sight.
//
//  It is a value type on purpose. Transcription cannot be unit tested and Pencil
//  input cannot be simulated, so the one part of dictation that *can* be proved
//  correct — when a hold saves, when a lift discards, what the driver is told to
//  do at each step — is kept free of both. Wave 2's popover owns the gesture
//  recogniser and the engine; this owns the rules.
//

import Foundation
import Core

/// Press and hold to record, release to save; a lift under
/// `GestureTiming.minimumHoldDuration` is a mis-touch and leaves nothing behind
/// (docs/02-spec.md § S3).
///
/// Pure and synchronous. Feed it `Event`s, apply the returned `Effect`s, render
/// `phase` and `update`. It holds no engine, no clock and no view: every time it
/// needs to know "now" the caller supplies it, which is what makes the 0.3s rule
/// testable without a device.
///
/// **On failure:** an engine error moves it to `.failed`, which is not a dead
/// end — the popover stays open and the user taps "✎ scribble instead"
/// (Protocols.swift § SpeechTranscribing). Nothing here ever discards silently
/// without saying why: every non-saving outcome carries a `DiscardReason`.
public struct VoiceRecordingMachine: Sendable, Hashable {

    // MARK: Timings

    // Both durations now live in `GestureTiming` (Core/Contracts). Wave 2's
    // gesture recogniser configures its `UILongPressGestureRecognizer` from
    // `GestureTiming.longPressDuration`, and the two halves of one gesture
    // cannot drift apart because there is only one of each number.

    // MARK: State

    /// Where the gesture is now.
    public enum Phase: Sendable, Hashable {

        /// Nothing in progress.
        case idle

        /// A touch that might become a comment is down. Capture is being
        /// pre-warmed; no audio is being transcribed yet and no popover is on
        /// screen.
        case arming(since: Date)

        /// The hold was recognised: the popover is open and the transcript is
        /// streaming. `since` is the instant the 0.3s rule is measured from.
        case recording(since: Date)

        /// The user lifted after a long enough hold, and the engine's `stop()`
        /// has not returned yet. The popover keeps showing the last transcript.
        case finishing(heldFor: TimeInterval)

        /// Terminal, and the only phase that saves anything. `text` is the
        /// transcript as the engine settled it, before term-list correction.
        case completed(text: String)

        /// Terminal, and nothing was saved: no comment, no marker, no trace.
        case discarded(reason: DiscardReason)

        /// Terminal for this attempt. The popover stays open offering scribble.
        case failed(error: PencilLoopError)
    }

    /// Why a recording produced no comment.
    public enum DiscardReason: Sendable, Hashable {

        /// Lifted in under `GestureTiming.minimumHoldDuration` (docs/04-flows.md § F4).
        case misTouch(heldFor: TimeInterval)

        /// Held long enough, but the engine settled on nothing. Saving an empty
        /// comment would leave a marker pointing at silence.
        case nothingHeard

        /// The popover was dismissed, the app went to the background, or the
        /// user switched to scribble mid-recording.
        case cancelled
    }

    /// Everything that can happen to a recording.
    public enum Event: Sendable, Hashable {

        /// A touch that might become a comment went down.
        ///
        /// The driver must **not** send this for every Pencil touch — inking is
        /// a touch too, and pre-warming the microphone on every stroke is both
        /// rude and expensive. Send it when the comment gesture becomes
        /// plausible: a short pre-trigger press, or a Pencil Pro squeeze.
        case touchDown(at: Date)

        /// The long press was recognised: open the popover, start recording.
        case holdRecognised(at: Date)

        /// A streamed update from `SpeechTranscribing.transcribe(contextualTerms:)`.
        case transcriptUpdated(TranscriptionUpdate)

        /// The user lifted.
        case touchUp(at: Date)

        /// The return value of `SpeechTranscribing.stop()`, which the contract
        /// says to prefer over the last streamed update.
        case finalText(String)

        /// The stream threw.
        case failed(PencilLoopError)

        /// Dismissed, backgrounded, or switched to scribble.
        case cancelled
    }

    /// What the driver must do. Returned in the order they should be performed.
    public enum Effect: Sendable, Hashable {

        /// Configure and activate the audio session and prepare the engine, so
        /// the first buffer is not waiting on setup (docs/03-architecture.md §
        /// Performance targets: first token under 400ms from press).
        case prewarmCapture

        /// Call `transcribe(contextualTerms:)` and pump the stream back in as
        /// `.transcriptUpdated` and `.failed`.
        case startTranscribing

        /// Call `stop()` and feed the result back as `.finalText`.
        case stopTranscribing

        /// Tear the audio session down.
        case releaseCapture

        /// Save the comment. The text is **uncorrected**: the driver runs it
        /// through `TranscriptCorrecting.correct(_:against:)` first, because
        /// correction happens once, at save (DTOs.swift § CommentSnapshot).
        case commit(text: String)

        /// Close the popover with nothing saved.
        case dismiss
    }

    /// Where the gesture is now.
    public private(set) var phase: Phase = .idle

    /// The latest streamed transcript. Render `update.displayText`, styling the
    /// volatile tail dimmer (DTOs.swift § TranscriptionUpdate).
    public private(set) var update = TranscriptionUpdate(volatileText: "", finalisedText: "")

    public init() {}

    // MARK: Derived

    /// True while audio is being captured — the waveform's cue.
    public var isRecording: Bool {
        if case .recording = phase { return true }
        return false
    }

    /// True once the machine has stopped for any reason.
    public var isFinished: Bool {
        switch phase {
        case .completed, .discarded, .failed: return true
        case .idle, .arming, .recording, .finishing: return false
        }
    }

    /// The text to save, or nil when this recording saved nothing.
    public var savedText: String? {
        if case let .completed(text) = phase { return text }
        return nil
    }

    // MARK: Transitions

    /// Applies one event and returns what the driver must do.
    ///
    /// Total: every state accepts every event. Anything that does not appear in
    /// the table below is ignored and returns no effects, so a duplicate
    /// `touchUp` or a late `transcriptUpdated` after `stop()` cannot corrupt the
    /// gesture.
    ///
    /// | from | event | to | effects |
    /// |---|---|---|---|
    /// | idle | touchDown | arming | prewarmCapture |
    /// | idle | holdRecognised | recording | prewarmCapture, startTranscribing |
    /// | arming | holdRecognised | recording | startTranscribing |
    /// | arming | touchUp / cancelled | idle | releaseCapture |
    /// | recording | transcriptUpdated | recording | — |
    /// | recording | touchUp (< 0.3s) | discarded(.misTouch) | stopTranscribing, releaseCapture, dismiss |
    /// | recording | touchUp (>= 0.3s) | finishing | stopTranscribing |
    /// | finishing | transcriptUpdated | finishing | — |
    /// | finishing | finalText (empty) | discarded(.nothingHeard) | releaseCapture, dismiss |
    /// | finishing | finalText | completed | commit, releaseCapture |
    /// | any live | failed | failed | stopTranscribing, releaseCapture |
    /// | recording, finishing | cancelled | discarded(.cancelled) | stopTranscribing, releaseCapture, dismiss |
    @discardableResult
    public mutating func handle(_ event: Event) -> [Effect] {
        switch (phase, event) {

        case (.idle, .touchDown(let at)):
            phase = .arming(since: at)
            update = TranscriptionUpdate(volatileText: "", finalisedText: "")
            return [.prewarmCapture]

        // Defensive: a squeeze shortcut can reach the popover without a
        // pre-trigger touch. Pre-warm and start in one step rather than
        // dropping the gesture on the floor.
        case (.idle, .holdRecognised(let at)):
            phase = .recording(since: at)
            update = TranscriptionUpdate(volatileText: "", finalisedText: "")
            return [.prewarmCapture, .startTranscribing]

        case (.arming(_), .holdRecognised(let at)):
            phase = .recording(since: at)
            return [.startTranscribing]

        // Lifted before the popover ever appeared. Not a mis-touch worth
        // reporting — as far as the user is concerned nothing happened.
        case (.arming(_), .touchUp(_)), (.arming(_), .cancelled):
            phase = .idle
            return [.releaseCapture]

        case (.recording(_), .transcriptUpdated(let value)),
             (.finishing(_), .transcriptUpdated(let value)):
            update = value
            return []

        case (.recording(let since), .touchUp(let at)):
            let held = max(0, at.timeIntervalSince(since))
            if held < GestureTiming.minimumHoldDuration {
                phase = .discarded(reason: .misTouch(heldFor: held))
                return [.stopTranscribing, .releaseCapture, .dismiss]
            }
            phase = .finishing(heldFor: held)
            return [.stopTranscribing]

        case (.finishing(_), .finalText(let text)):
            let settled = Self.settle(final: text, streamed: update)
            if settled.isEmpty {
                phase = .discarded(reason: .nothingHeard)
                return [.releaseCapture, .dismiss]
            }
            phase = .completed(text: settled)
            return [.commit(text: settled), .releaseCapture]

        case (.arming(_), .failed(let error)),
             (.recording(_), .failed(let error)),
             (.finishing(_), .failed(let error)):
            phase = .failed(error: error)
            return [.stopTranscribing, .releaseCapture]

        case (.recording(_), .cancelled), (.finishing(_), .cancelled):
            phase = .discarded(reason: .cancelled)
            return [.stopTranscribing, .releaseCapture, .dismiss]

        default:
            return []
        }
    }

    /// Prefers the engine's final answer, because it may finalise a trailing
    /// word after the last yield (Protocols.swift § SpeechTranscribing.stop),
    /// and falls back to what was streamed when it returns nothing.
    static func settle(final text: String, streamed: TranscriptionUpdate) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty == false { return trimmed }
        let settled = streamed.finalisedText.trimmingCharacters(in: .whitespacesAndNewlines)
        if settled.isEmpty == false { return settled }
        return streamed.displayText.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
