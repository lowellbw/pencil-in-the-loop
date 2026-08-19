//
//  InkTransform.swift
//  Annotate · Ink
//
//  The zoom arithmetic, as pure functions. "On zoom, scale the canvas transform
//  with the page, never re-render the strokes" (docs/03-architecture.md § 2) is
//  one line of prose and about six of maths; this is the six, kept out of the
//  view so it can be tested without one.
//

import CoreGraphics
import Foundation

/// Geometry for mapping a page's ink canvas onto whatever rectangle PDFKit has
/// currently laid the page out in.
///
/// The invariant everything else depends on: **the canvas's `bounds` are always
/// the page's size at 1.0 zoom, and zoom is expressed entirely as an affine
/// scale on the canvas's `transform`.** That keeps every stroke's coordinates in
/// page space, so a `PKDrawing` persisted today still lines up after a zoom, a
/// rotation, a relaunch, or an export by a different module.
///
/// **On failure:** degenerate input (a zero or negative dimension, a
/// non-finite size) returns the identity — a canvas at 1.0 that is merely in the
/// wrong place, rather than one with a `NaN` transform, which UIKit turns into
/// an invisible view and an afternoon of confusion.
public enum InkTransform {

    /// Scale changes smaller than this are not worth touching the view for.
    /// Pinch gestures emit a continuous stream of near-identical values.
    public static let scaleTolerance: CGFloat = 0.0005

    /// The page's size as displayed, taking the PDF `/Rotate` entry into account.
    ///
    /// PDFKit reports a page's box unrotated; a page with 90° or 270° rotation
    /// is displayed with its width and height swapped. The canvas has to match
    /// what the reader sees, because that is the space the user draws in.
    ///
    /// - Parameters:
    ///   - cropBox: the page's box size, unrotated.
    ///   - rotation: degrees, as PDFKit reports it. Any multiple of 90 —
    ///     positive or negative — is handled; anything else is treated as 0.
    public static func displaySize(cropBox: CGSize, rotation: Int) -> CGSize {
        guard InkTransform.isUsable(cropBox) else { return .zero }
        guard rotation % 90 == 0 else { return cropBox }
        let quarters = ((rotation / 90) % 4 + 4) % 4
        if quarters == 1 || quarters == 3 {
            return CGSize(width: cropBox.height, height: cropBox.width)
        }
        return cropBox
    }

    /// The scale that maps page space onto the rectangle PDFKit has given us.
    ///
    /// The smaller of the two axis ratios, so the canvas can never overhang the
    /// page it belongs to. PDFKit preserves aspect ratio, so in practice the two
    /// agree to within a rounding error.
    public static func scale(pageSize: CGSize, displayedSize: CGSize) -> CGFloat {
        guard InkTransform.isUsable(pageSize), InkTransform.isUsable(displayedSize) else { return 1 }
        return min(displayedSize.width / pageSize.width, displayedSize.height / pageSize.height)
    }

    /// The canvas transform for a given scale.
    public static func transform(scale: CGFloat) -> CGAffineTransform {
        guard scale.isFinite, scale > 0 else { return .identity }
        return CGAffineTransform(scaleX: scale, y: scale)
    }

    /// The canvas transform for a page laid out at `displayedSize`.
    public static func transform(pageSize: CGSize, displayedSize: CGSize) -> CGAffineTransform {
        InkTransform.transform(scale: InkTransform.scale(pageSize: pageSize, displayedSize: displayedSize))
    }

    /// Where to put the scaled canvas's centre inside the overlay's bounds.
    ///
    /// Position goes through `center` rather than `frame` on purpose: setting
    /// `frame` on a view with a non-identity transform is undefined, and it is
    /// the classic way to make ink drift as a page zooms.
    public static func centre(of bounds: CGRect) -> CGPoint {
        guard bounds.width.isFinite, bounds.height.isFinite else { return .zero }
        return CGPoint(x: bounds.midX, y: bounds.midY)
    }

    /// Whether a scale change is large enough to be worth applying.
    public static func hasChanged(
        from previous: CGFloat,
        to next: CGFloat,
        tolerance: CGFloat = InkTransform.scaleTolerance
    ) -> Bool {
        guard previous.isFinite, next.isFinite else { return true }
        return abs(next - previous) > max(tolerance, 0)
    }

    /// The rasterisation scale a canvas should render at once a zoom settles.
    ///
    /// A view scaled by its `transform` is rasterised at its pre-transform
    /// resolution, so strokes soften as the reader zooms in. Raising
    /// `contentScaleFactor` once the pinch ends buys the sharpness back for one
    /// re-render, at a moment when nobody is drawing. Capped, because the cost
    /// is quadratic in this number.
    public static func renderScale(
        for scale: CGFloat,
        displayScale: CGFloat,
        maximum: CGFloat = 3
    ) -> CGFloat {
        let base = displayScale.isFinite && displayScale > 0 ? displayScale : 2
        guard scale.isFinite, scale > 1 else { return base }
        let capped = min(max(maximum, 1), scale)
        return base * capped
    }

    /// A size UIKit can actually lay out.
    private static func isUsable(_ size: CGSize) -> Bool {
        size.width.isFinite && size.height.isFinite && size.width > 0 && size.height > 0
    }
}
