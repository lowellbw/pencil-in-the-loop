//
//  Anchor.swift
//  Core · Contracts
//
//  What a comment is attached to. Keys match `review.json` exactly:
//  quoted · prefix · suffix · pageIndex · normalisedRect · sourceRange.
//
//  Anchors are quoted text, never line numbers (CLAUDE.md non-negotiable 5).
//  The rect is a fallback for when the text has changed under us, not the
//  primary key.
//

import Foundation

/// The passage a comment refers to, captured at annotation time and re-resolved
/// later by whatever tool reads the review.
///
/// `prefix` and `suffix` carry `AnchorResolver.contextLength` characters of
/// surrounding text (32, per docs/02-spec.md § S3). They exist so a quote that
/// appears twice in a document still resolves to the right occurrence.
///
/// Encodes exactly as the `anchor` object in `review.json`:
/// ```json
/// {
///   "quoted": "…", "prefix": "…", "suffix": "…",
///   "pageIndex": 0,
///   "normalisedRect": [0.12, 0.34, 0.76, 0.04],
///   "sourceRange": [1204, 1268]
/// }
/// ```
/// `sourceRange` is omitted entirely when nil — it only exists when the document
/// came from markdown and a `sourcemap.json` was generated.
public struct Anchor: Codable, Sendable, Hashable {

    /// The selected text, exactly as it appeared in the document. This is the
    /// primary key for resolution and it must not be trimmed, re-wrapped or
    /// whitespace-collapsed at capture time — normalisation happens during
    /// fuzzy matching, and only there.
    public var quoted: String

    /// Up to `AnchorResolver.contextLength` characters immediately before
    /// `quoted`. Empty when the quote starts the document.
    public var prefix: String

    /// Up to `AnchorResolver.contextLength` characters immediately after
    /// `quoted`. Empty when the quote ends the document.
    public var suffix: String

    /// Zero-based page index in `document.pdf`. Zero-based everywhere in code;
    /// `review.md` prose displays it one-based ("page 1" == `pageIndex` 0).
    public var pageIndex: Int

    /// Where the quote sits on that page, top-left origin. Used to place the
    /// margin marker, to crop ink, and as the last-resort anchor when no text
    /// match survives.
    public var normalisedRect: NormalisedRect

    /// The byte range in `source.md`, when a source map exists. Nil for a PDF
    /// that was never rendered from markdown.
    public var sourceRange: SourceRange?

    public init(
        quoted: String,
        prefix: String = "",
        suffix: String = "",
        pageIndex: Int,
        normalisedRect: NormalisedRect,
        sourceRange: SourceRange? = nil
    ) {
        self.quoted = quoted
        self.prefix = prefix
        self.suffix = suffix
        self.pageIndex = pageIndex
        self.normalisedRect = normalisedRect
        self.sourceRange = sourceRange
    }

    /// One-line form for the review sheet and the popover header, truncated
    /// with an ellipsis. Whitespace is collapsed for display only — the stored
    /// `quoted` is never modified.
    public func excerpt(maxLength: Int = 80) -> String {
        let collapsed = quoted
            .split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .joined(separator: " ")
        guard collapsed.count > maxLength else { return collapsed }
        let cut = collapsed.prefix(maxLength)
        return String(cut) + "…"
    }

    /// `prefix + quoted + suffix`, the string step 1 of the resolver looks for.
    public var contextualQuote: String { prefix + quoted + suffix }

    enum CodingKeys: String, CodingKey {
        case quoted
        case prefix
        case suffix
        case pageIndex
        case normalisedRect
        case sourceRange
    }

    /// Custom only to omit `sourceRange` rather than emit `null` — external
    /// tools treat a missing key and a null the same, but the fixtures don't.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(quoted, forKey: .quoted)
        try container.encode(prefix, forKey: .prefix)
        try container.encode(suffix, forKey: .suffix)
        try container.encode(pageIndex, forKey: .pageIndex)
        try container.encode(normalisedRect, forKey: .normalisedRect)
        try container.encodeIfPresent(sourceRange, forKey: .sourceRange)
    }

    /// Tolerant on everything except `quoted`: a missing prefix, suffix, page
    /// index or rect degrades to empty / zero rather than throwing, because an
    /// anchor that only knows its quote is still a usable anchor.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.quoted = try container.decode(String.self, forKey: .quoted)
        self.prefix = (try? container.decode(String.self, forKey: .prefix)) ?? ""
        self.suffix = (try? container.decode(String.self, forKey: .suffix)) ?? ""
        self.pageIndex = (try? container.decode(Int.self, forKey: .pageIndex)) ?? 0
        self.normalisedRect = (try? container.decode(NormalisedRect.self, forKey: .normalisedRect)) ?? .zero
        self.sourceRange = try? container.decodeIfPresent(SourceRange.self, forKey: .sourceRange)
    }
}
