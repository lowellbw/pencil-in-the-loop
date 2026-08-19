//
//  LibraryFormat.swift
//  AppUI · Library
//
//  The strings one library row shows, in one place. `DocumentSummary` carries
//  the parts and deliberately does not assemble them (DTOs.swift § Library):
//  relative dates change while a view is on screen, and how they read is a
//  locale decision this layer owns.
//

import Foundation
import Core

/// Subtitle and VoiceOver text for a library row (docs/02-spec.md § S1).
///
/// **On failure:** total. Every member returns a string for every input; a
/// summary with a zero page count or an empty origin simply produces a shorter
/// line.
public enum LibraryFormat {

    /// "Cowork · 8 min ago · 4 pages", exactly the subtitle in the spec.
    ///
    /// - Parameter now: injectable so the phrasing can be checked without
    ///   waiting for the clock to move.
    public static func subtitle(for summary: DocumentSummary, now: Date = Date()) -> String {
        parts(for: summary, now: now).joined(separator: " · ")
    }

    /// The same information as one sentence, for VoiceOver.
    ///
    /// Title first, then the subtitle parts, then anything the trailing dot is
    /// saying — a dot has no accessible form of its own, so the state has to be
    /// spoken here (docs/01-design-principles.md § 8).
    public static func accessibilityLabel(for summary: DocumentSummary, now: Date = Date()) -> String {
        var pieces = [summary.title]
        pieces.append(contentsOf: parts(for: summary, now: now))
        if summary.commentCount > 0 {
            pieces.append(count(summary.commentCount, one: "comment", many: "comments"))
        }
        if let state = localStateDescription(summary.localState) {
            pieces.append(state)
        }
        if let note = refreshNote(for: summary) {
            pieces.append(note)
        }
        return pieces.joined(separator: ", ")
    }

    /// The quiet second line under a row that still opens but did not refresh,
    /// or nil for a row with nothing to add — which is nearly all of them.
    ///
    /// Phrased like `localStateDescription(_:)`'s "Unavailable. …" so the two
    /// read as the same kind of remark, and worded so the row's own claim is
    /// the small one: this document is readable and this is the copy you have.
    /// The reason is the store's sentence, shown verbatim — a note that will
    /// not say what went wrong is a note that cannot be acted on
    /// (DTOs.swift § `DocumentSummary.refreshFailureReason`).
    public static func refreshNote(for summary: DocumentSummary) -> String? {
        guard let reason = summary.refreshFailureReason,
              reason.isEmpty == false else { return nil }
        return "Couldn’t update. " + reason
    }

    /// What the trailing indicator means, spelled out. Nil for a document that
    /// is simply here, which is the ordinary case and needs no announcement.
    public static func localStateDescription(_ state: DocumentLocalState) -> String? {
        switch state {
        case .local:
            return nil
        case let .downloading(progress):
            guard let progress else { return "Downloading" }
            return "Downloading, " + percent(progress)
        case let .unavailable(reason):
            return "Unavailable. " + reason
        }
    }

    /// "8 min ago", "yesterday", "last week" — the system's phrasing, not ours.
    public static func relativeDate(_ date: Date, now: Date = Date()) -> String {
        LibraryFormat.relativeFormatter.localizedString(for: date, relativeTo: now)
    }

    /// "4 pages", "1 page".
    public static func pages(_ pageCount: Int) -> String {
        count(pageCount, one: "page", many: "pages")
    }

    // MARK: - Internals

    private static func parts(for summary: DocumentSummary, now: Date) -> [String] {
        var pieces: [String] = []
        if summary.originDisplayName.isEmpty == false {
            pieces.append(summary.originDisplayName)
        }
        pieces.append(relativeDate(summary.addedAt, now: now))
        pieces.append(pages(summary.pageCount))
        return pieces
    }

    private static func count(_ value: Int, one: String, many: String) -> String {
        "\(value) " + (value == 1 ? one : many)
    }

    private static func percent(_ fraction: Double) -> String {
        let clamped = min(max(fraction, 0), 1)
        return clamped.formatted(.percent.precision(.fractionLength(0)))
    }

    /// Abbreviated because the spec's example is "8 min ago" rather than
    /// "8 minutes ago", and because the subtitle shares a line with two other
    /// parts.
    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()
}
