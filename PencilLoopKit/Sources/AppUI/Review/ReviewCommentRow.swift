//
//  ReviewCommentRow.swift
//  AppUI · Review
//
//  One comment in the review sheet's list (docs/02-spec.md § S4): marker,
//  quoted excerpt dimmed on one line, the comment text, and the source line.
//
//  The comment text is a live `TextField` rather than a label that becomes one,
//  which is what makes "tap to edit" literally true and keeps the row usable
//  with VoiceOver and at accessibility text sizes. Deleting is the standard
//  swipe, applied by the list rather than by this row.
//

import SwiftUI
import Core

/// A single comment row.
struct ReviewCommentRow: View {

    /// 1-based, matching the numbering in `review.md` and the `C1`, `C2` ids in
    /// `review.json`.
    let index: Int

    /// The stored comment. Only `text` is editable; the anchor and the source
    /// are facts about how it was captured.
    let comment: CommentSnapshot

    /// The editable text, written back through the model.
    @Binding var text: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            marker
            VStack(alignment: .leading, spacing: 4) {
                Text("“\(comment.anchor.excerpt())”")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .accessibilityLabel("Quoting: \(comment.anchor.excerpt())")

                TextField("Comment", text: $text, axis: .vertical)
                    .font(.body)
                    .lineLimit(1...8)
                    .accessibilityLabel("Comment \(index)")
                    .accessibilityHint("Edit the text of this comment.")

                Text(sourceLine)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .accessibilityLabel("Captured by \(sourceLine).")
            }
        }
        .padding(.vertical, 2)
    }

    /// The margin marker, echoing the reader's filled circle
    /// (docs/01-design-principles.md § Specific choices). Padded rather than
    /// fixed-size so it grows with the type.
    private var marker: some View {
        Text("\(index)")
            .font(.caption2)
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .padding(5)
            .background(.quaternary, in: .circle)
            .accessibilityHidden(true)
    }

    /// "voice · on-device" or "handwriting · recognised", plus the page it sits
    /// on. Both halves are frozen in Core so the sheet and the export agree.
    private var sourceLine: String {
        "\(comment.source.displayName) · page \(comment.resolvedOnPage + 1)"
    }
}

#Preview("Comment row") {
    List {
        ReviewCommentRow(
            index: 1,
            comment: ReviewPreviewData.comments[0],
            text: .constant(ReviewPreviewData.comments[0].text)
        )
        ReviewCommentRow(
            index: 2,
            comment: ReviewPreviewData.comments[1],
            text: .constant(ReviewPreviewData.comments[1].text)
        )
    }
    .listStyle(.insetGrouped)
}
