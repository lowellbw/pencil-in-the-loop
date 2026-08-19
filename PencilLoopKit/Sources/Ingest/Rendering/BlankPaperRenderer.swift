//
//  BlankPaperRenderer.swift
//  Ingest · Rendering
//
//  Blank paper → PDF, so that a note is an ordinary document
//  (docs/11-backlog.md § B1).
//
//  The sibling of `MarkdownPDFRenderer`, and deliberately the same shape, for
//  the reason that file states in its own header: everything becomes a PDF at
//  ingest so there is one annotation engine and one set of page coordinates.
//  A note is that engine with a generated page instead of a rendered one, which
//  is why the reader, the ink layer, search and export all work on a notebook
//  without knowing one exists.
//
//  Nothing here paginates. There is no text to measure, no reflow and no
//  widow to avoid — every page is identical, so the "same input, same pages"
//  contract `MarkdownPDFRendering` works hard for is free.
//
//  ─── WHY THE RULING IS IN THE PDF ────────────────────────────────────────────
//  Lines could be drawn under the canvas as a view, and that would be less
//  code. It would also be wrong: the ink lives in page space and a background
//  view lives in screen space, so the first pinch-zoom would slide the
//  handwriting off the lines it was written on. Rendering the ruling into the
//  page makes it part of the same coordinate system as the strokes, exactly as
//  document text is.
//

import Foundation
import UIKit
import CoreGraphics
import Core

/// Draws plain, lined or grid paper as a PDF sized to a `PageGeometry`.
public struct BlankPaperRenderer: Sendable {

    /// A notebook longer than this is a mistake rather than a request. Pages
    /// are appended as they are needed, so the ceiling costs nobody anything.
    public static let maximumPages = 500

    /// Distance between ruled lines, in points.
    ///
    /// A handwriting measure, not a typesetting one: body text is 11pt, but
    /// handwriting with a Pencil wants roughly this much room per line, and
    /// ruling paper at the text leading would produce something nobody can
    /// write on.
    private static let linePitch: Double = 28

    /// Grid square, in points. 5mm, which is what squared paper means.
    private static let gridPitch: Double = 14.173

    /// Thin enough to sit under handwriting rather than compete with it.
    private static let ruleWidth: Double = 0.5

    public init() {}

    /// Renders `pages` identical sheets of `paper`.
    ///
    /// - Returns: the PDF bytes, ready to be written as `document.pdf`.
    /// - Throws: `PencilLoopError.renderFailed` when the page count is not
    ///   between one and `maximumPages`, when the geometry leaves no room to
    ///   rule, or when the graphics context produces nothing. There is never a
    ///   partial result — a truncated notebook would be pinned and treated as
    ///   complete.
    public func render(pages: Int, paper: PaperStyle, geometry: PageGeometry) throws -> Data {
        guard pages > 0 else {
            throw PencilLoopError.renderFailed(reason: "A notebook needs at least one page.")
        }
        guard pages <= BlankPaperRenderer.maximumPages else {
            throw PencilLoopError.renderFailed(
                reason: "A notebook can have at most \(BlankPaperRenderer.maximumPages) pages."
            )
        }
        guard geometry.pageWidth > 0, geometry.pageHeight > 0,
              geometry.textColumnWidth > 0, geometry.textColumnHeight > 0 else {
            throw PencilLoopError.renderFailed(reason: "The page geometry leaves no room to write.")
        }

        let pageSize = CGSize(width: geometry.pageWidth, height: geometry.pageHeight)
        let renderer = UIGraphicsPDFRenderer(
            bounds: CGRect(origin: CGPoint.zero, size: pageSize),
            format: UIGraphicsPDFRendererFormat()
        )

        let data = renderer.pdfData { context in
            for _ in 0..<pages {
                context.beginPage()
                self.rule(paper, geometry: geometry, into: context.cgContext)
            }
        }

        guard data.isEmpty == false else {
            throw PencilLoopError.renderFailed(reason: "The page could not be drawn.")
        }
        return data
    }

    /// Draws one sheet's ruling. `.plain` draws nothing at all, which is the
    /// whole of its implementation and the reason it cannot go wrong.
    private func rule(_ paper: PaperStyle, geometry: PageGeometry, into cgContext: CGContext) {
        let left = geometry.marginLeft
        let right = geometry.pageWidth - geometry.marginRight
        let top = geometry.marginTop
        let bottom = geometry.pageHeight - geometry.marginBottom

        switch paper {
        case .plain:
            return

        case .lined:
            cgContext.setStrokeColor(UIColor(white: 0.80, alpha: 1).cgColor)
            cgContext.setLineWidth(BlankPaperRenderer.ruleWidth)
            BlankPaperRenderer.stride(from: top, through: bottom, by: BlankPaperRenderer.linePitch)
                .forEach { y in
                    cgContext.move(to: CGPoint(x: left, y: y))
                    cgContext.addLine(to: CGPoint(x: right, y: y))
                }
            cgContext.strokePath()

        case .grid:
            // Lighter than ruled lines because there are several times as many
            // of them, and a grid at the same weight reads as a wall.
            cgContext.setStrokeColor(UIColor(white: 0.86, alpha: 1).cgColor)
            cgContext.setLineWidth(BlankPaperRenderer.ruleWidth)
            BlankPaperRenderer.stride(from: top, through: bottom, by: BlankPaperRenderer.gridPitch)
                .forEach { y in
                    cgContext.move(to: CGPoint(x: left, y: y))
                    cgContext.addLine(to: CGPoint(x: right, y: y))
                }
            BlankPaperRenderer.stride(from: left, through: right, by: BlankPaperRenderer.gridPitch)
                .forEach { x in
                    cgContext.move(to: CGPoint(x: x, y: top))
                    cgContext.addLine(to: CGPoint(x: x, y: bottom))
                }
            cgContext.strokePath()
        }
    }

    /// Positions from `start` to `limit` inclusive, stepping by `step`.
    ///
    /// Hand-rolled rather than `Swift.stride` because the last line should be
    /// drawn when it lands a hair past the margin through accumulated
    /// floating-point error, and dropping it would leave a visibly short page.
    private static func stride(from start: Double, through limit: Double, by step: Double) -> [Double] {
        guard step > 0, limit >= start else { return [] }
        let count = Int(((limit - start) / step).rounded(.down))
        return (0...count).map { start + Double($0) * step }
    }
}
