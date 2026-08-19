//
//  ReviewSendBar.swift
//  AppUI · Review
//
//  The destination row and the one prominent button, pinned to the bottom of
//  the review sheet as a safe-area inset.
//
//  Pinned rather than listed: docs/02-spec.md § S4 requires the destination to
//  be visible before sending, and a row that sits below twenty comments is only
//  visible to someone who scrolled. In a bottom inset the user cannot reach the
//  button without the destination being on screen above it.
//

import SwiftUI
import Core

/// Destination plus Send.
struct ReviewSendBar: View {

    let path: ResolvedReturnPath

    /// "Send back to thread", or "Send review" when no conversation is waiting.
    let title: String

    let isSending: Bool
    let isEnabled: Bool

    /// Shown above the button when a send failed. Nil the rest of the time.
    let failureMessage: String?

    let onSend: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            Divider()

            ReviewDestinationRow(path: path)
                .padding(.horizontal)

            if let failureMessage {
                Label(failureMessage, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal)
            }

            Button(action: onSend) {
                Group {
                    if isSending {
                        ProgressView()
                    } else {
                        Text(title).font(.body.weight(.semibold))
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 24)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(isEnabled == false || isSending)
            .padding(.horizontal)
            .padding(.bottom, 10)
            .accessibilityLabel(isSending ? "Sending the review" : title)
            .accessibilityHint("Sends this review to \(path.displayName).")
        }
        .background(.regularMaterial)
    }
}

#Preview("Send bar") {
    Text("Comments would be here")
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .safeAreaInset(edge: .bottom) {
            ReviewSendBar(
                path: ReviewPreviewData.resolved(.checkin),
                title: "Send back to thread",
                isSending: false,
                isEnabled: true,
                failureMessage: nil,
                onSend: {}
            )
        }
}

#Preview("Send bar · no path, and a failure") {
    Text("Comments would be here")
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .safeAreaInset(edge: .bottom) {
            ReviewSendBar(
                path: ResolvedReturnPath.unresolved,
                title: "Send review",
                isSending: false,
                isEnabled: true,
                failureMessage: "The sync folder is unavailable. It will be written when the folder returns.",
                onSend: {}
            )
        }
}
