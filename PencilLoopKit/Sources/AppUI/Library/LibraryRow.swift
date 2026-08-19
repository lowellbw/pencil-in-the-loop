//
//  LibraryRow.swift
//  AppUI · Library
//
//  One row of the sidebar. Title, subtitle, and a trailing indicator that is a
//  dot rather than a badge (docs/02-spec.md § S1).
//

import SwiftUI
import Core

/// A single document in the library list.
///
/// Three appearances, one layout:
///
/// - **Local.** Ordinary row, nothing trailing. A library where everything is
///   downloaded — the normal state, since documents are pinned on arrival — is
///   then a list of titles rather than a field of dots.
/// - **Downloading.** A `circle.fill` in tertiary, small enough to read as
///   punctuation. The row does not open; the caller disables it.
/// - **Unavailable.** The reason on its own line and a quiet
///   `exclamationmark.circle`. A document that could not be ingested shows as
///   an error row and never as a missing one (docs/04-flows.md § F1).
///
/// A local row may additionally carry a **refresh note**: it opens exactly as
/// it always did, but the last attempt to update it failed
/// (`DocumentSummary.refreshFailureReason`). That is a smaller thing than any
/// of the three above and is drawn as one — `.caption` in tertiary, under the
/// subtitle, no symbol, no tint, nothing trailing. It is not an error state and
/// must never grow into one: the row is fine, the news is that it is not new
/// (docs/01-design-principles.md §§ 1, 7).
///
/// **On failure:** there is nothing to fail. The row renders whatever summary
/// it is given, including one with no origin and no pages.
struct LibraryRow: View {

    let summary: DocumentSummary

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        layout
            .accessibilityElement(children: .combine)
            .accessibilityLabel(LibraryFormat.accessibilityLabel(for: summary))
            .accessibilityHint(hint)
    }

    /// The indicator sits beside the text normally and under it at accessibility
    /// sizes, where a fixed trailing column would squeeze the title to two
    /// characters a line (docs/01-design-principles.md § 8).
    @ViewBuilder private var layout: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 4) {
                text
                indicator
            }
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                text
                Spacer(minLength: 0)
                indicator
            }
        }
    }

    private var text: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(summary.title)
                .font(.body)
                .foregroundStyle(summary.isLocal ? Color.primary : Color.secondary)
                .lineLimit(2)
            Text(LibraryFormat.subtitle(for: summary))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if case let .unavailable(reason) = summary.localState {
                Text(reason)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            // Smaller than the subtitle and quieter than the unavailable
            // reason, because it is a smaller thing than either: the row still
            // opens. No line limit, so it wraps rather than truncating at
            // accessibility sizes.
            if let note = LibraryFormat.refreshNote(for: summary) {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    @ViewBuilder private var indicator: some View {
        switch summary.localState {
        case .local:
            EmptyView()
        case .downloading:
            Image(systemName: "circle.fill")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        case .unavailable:
            Image(systemName: "exclamationmark.circle")
                .font(.body)
                .foregroundStyle(.secondary)
        }
    }

    private var hint: String {
        switch summary.localState {
        case .local:
            // The label already carries the note; what a hint adds is that it
            // does not stop the row working, which is the one thing a reader
            // who cannot see how quietly it is drawn would otherwise guess at.
            guard summary.refreshFailureReason != nil else { return "" }
            return "Opens as usual. This is the copy already on this device."
        case .downloading:
            return "Not yet downloaded. It opens once it arrives."
        case .unavailable:
            return "This document could not be read and cannot be opened."
        }
    }
}

#Preview("Rows") {
    List {
        ForEach(DocumentSummary.previewSamples) { summary in
            LibraryRow(summary: summary)
        }
        LibraryRow(
            summary: DocumentSummary(
                id: UUID(),
                title: "2026-08-18-broken-export",
                originDisplayName: OriginKind.claudeCode.displayName,
                addedAt: Date(timeIntervalSince1970: 1_787_000_000),
                pageCount: 0,
                state: .unread,
                localState: .unavailable(reason: "source.md could not be rendered."),
                commentCount: 0,
                hasInk: false,
                folderName: "2026-08-18-broken-export"
            )
        )
        LibraryRow(
            summary: DocumentSummary(
                id: UUID(),
                title: "Retrieval eval harness",
                originDisplayName: OriginKind.cowork.displayName,
                addedAt: Date(timeIntervalSince1970: 1_786_500_000),
                pageCount: 6,
                state: .unread,
                localState: .local,
                commentCount: 0,
                hasInk: false,
                folderName: "2026-08-14-retrieval-eval-harness",
                refreshFailureReason: "The download did not finish."
            )
        )
    }
    .listStyle(.insetGrouped)
}
