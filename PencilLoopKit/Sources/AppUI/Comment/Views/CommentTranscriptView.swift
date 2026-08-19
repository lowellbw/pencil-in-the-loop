//
//  CommentTranscriptView.swift
//  AppUI · Comment · Views
//
//  "The transcript, appearing as you speak." (docs/02-spec.md § S3)
//

import SwiftUI
import Core

/// The words, in `.body`, with the unsettled tail dimmer than the settled part.
///
/// `SpeechAnalyzer` streams two things at once and both matter: text that has
/// been finalised and will not change again, and a volatile hypothesis that
/// gets replaced as you keep speaking. Rendering only the finalised text makes
/// the popover look frozen; rendering only the volatile text makes it flicker.
/// So both are shown, and the volatile part is secondary
/// (DTOs.swift § TranscriptionUpdate).
///
/// **Accessibility.** One label containing the whole transcript, marked as
/// updating frequently so VoiceOver reads it as it grows rather than
/// interrupting after every word. This is a voice-first feature; it has to work
/// for someone who cannot see the popover at all.
///
/// **Never fails.** With nothing to show it shows its placeholder, which is a
/// state, not an error.
public struct CommentTranscriptView: View {

    /// The streamed transcript.
    public var update: TranscriptionUpdate

    /// Shown in secondary colour when there is nothing yet.
    public var placeholder: String

    public init(update: TranscriptionUpdate, placeholder: String) {
        self.update = update
        self.placeholder = placeholder
    }

    public var body: some View {
        Group {
            if isEmpty {
                Text(placeholder)
                    .foregroundStyle(.secondary)
            } else {
                Text(update.finalisedText)
                    + Text(update.volatileText).foregroundStyle(.secondary)
            }
        }
        .font(.body)
        .multilineTextAlignment(.leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(isEmpty ? placeholder : update.displayText)
        .accessibilityAddTraits(.updatesFrequently)
    }

    private var isEmpty: Bool {
        update.displayText.contains(where: { !$0.isWhitespace && !$0.isNewline }) == false
    }
}

#Preview("Streaming") {
    CommentTranscriptView(
        update: TranscriptionUpdate(
            volatileText: " — I want a shadow read for at least a day",
            finalisedText: "No dual-write window means we cannot roll back after the cutover"
        ),
        placeholder: "Hold to talk"
    )
    .padding()
    .frame(width: 300)
}

#Preview("Nothing yet") {
    CommentTranscriptView(
        update: TranscriptionUpdate(volatileText: "", finalisedText: ""),
        placeholder: "Hold to talk"
    )
    .padding()
    .frame(width: 300)
}
