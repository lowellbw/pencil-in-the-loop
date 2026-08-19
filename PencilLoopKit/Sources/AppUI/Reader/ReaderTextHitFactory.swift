//
//  ReaderTextHitFactory.swift
//  AppUI · Reader
//
//  Turning a place on a page into a `CommentTextHit` — the value the comment
//  unit asks for through `CommentPageResolving.textHit(at:)`.
//
//  This is the only file in the reader that knows both PDFKit's idea of a
//  selection and the anchor's idea of one, which is what keeps PDFKit out of
//  the comment popover entirely. Nothing here expands anything: the hit is the
//  raw text under the point, and the expansion to a sentence or a line happens
//  once, inside `AnchorResolver`, which the comment unit calls
//  (Comment/Seam/CommentTextHit.swift is explicit about this).
//

import CoreGraphics
import Foundation
import PDFKit
import Core

/// Builds comment text hits from what PDFKit knows about a page.
///
/// **`CommentTextHit.selection` is always nil here, deliberately.** That field
/// indexes `DocumentDetail.extractedText` — the whole document, concatenated —
/// and PDFKit offers no mapping from a `PDFSelection` into it. A page-local
/// offset dressed up as a document-wide one anchors the comment to a different
/// sentence, which is worse than none; the comment unit locates the quote
/// itself with `AnchorResolver.exactQuoteRange(quoted:in:)`, and its own seam
/// documentation asks for nil in exactly this case.
///
/// **On failure:** never throws. A point over a page with no text layer, or one
/// PDFKit will not give a selection for, comes back as
/// `CommentTextHit.pageOnly(pageIndex:normalisedRect:)` — a comment on a figure
/// is a supported outcome, and it resolves as
/// `AnchorResolution.rectFallback`.
public enum ReaderTextHitFactory {

    /// The hit for a point on a page.
    ///
    /// - Parameters:
    ///   - point: in the page's own coordinate space —
    ///     `pdfView.convert(pointInHostView, to: page)`.
    ///   - page: the page under the point.
    ///   - pageIndex: its zero-based index in the document.
    public static func hit(atPagePoint point: CGPoint, on page: PDFPage, pageIndex: Int) -> CommentTextHit {
        let selection = page.selectionForLine(at: point)
        let bounds = selection?.bounds(for: page) ?? ReaderTextHitFactory.pointRect(around: point)
        let rect = ReaderTextHitFactory.normalisedRect(bounds, on: page)

        guard let quoted = selection?.string, !quoted.isEmpty else {
            return CommentTextHit.pageOnly(pageIndex: pageIndex, normalisedRect: rect)
        }
        return CommentTextHit(
            quotedText: quoted,
            selection: nil,
            pageIndex: pageIndex,
            normalisedRect: rect
        )
    }

    /// The hit for a selection the user made themselves, for the "Comment" item
    /// in the text-selection menu (docs/02-spec.md § S2).
    ///
    /// - Parameter selection: `PDFView.currentSelection`, or the one the edit
    ///   menu callback carried.
    public static func hit(for selection: PDFSelection, on page: PDFPage, pageIndex: Int) -> CommentTextHit {
        let bounds = selection.bounds(for: page)
        let rect = ReaderTextHitFactory.normalisedRect(bounds, on: page)

        guard let quoted = selection.string, !quoted.isEmpty else {
            return CommentTextHit.pageOnly(pageIndex: pageIndex, normalisedRect: rect)
        }
        return CommentTextHit(
            quotedText: quoted,
            selection: nil,
            pageIndex: pageIndex,
            normalisedRect: rect
        )
    }

    /// A page-space rect as a normalised one, rotation applied, top-left origin.
    public static func normalisedRect(_ pdfRect: CGRect, on page: PDFPage) -> NormalisedRect {
        ReaderPageGeometry.normalised(
            pdfRect: pdfRect,
            cropBox: page.bounds(for: .cropBox),
            rotation: page.rotation
        )
    }

    // MARK: - Support

    /// A small rect around a touch point, for a page with nothing selectable
    /// under it. Sixteen points is a Pencil tip's worth of page.
    private static func pointRect(around point: CGPoint) -> CGRect {
        CGRect(x: point.x - 8, y: point.y - 8, width: 16, height: 16)
    }
}
