//
//  CommentTextHit.swift
//  AppUI · Comment · Seam
//
//  What the Reader hands back when asked "what text is under this point?".
//  Everything the anchor needs and nothing about how it was found, so that a
//  `PDFSelection`, a source-map lookup, or a future non-PDFKit reader all
//  answer the same shape.
//

import Foundation
import Core

/// One text selection near a touch point, in the form
/// `AnchorResolver.captureAnchor(in:selection:pageIndex:normalisedRect:sourceRange:)`
/// wants it (docs/02-spec.md § S3).
///
/// **Nothing here is expanded.** The Reader returns the raw hit — a word, a
/// line, whatever `PDFPage.selectionForLine(at:)` produced — and the expansion
/// to a sentence or a line happens once, inside `AnchorResolver`, which is
/// idempotent and shared with the resolver on the agent's side. A Reader that
/// expands first is not wrong, just redundant.
///
/// **When there is no text under the point** the Reader returns nil rather than
/// an empty hit, and the comment is captured against the page rect alone. That
/// is a supported outcome — a comment on a figure has no quote — and it
/// resolves as `AnchorResolution.rectFallback`.
public struct CommentTextHit: Sendable, Hashable {

    /// The selected text exactly as it appears in the document: not trimmed,
    /// not whitespace-collapsed, not re-wrapped. `AnchorResolver` normalises
    /// during fuzzy matching and only there, so a hit that was tidied here
    /// stops matching exactly at step 1.
    public var quotedText: String

    /// Where `quotedText` sits in `DocumentDetail.extractedText`, as UTF-8 byte
    /// offsets.
    ///
    /// **Optional on purpose.** Mapping a `PDFSelection` back to an offset in
    /// the concatenated extracted text is fiddly and easy to get subtly wrong,
    /// and a wrong offset is worse than none: it anchors the comment to a
    /// different sentence. A Reader that cannot compute it confidently passes
    /// nil, and `CommentCaptureModel` locates the quote itself with
    /// `AnchorResolver.exactQuoteRange(quoted:in:nearOffset:)`. Passing a
    /// correct range is still better — it disambiguates a sentence that occurs
    /// twice.
    public var selection: SourceRange?

    /// Zero-based page the hit landed on.
    public var pageIndex: Int

    /// The selection's bounding box on that page, **top-left origin, y
    /// increasing downwards** (`NormalisedRect`). PDF user space is bottom-up,
    /// so this is a flip away from `PDFPage.bounds(for:)`; getting it backwards
    /// puts every marker at the wrong end of the page and nothing crashes to
    /// say so.
    public var normalisedRect: NormalisedRect

    public init(
        quotedText: String,
        selection: SourceRange? = nil,
        pageIndex: Int,
        normalisedRect: NormalisedRect
    ) {
        self.quotedText = quotedText
        self.selection = selection
        self.pageIndex = pageIndex
        self.normalisedRect = normalisedRect
    }

    /// A hit with no text: a tap on a figure, a margin, or a page whose text
    /// layer is empty. Anchors captured from one carry an empty `quoted` and
    /// resolve by rect.
    public static func pageOnly(pageIndex: Int, normalisedRect: NormalisedRect) -> CommentTextHit {
        CommentTextHit(quotedText: "", pageIndex: pageIndex, normalisedRect: normalisedRect)
    }

    /// True when there is a quote worth storing.
    public var hasText: Bool {
        quotedText.contains(where: { !$0.isWhitespace && !$0.isNewline })
    }
}
