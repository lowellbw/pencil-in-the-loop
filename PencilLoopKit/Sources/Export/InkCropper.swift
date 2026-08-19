//
//  InkCropper.swift
//  Export
//
//  One PNG per inked page (docs/05-file-contracts.md § Ink images).
//
//  Three rules, all of them load-bearing:
//
//  · **Only inked pages.** A 50-page document with marks on two pages sends two
//    images. This is the difference between a cheap review and an absurd one,
//    and it is the caller's filter as much as ours — `ReviewDraft.inkedPages`.
//  · **Page content underneath.** An arrow with nothing to point at is useless;
//    position is content. The PDF page is drawn first, the strokes over it.
//  · **Union plus 15% each side, long edge capped at 2048px.** Enough
//    surrounding text to read the mark in context, small enough that a review
//    with marks on eight pages is still an email rather than an upload.
//

import Foundation
import CoreGraphics
import PDFKit
import PencilKit
import UIKit
import Core

/// Crops one page of ink to a PNG with the page content rendered beneath it.
///
/// **On failure:** throws `PencilLoopError.bundleBuildFailed`. The builder
/// catches it, skips that page and keeps the comment text — losing a whole
/// review because one PNG would not encode is not a trade worth making.
///
/// **Never on the main actor.** Rendering a PDF page and rasterising strokes is
/// exactly the work the bundle build is supposed to keep off the touch path.
public struct InkCropper: InkCropping {

    /// Points-to-pixels scale before the long-edge cap applies.
    ///
    /// 2 is the retina factor: at 1 the body text under a margin note is legible
    /// but not comfortable, and beyond 2 the cap does the deciding anyway for
    /// anything larger than about a third of a page.
    public static let renderScale: CGFloat = 2

    /// Smallest crop dimension, as a fraction of the page.
    ///
    /// A single vertical stroke has zero width, and 15% of zero is zero. Without
    /// a floor that produces a one-pixel-wide image of nothing.
    public static let minimumCropFraction: CGFloat = 0.08

    private let scale: CGFloat

    /// - Parameter scale: points-to-pixels before the cap. Injected so a test
    ///   can pin the geometry without asserting on a retina constant.
    public init(scale: CGFloat = InkCropper.renderScale) {
        self.scale = scale
    }

    // MARK: - InkCropping

    public func cropInk(
        pdfURL: URL,
        pageIndex: Int,
        drawingData: Data,
        recognisedText: String?
    ) async throws -> InkImage {
        guard pageIndex >= 0 else {
            throw PencilLoopError.bundleBuildFailed(reason: "Page index \(pageIndex) is negative.")
        }
        guard let document = PDFDocument(url: pdfURL) else {
            throw PencilLoopError.bundleBuildFailed(
                reason: "The document could not be opened to render page \(pageIndex + 1) beneath its ink."
            )
        }
        guard let page = document.page(at: pageIndex) else {
            throw PencilLoopError.bundleBuildFailed(
                reason: "The document has no page \(pageIndex + 1)."
            )
        }

        let drawing: PKDrawing
        do {
            drawing = try PKDrawing(data: drawingData)
        } catch {
            throw PencilLoopError.bundleBuildFailed(
                reason: "The ink on page \(pageIndex + 1) could not be read. \(error.localizedDescription)"
            )
        }

        let pageSize = InkCropper.canvasSize(for: page)
        guard pageSize.width > 0, pageSize.height > 0 else {
            throw PencilLoopError.bundleBuildFailed(
                reason: "Page \(pageIndex + 1) has no usable size."
            )
        }

        let strokeBounds = drawing.strokes.map { $0.renderBounds }
        guard let crop = InkCropper.cropRect(strokeBounds: strokeBounds, pageSize: pageSize) else {
            throw PencilLoopError.bundleBuildFailed(
                reason: "Page \(pageIndex + 1) is marked as inked but carries no strokes inside the page."
            )
        }

        let pixels = InkCropper.pixelSize(for: crop, scale: scale)
        let renderedScale = InkCropper.renderedScale(for: crop, scale: scale)
        guard pixels.width >= 1, pixels.height >= 1, renderedScale > 0,
              crop.width > 0, crop.height > 0 else {
            throw PencilLoopError.bundleBuildFailed(
                reason: "The crop for page \(pageIndex + 1) is empty."
            )
        }
        // A plain format rather than `.preferred()`: that reads the trait
        // environment, which is main-actor work in the Swift 6 UIKit overlay,
        // and this is deliberately the one place in Export that runs off the
        // main actor. Both properties it would have inherited are overridden on
        // the next two lines anyway, so there is nothing to inherit.
        let format = UIGraphicsImageRendererFormat()
        // The size below is already in pixels, so the renderer must not scale it
        // again — otherwise the 2048 cap is silently a 4096 cap on a retina
        // device and the bundle triples in size.
        format.scale = 1
        format.opaque = true

        // The scale the *image* is in, which is not quite `renderedScale`:
        // `pixelSize(for:scale:)` floors, so the pixel box is up to a pixel
        // shorter than `crop × renderedScale`. Deriving the transform from
        // `renderedScale` would map `crop.maxY` onto `pixels.height` and
        // `crop.minY` a fraction of a pixel below the top edge, while the ink
        // layer below is stretched to fill the box exactly — one pixel of
        // daylight between an arrow and the word it points at. Position is the
        // content here, so both layers are derived from the same box.
        let scaleX = pixels.width / crop.width
        let scaleY = pixels.height / crop.height

        let renderer = UIGraphicsImageRenderer(size: pixels, format: format)
        let image = renderer.image { context in
            let cgContext = context.cgContext

            UIColor.white.setFill()
            cgContext.fill(CGRect(origin: .zero, size: pixels))

            // Page content first. PDF user space is bottom-up, the renderer's
            // context is top-down, so flip and then slide the crop's top-left
            // corner to the origin. Getting this backwards renders the far end
            // of the page and nothing crashes to tell you.
            cgContext.saveGState()
            cgContext.translateBy(x: 0, y: pixels.height)
            cgContext.scaleBy(x: scaleX, y: -scaleY)
            cgContext.translateBy(x: -crop.minX, y: -(pageSize.height - crop.maxY))
            page.draw(with: .mediaBox, to: cgContext)
            cgContext.restoreGState()

            // Then the strokes. `PKDrawing` coordinates are the canvas's, and the
            // canvas is one page laid over the page view at page size with a
            // top-left origin (docs/03-architecture.md § 2), which is the same
            // space `crop` is in.
            let ink = drawing.image(from: crop, scale: renderedScale)
            ink.draw(in: CGRect(origin: .zero, size: pixels))
        }

        guard let pngData = image.pngData() else {
            throw PencilLoopError.bundleBuildFailed(
                reason: "The ink image for page \(pageIndex + 1) could not be encoded as PNG."
            )
        }

        return InkImage(
            pageIndex: pageIndex,
            relativePath: InkImage.fileName(forPageIndex: pageIndex),
            pngData: pngData,
            recognisedText: recognisedText
        )
    }

    // MARK: - Geometry

    /// The crop rectangle in page points, top-left origin.
    ///
    /// The union of every stroke's bounds, grown by
    /// `InkImage.paddingFraction` of the union's own size on each side, floored
    /// at `minimumCropFraction` of the page in either axis, then clamped to the
    /// page. Pure and static so the geometry can be tested without PencilKit,
    /// which cannot be exercised anywhere but a device.
    ///
    /// - Returns: nil when there is nothing to crop to.
    public static func cropRect(strokeBounds: [CGRect], pageSize: CGSize) -> CGRect? {
        guard pageSize.width > 0, pageSize.height > 0 else { return nil }

        // Min/max by hand rather than `CGRect.union`, which special-cases empty
        // rectangles: a single tap of the pencil is a zero-size bounds at a real
        // position, and losing that position would put the crop somewhere else
        // entirely. The floor further down gives it a size.
        var found = false
        var minX = CGFloat.greatestFiniteMagnitude
        var minY = CGFloat.greatestFiniteMagnitude
        var maxX = -CGFloat.greatestFiniteMagnitude
        var maxY = -CGFloat.greatestFiniteMagnitude

        for bounds in strokeBounds {
            guard !bounds.isNull, !bounds.isInfinite else { continue }
            let standard = bounds.standardized
            guard standard.minX.isFinite, standard.minY.isFinite,
                  standard.maxX.isFinite, standard.maxY.isFinite else { continue }
            minX = min(minX, standard.minX)
            minY = min(minY, standard.minY)
            maxX = max(maxX, standard.maxX)
            maxY = max(maxY, standard.maxY)
            found = true
        }
        guard found else { return nil }

        let union = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)

        // `insetBy` with a negative delta grows: 15% of the union's width on the
        // left and 15% on the right, which is what "15% padding on each side"
        // means and what NormalisedRect.insetBy(fraction: -0.15) does.
        let padding = CGFloat(InkImage.paddingFraction)
        var padded = union.insetBy(dx: -union.width * padding, dy: -union.height * padding)

        let floorWidth = pageSize.width * minimumCropFraction
        let floorHeight = pageSize.height * minimumCropFraction
        if padded.width < floorWidth {
            padded = padded.insetBy(dx: -(floorWidth - padded.width) / 2, dy: 0)
        }
        if padded.height < floorHeight {
            padded = padded.insetBy(dx: 0, dy: -(floorHeight - padded.height) / 2)
        }

        let page = CGRect(origin: .zero, size: pageSize)
        let clamped = padded.intersection(page)
        guard !clamped.isNull, clamped.width > 0, clamped.height > 0 else { return nil }
        return clamped
    }

    /// The output size in pixels for a crop.
    ///
    /// `scale` is an upper bound, never a target: a crop is rendered at `scale`
    /// unless that would put the long edge past
    /// `InkImage.maxLongEdgePixels`, in which case it is rendered at whatever
    /// scale lands exactly on the cap. Small crops are never blown up to reach
    /// it — a cap is a ceiling, not a size.
    public static func pixelSize(for cropRect: CGRect, scale: CGFloat) -> CGSize {
        let effective = renderedScale(for: cropRect, scale: scale)
        guard effective > 0 else { return .zero }

        let cap = CGFloat(InkImage.maxLongEdgePixels)
        let width = max(1, (cropRect.width * effective).rounded(.down))
        let height = max(1, (cropRect.height * effective).rounded(.down))
        return CGSize(width: min(width, cap), height: min(height, cap))
    }

    /// The points-to-pixels factor actually used, after the long-edge cap.
    ///
    /// `min(scale, 2048 / longest edge)`. Never larger than `scale`: a mark in
    /// the corner of a page does not become a 2048px image of a corner.
    public static func renderedScale(for cropRect: CGRect, scale: CGFloat) -> CGFloat {
        let longEdge = max(cropRect.width, cropRect.height)
        guard longEdge > 0, scale > 0, longEdge.isFinite else { return 0 }
        return min(scale, CGFloat(InkImage.maxLongEdgePixels) / longEdge)
    }

    /// The size of the canvas the strokes were drawn on, which is the page's own
    /// size with its rotation applied.
    ///
    /// A page rotated 90° presents a landscape box to the reader, so the canvas
    /// laid over it is landscape too.
    static func canvasSize(for page: PDFPage) -> CGSize {
        let bounds = page.bounds(for: .mediaBox)
        let rotation = ((page.rotation % 360) + 360) % 360
        if rotation == 90 || rotation == 270 {
            return CGSize(width: bounds.height, height: bounds.width)
        }
        return bounds.size
    }
}
