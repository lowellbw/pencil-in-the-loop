//
//  CommentHintRow.swift
//  AppUI · Comment · Views
//
//  The bottom line of the popover: "Hold to talk" and the way out to Scribble
//  (docs/02-spec.md § S3).
//

import SwiftUI

/// The hint row, which is also a control.
///
/// It reads as a hint because that is what docs/02-spec.md § S3 asks for, but
/// the left half is the in-popover hold target and the right half is a button.
/// Both are needed: a comment started from the text-selection menu has no
/// Pencil press to hold, and a silent room needs Scribble.
///
/// **Three reflows, all required.**
/// - At accessibility text sizes the two halves stack, because "Hold to talk ·
///   Scribble instead" on one line at 310% is one word per line.
/// - With VoiceOver running, hold-to-talk becomes tap-to-start and
///   tap-to-stop. Nobody can hold a control they are exploring by touch, and a
///   voice feature that cannot be driven by VoiceOver would be a poor joke.
/// - With speech unavailable the talk half is not offered at all — the popover
///   opened straight into Scribble and there is nothing to hold.
///
/// **Never fails.** Buttons and text.
public struct CommentHintRow: View {

    /// Which body the popover is showing.
    public var mode: CommentPopoverState.Mode

    /// False when assets are missing, permission was refused, or the locale is
    /// unsupported.
    public var isSpeechAvailable: Bool

    /// True while audio is being captured.
    public var isRecording: Bool

    /// True when the Scribble field has something worth saving.
    public var canSave: Bool

    /// The hold target went down.
    public var onHoldBegan: () -> Void

    /// The hold target came up. Under `GestureTiming.minimumHoldDuration` the
    /// state machine discards this, and it does so without leaving a marker.
    public var onHoldEnded: () -> Void

    /// VoiceOver's tap-to-toggle equivalent of the two above.
    public var onToggleRecording: () -> Void

    /// "Scribble instead".
    public var onScribble: () -> Void

    /// Back to press-and-hold from the Scribble field.
    public var onVoice: () -> Void

    /// Save what was scribbled.
    public var onSave: () -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled

    public init(
        mode: CommentPopoverState.Mode,
        isSpeechAvailable: Bool,
        isRecording: Bool,
        canSave: Bool,
        onHoldBegan: @escaping () -> Void,
        onHoldEnded: @escaping () -> Void,
        onToggleRecording: @escaping () -> Void,
        onScribble: @escaping () -> Void,
        onVoice: @escaping () -> Void,
        onSave: @escaping () -> Void
    ) {
        self.mode = mode
        self.isSpeechAvailable = isSpeechAvailable
        self.isRecording = isRecording
        self.canSave = canSave
        self.onHoldBegan = onHoldBegan
        self.onHoldEnded = onHoldEnded
        self.onToggleRecording = onToggleRecording
        self.onScribble = onScribble
        self.onVoice = onVoice
        self.onSave = onSave
    }

    public var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 10) {
                    leading
                    trailing
                }
            } else {
                HStack(alignment: .firstTextBaseline) {
                    leading
                    Spacer(minLength: 12)
                    trailing
                }
            }
        }
        .font(.footnote)
    }

    @ViewBuilder
    private var leading: some View {
        switch mode {
        case .voice:
            if voiceOverEnabled {
                Button(isRecording ? "Stop and save" : "Record", action: onToggleRecording)
            } else {
                Text("**Hold** to talk")
                    .foregroundStyle(.secondary)
                    .contentShape(.rect)
                    .onLongPressGesture(
                        minimumDuration: 0.05,
                        perform: {},
                        onPressingChanged: { isPressing in
                            if isPressing {
                                onHoldBegan()
                            } else {
                                onHoldEnded()
                            }
                        }
                    )
                    .accessibilityLabel("Hold to talk")
            }
        case .scribble:
            if isSpeechAvailable {
                Button(action: onVoice) {
                    Label("Talk instead", systemImage: "mic")
                }
            } else {
                Text("Dictation unavailable")
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var trailing: some View {
        switch mode {
        case .voice:
            Button(action: onScribble) {
                // An SF Symbol rather than the spec's literal "✎": rule 1 of
                // docs/01-design-principles.md is SF Symbols only, and the pencil
                // tip is the same idea in the system's own hand.
                Label("Scribble instead", systemImage: "pencil.tip")
            }
        case .scribble:
            Button("Save", action: onSave)
                .disabled(!canSave)
                .fontWeight(.semibold)
        }
    }
}

#Preview("Voice") {
    CommentHintRow(
        mode: .voice,
        isSpeechAvailable: true,
        isRecording: false,
        canSave: false,
        onHoldBegan: {},
        onHoldEnded: {},
        onToggleRecording: {},
        onScribble: {},
        onVoice: {},
        onSave: {}
    )
    .padding()
    .frame(width: 300)
}

#Preview("Scribble") {
    CommentHintRow(
        mode: .scribble,
        isSpeechAvailable: true,
        isRecording: false,
        canSave: true,
        onHoldBegan: {},
        onHoldEnded: {},
        onToggleRecording: {},
        onScribble: {},
        onVoice: {},
        onSave: {}
    )
    .padding()
    .frame(width: 300)
}
