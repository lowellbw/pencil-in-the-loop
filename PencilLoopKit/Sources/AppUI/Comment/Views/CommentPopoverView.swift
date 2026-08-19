//
//  CommentPopoverView.swift
//  AppUI · Comment · Views
//
//  docs/02-spec.md § S3, top to bottom: the quoted excerpt, a live waveform, the
//  transcript, the hint row. Nothing else, in that order.
//

import SwiftUI
import Core

/// The comment popover.
///
/// Driven entirely by a `CommentPopoverState` and six closures, so that every
/// state in the spec can be built by hand in a `#Preview` — which is the only
/// way anyone sees this before a device, since dictation, Pencil input, hover
/// and squeeze cannot be run in the Simulator.
///
/// **Never fails.** Every failure of the machinery behind it is one of the
/// states below, and all of them keep the popover open with a way forward. The
/// one thing this view must never do is lose words the user has already said.
public struct CommentPopoverView: View {

    /// What to draw.
    public var state: CommentPopoverState

    /// The hold target went down.
    public var onHoldBegan: () -> Void

    /// The hold target came up.
    public var onHoldEnded: () -> Void

    /// VoiceOver's tap-to-toggle equivalent.
    public var onToggleRecording: () -> Void

    /// "Scribble instead".
    public var onScribble: () -> Void

    /// Back to press-and-hold.
    public var onVoice: () -> Void

    /// Save what was scribbled.
    public var onSave: () -> Void

    /// The Scribble field changed.
    public var onScribbleTextChanged: (String) -> Void

    public init(
        state: CommentPopoverState,
        onHoldBegan: @escaping () -> Void = {},
        onHoldEnded: @escaping () -> Void = {},
        onToggleRecording: @escaping () -> Void = {},
        onScribble: @escaping () -> Void = {},
        onVoice: @escaping () -> Void = {},
        onSave: @escaping () -> Void = {},
        onScribbleTextChanged: @escaping (String) -> Void = { _ in }
    ) {
        self.state = state
        self.onHoldBegan = onHoldBegan
        self.onHoldEnded = onHoldEnded
        self.onToggleRecording = onToggleRecording
        self.onScribble = onScribble
        self.onVoice = onVoice
        self.onSave = onSave
        self.onScribbleTextChanged = onScribbleTextChanged
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            excerpt
            content(for: state.mode)
            Divider()
            CommentHintRow(
                mode: state.mode,
                isSpeechAvailable: state.isSpeechAvailable,
                isRecording: state.isRecording,
                canSave: !state.scribbleText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                onHoldBegan: onHoldBegan,
                onHoldEnded: onHoldEnded,
                onToggleRecording: onToggleRecording,
                onScribble: onScribble,
                onVoice: onVoice,
                onSave: onSave
            )
        }
        .padding(16)
        .frame(idealWidth: 300)
        .frame(maxWidth: 460)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityLabel)
    }

    // MARK: - Parts

    /// The anchor, quoted. One or two lines, truncated with an ellipsis
    /// (docs/02-spec.md § S3).
    private var excerpt: some View {
        Text(quotedLine)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(2)
            .truncationMode(.tail)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel("Commenting on \(quotedLine)")
    }

    private var quotedLine: String {
        let excerpt = state.anchor.excerpt(maxLength: 120)
        // A comment on a figure, a table, or a page whose text layer is empty
        // is a supported outcome, not a failure — say where it is instead of
        // showing an empty pair of quotation marks.
        guard !excerpt.isEmpty else {
            return "This part of page \(state.anchor.pageIndex + 1)"
        }
        return "\u{201C}\(excerpt)\u{201D}"
    }

    @ViewBuilder
    private func content(for mode: CommentPopoverState.Mode) -> some View {
        switch mode {
        case .voice:
            VStack(alignment: .leading, spacing: 10) {
                if state.isRecording || state.stage == .finishing {
                    CommentWaveformView(
                        isActive: state.isRecording,
                        transcriptLength: state.update.displayText.count
                    )
                }
                if let failure = state.failureMessage {
                    failureRow(failure)
                }
                CommentTranscriptView(update: state.update, placeholder: placeholder)
                    .opacity(state.stage == .saving ? 0.5 : 1)
            }
        case .scribble:
            CommentScribbleField(
                text: Binding(
                    get: { state.scribbleText },
                    set: { onScribbleTextChanged($0) }
                ),
                placeholder: "Write your comment"
            )
            .frame(minHeight: 76, maxHeight: 160)
        }
    }

    private func failureRow(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var placeholder: String {
        switch state.stage {
        case .recording: return "Listening\u{2026}"
        case .finishing: return "Finishing\u{2026}"
        case .saving: return "Saving\u{2026}"
        case .failed: return "Nothing was captured."
        case .waiting: return state.isSpeechAvailable ? "Hold to talk" : "Dictation unavailable"
        }
    }

    private var accessibilityLabel: String {
        switch state.stage {
        case .recording: return "Recording a comment"
        case .finishing, .saving: return "Saving comment"
        case .failed: return "Comment, dictation failed"
        case .waiting: return "New comment"
        }
    }
}

// MARK: - Previews

private let previewAnchor = Anchor(
    quoted: "The migration runs in a single deploy, with no dual-write window.",
    prefix: "\u{2026}rotating refresh token stored in the keychain. ",
    suffix: " Rollout is gated behind auth_v2.",
    pageIndex: 1,
    normalisedRect: NormalisedRect(x: 0.12, y: 0.34, width: 0.76, height: 0.04)
)

#Preview("Waiting") {
    CommentPopoverView(state: CommentPopoverState(anchor: previewAnchor))
}

#Preview("Recording") {
    CommentPopoverView(
        state: CommentPopoverState(
            anchor: previewAnchor,
            stage: .recording,
            update: TranscriptionUpdate(
                volatileText: " I want a shadow read for at least a day",
                finalisedText: "No dual-write window means we cannot roll back after the cutover \u{2014}"
            )
        )
    )
}

#Preview("Finishing") {
    CommentPopoverView(
        state: CommentPopoverState(
            anchor: previewAnchor,
            stage: .finishing,
            update: TranscriptionUpdate(
                volatileText: "",
                finalisedText: "No dual-write window means we cannot roll back after the cutover."
            )
        )
    )
}

#Preview("Saving") {
    CommentPopoverView(
        state: CommentPopoverState(
            anchor: previewAnchor,
            stage: .saving,
            update: TranscriptionUpdate(
                volatileText: "",
                finalisedText: "No dual-write window means we cannot roll back after the cutover."
            )
        )
    )
}

#Preview("Dictation failed") {
    CommentPopoverView(
        state: CommentPopoverState(
            anchor: previewAnchor,
            stage: .failed(message: PencilLoopError.speechUnavailable(reason: "Language assets are still downloading.").message)
        )
    )
}

#Preview("Scribble") {
    CommentPopoverView(
        state: CommentPopoverState(
            anchor: previewAnchor,
            mode: .scribble,
            scribbleText: "Shadow read for a day before the cutover."
        )
    )
}

#Preview("Speech unavailable") {
    CommentPopoverView(
        state: CommentPopoverState(
            anchor: previewAnchor,
            mode: .scribble,
            isSpeechAvailable: false
        )
    )
}

#Preview("No text under the touch") {
    CommentPopoverView(
        state: CommentPopoverState(
            anchor: Anchor(
                quoted: "",
                pageIndex: 3,
                normalisedRect: NormalisedRect(x: 0.1, y: 0.5, width: 0.8, height: 0.2)
            ),
            stage: .recording
        )
    )
}

#Preview("Accessibility text size") {
    CommentPopoverView(
        state: CommentPopoverState(
            anchor: previewAnchor,
            stage: .recording,
            update: TranscriptionUpdate(
                volatileText: "",
                finalisedText: "No dual-write window means we cannot roll back."
            )
        )
    )
    .environment(\.dynamicTypeSize, .accessibility3)
}
