//
//  CommentPopoverState.swift
//  AppUI · Comment · Model
//
//  Everything the popover draws, as one value with no dependencies. The point
//  is `#Preview`: dictation, Pencil input and hover cannot be run anywhere but a
//  device, so the only way anyone sees this feature before then is by
//  constructing its states by hand.
//

import Foundation
import CoreGraphics
import Core

/// One open comment popover, as a value.
///
/// `CommentCaptureModel` owns the live one and derives it from
/// `VoiceRecordingMachine.phase`; a preview builds one literally. The view
/// reads nothing else, so every state in docs/02-spec.md § S3 is previewable
/// and none of them needs a microphone.
///
/// **Never fails.** A struct of facts about what is on screen.
public struct CommentPopoverState: Sendable, Hashable, Identifiable {

    /// How the comment is being written.
    public enum Mode: Sendable, Hashable {

        /// Press and hold to talk (docs/02-spec.md § S3). Saves as
        /// `CommentSource.voice`.
        case voice

        /// The system Scribble field, for silent rooms and for when speech
        /// assets are not installed. Saves as `CommentSource.handwriting`.
        case scribble
    }

    /// Where the recording has got to. Mirrors `VoiceRecordingMachine.Phase`,
    /// minus the parts the view has no opinion about.
    public enum Stage: Sendable, Hashable {

        /// Open, nothing being captured. The popover reached this way when the
        /// user came in through the text-selection menu, or lifted and is
        /// deciding what to do next.
        case waiting

        /// Capturing. The waveform is live and the transcript is streaming.
        case recording

        /// Lifted after a long enough hold; the engine is settling the last
        /// word. The transcript stays exactly as it was — nothing flickers.
        case finishing

        /// Correcting against the term list and writing to the store.
        case saving

        /// The engine failed. **Not a dead end**: the popover stays open and
        /// the scribble hint is still there (Protocols.swift §
        /// SpeechTranscribing).
        case failed(message: String)
    }

    /// Identity, so that SwiftUI treats a second popover as a second popover.
    public var id: UUID

    /// What the comment is anchored to. Its `excerpt(maxLength:)` is the
    /// quoted line at the top of the popover.
    public var anchor: Anchor

    /// Where the popover points, in `CommentPageResolving.pageHostView`
    /// coordinates.
    public var anchorPoint: CGPoint

    public var mode: Mode
    public var stage: Stage

    /// The live transcript. Render `displayText`, styling the volatile tail
    /// dimmer (DTOs.swift § TranscriptionUpdate).
    public var update: TranscriptionUpdate

    /// What has been written into the Scribble field so far.
    public var scribbleText: String

    /// False when speech assets are missing, permission was refused, or the
    /// locale is unsupported.
    ///
    /// It changes what the hint row says and nothing else. Dictation being
    /// unavailable is never a modal and never a blocker — the popover opens
    /// either way and the user scribbles (docs/03-architecture.md § 4).
    public var isSpeechAvailable: Bool

    public init(
        id: UUID = UUID(),
        anchor: Anchor,
        anchorPoint: CGPoint = .zero,
        mode: Mode = .voice,
        stage: Stage = .waiting,
        update: TranscriptionUpdate = TranscriptionUpdate(volatileText: "", finalisedText: ""),
        scribbleText: String = "",
        isSpeechAvailable: Bool = true
    ) {
        self.id = id
        self.anchor = anchor
        self.anchorPoint = anchorPoint
        self.mode = mode
        self.stage = stage
        self.update = update
        self.scribbleText = scribbleText
        self.isSpeechAvailable = isSpeechAvailable
    }

    /// True while audio is being captured — the waveform's cue.
    public var isRecording: Bool {
        if case .recording = stage { return true }
        return false
    }

    /// The message to show instead of a transcript, or nil when there is a
    /// transcript to show.
    public var failureMessage: String? {
        if case let .failed(message) = stage { return message }
        return nil
    }

    /// What the transcript area currently reads.
    public var displayText: String {
        switch mode {
        case .voice: return update.displayText
        case .scribble: return scribbleText
        }
    }

    /// True when there is nothing yet — the popover shows its placeholder line
    /// rather than an empty gap that looks broken.
    public var isEmpty: Bool {
        displayText.contains(where: { !$0.isWhitespace && !$0.isNewline }) == false
    }
}
