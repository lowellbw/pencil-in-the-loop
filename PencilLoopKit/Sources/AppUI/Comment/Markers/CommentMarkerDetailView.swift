//
//  CommentMarkerDetailView.swift
//  AppUI · Comment · Markers
//
//  "Tap a comment marker → open that comment for review or deletion."
//  (docs/02-spec.md § S2)
//

import SwiftUI
import Core

/// What a marker shows when it is tapped.
///
/// One comment normally; several when the marker stood for several on a line.
/// Each one shows what it is anchored to, what it says, and how it was
/// captured — the same three facts the review sheet shows, because a user who
/// has just tapped a marker is doing a small review of one comment.
///
/// **Deleting does not close this.** The comment vanishes from the list and an
/// Undo takes its place, right where the user is already looking: nothing in
/// this app is destructive without undo (docs/02-spec.md § Cross-cutting), and
/// an undo that lives in a toast somewhere else is an undo nobody finds. The
/// store holds the real undo stack, so the restored comment keeps its original
/// id, timestamp and anchor.
///
/// **Never fails.** With every comment deleted it shows the undo row alone.
public struct CommentMarkerDetailView: View {

    /// What this marker stands for, in document order.
    public var comments: [CommentSnapshot]

    /// The comment just deleted, while its undo is still offered.
    public var deletedComment: CommentSnapshot?

    /// Delete one comment, undoably.
    public var onDelete: (CommentSnapshot) -> Void

    /// Put the last deleted one back.
    public var onUndo: () -> Void

    public init(
        comments: [CommentSnapshot],
        deletedComment: CommentSnapshot? = nil,
        onDelete: @escaping (CommentSnapshot) -> Void = { _ in },
        onUndo: @escaping () -> Void = {}
    ) {
        self.comments = comments
        self.deletedComment = deletedComment
        self.onDelete = onDelete
        self.onUndo = onUndo
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if deletedComment != nil {
                    undoRow
                    if !comments.isEmpty {
                        Divider()
                    }
                }
                ForEach(Array(comments.enumerated()), id: \.element.id) { index, comment in
                    if index > 0 {
                        Divider()
                    }
                    row(for: comment)
                }
            }
            .padding(16)
        }
        .frame(idealWidth: 320)
        .frame(maxWidth: 460, maxHeight: 420)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(comments.count > 1 ? "\(comments.count) comments" : "Comment")
    }

    private var undoRow: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Comment deleted")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Button("Undo", action: onUndo)
                .font(.footnote)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func row(for comment: CommentSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(quotedLine(for: comment))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            Text(comment.text)
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)

            HStack(alignment: .firstTextBaseline) {
                Text(comment.source.displayName)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 12)
                Button("Delete", role: .destructive) {
                    onDelete(comment)
                }
                .font(.footnote)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(comment.text). \(comment.source.displayName).")
        .accessibilityAction(named: "Delete") { onDelete(comment) }
    }

    private func quotedLine(for comment: CommentSnapshot) -> String {
        let excerpt = comment.anchor.excerpt(maxLength: 120)
        guard !excerpt.isEmpty else {
            return "This part of page \(comment.anchor.pageIndex + 1)"
        }
        return "\u{201C}\(excerpt)\u{201D}"
    }
}

// MARK: - Previews

private let detailPreviewComments: [CommentSnapshot] = [
    CommentSnapshot(
        id: UUID(uuidString: "C0FFEE00-0000-4000-8000-000000000001") ?? UUID(),
        createdAt: Date(timeIntervalSince1970: 1_787_000_000),
        text: "No dual-write window means we cannot roll back after the cutover. I want a shadow read for at least a day.",
        source: .voice,
        anchor: Anchor(
            quoted: "The migration runs in a single deploy, with no dual-write window.",
            pageIndex: 1,
            normalisedRect: NormalisedRect(x: 0.12, y: 0.34, width: 0.76, height: 0.04)
        ),
        resolvedOnPage: 1
    ),
    CommentSnapshot(
        id: UUID(uuidString: "C0FFEE00-0000-4000-8000-000000000002") ?? UUID(),
        createdAt: Date(timeIntervalSince1970: 1_787_000_100),
        text: "Infinite retry loop?",
        source: .handwriting,
        anchor: Anchor(
            quoted: "every client is on SDK v4 or later",
            pageIndex: 1,
            normalisedRect: NormalisedRect(x: 0.12, y: 0.36, width: 0.5, height: 0.03)
        ),
        resolvedOnPage: 1
    )
]

#Preview("One comment") {
    CommentMarkerDetailView(comments: Array(detailPreviewComments.prefix(1)))
}

#Preview("Several on a line") {
    CommentMarkerDetailView(comments: detailPreviewComments)
}

#Preview("Just deleted") {
    CommentMarkerDetailView(
        comments: Array(detailPreviewComments.dropFirst()),
        deletedComment: detailPreviewComments.first
    )
}

#Preview("Accessibility text size") {
    CommentMarkerDetailView(comments: detailPreviewComments)
        .environment(\.dynamicTypeSize, .accessibility3)
}
