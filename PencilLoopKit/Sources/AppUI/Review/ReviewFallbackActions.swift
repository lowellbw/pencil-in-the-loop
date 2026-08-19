//
//  ReviewFallbackActions.swift
//  AppUI · Review
//
//  Copy review · Share… · Save to folder (docs/02-spec.md § S5).
//
//  This is not an error branch. docs/06-integrations.md § The universal
//  fallback is explicit: the Claude iOS app's Remote Control takes photo
//  attachments straight into a live session, so handing the marked-up pages to
//  the share sheet and dictating a line of instruction works today, with
//  nothing installed. "Copy review" is the same idea for someone who would
//  rather paste. Neither is presented as a failure, and neither is a dead end.
//

import SwiftUI

/// The three things a person can always do with a finished review.
struct ReviewFallbackActions: View {

    /// Whether to lead with these actions, which changes only the wording.
    let isPrimary: Bool

    /// True for a moment after copying, so the button can confirm.
    let didCopy: Bool

    let onCopy: () -> Void
    let onShare: () -> Void
    let onSave: () -> Void

    var body: some View {
        Section {
            Button(action: onCopy) {
                Label(didCopy ? "Copied" : "Copy review", systemImage: didCopy ? "checkmark" : "doc.on.doc")
            }
            .accessibilityHint("Copies the whole review as markdown.")

            Button(action: onShare) {
                Label("Share…", systemImage: "square.and.arrow.up")
            }
            .accessibilityHint("Shares the review and the marked-up pages as images.")

            Button(action: onSave) {
                Label("Save to folder", systemImage: "folder")
            }
            .accessibilityHint("Writes the review and its images to a folder you choose.")
        } header: {
            Text(isPrimary ? "Send it yourself" : "Other ways to send it")
        } footer: {
            Text(footerText)
        }
    }

    private var footerText: String {
        isPrimary
            ? "This document arrived without a conversation to reply into. Attach the shared pages in the Claude app and say what you want done — it reads the ink."
            : "The review is already on its way. These are here if you would rather hand it over yourself."
    }
}

#Preview("Fallback actions") {
    List {
        ReviewFallbackActions(
            isPrimary: true,
            didCopy: false,
            onCopy: {},
            onShare: {},
            onSave: {}
        )
        ReviewFallbackActions(
            isPrimary: false,
            didCopy: true,
            onCopy: {},
            onShare: {},
            onSave: {}
        )
    }
    .listStyle(.insetGrouped)
}
