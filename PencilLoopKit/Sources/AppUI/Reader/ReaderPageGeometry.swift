//
//  ReaderPageGeometry.swift
//  AppUI · Reader
//
//  The conversion between PDF user space and the normalised, top-left space
//  every stored rect in this project uses (Core/Contracts/NormalisedRect.swift).
//  Pure arithmetic, kept out of the views so it can be read — and one day
//  tested — without a `PDFPage`.
//
//  Two flips happen here and both are easy to get backwards, which is why they
//  live in one place:
//
//  · PDF user space is bottom-up. Ours is top-down, matching UIKit.
//  · A page with a `/Rotate` entry is displayed rotated. The canvas, the ink and
//    the anchors all live in *displayed* space (Annotate/Ink/InkTransform.swift
//    says so for ink, and an anchor that disagreed with the ink would put a
//    marker and the note about it on opposite sides of the page).
//

import CoreGraphics
import Foundation
import Core

/// Maps rectangles between a PDF page's user space and normalised display
/// space.
///
/// **On failure:** degenerate input — an empty crop box, a non-finite rect —
/// comes back as `NormalisedRect.zero` or `CGRect.zero` rather than as
/// infinities. A marker in the wrong place is a bug you can see; a `NaN` rect is
/// an invisible view and an afternoon of confusion.
public enum ReaderPageGeometry {

    /// A PDF-space rect as a normalised rect in displayed space, origin
    /// top-left, `y` increasing downwards.
    ///
    /// - Parameters:
    ///   - pdfRect: a rect in the page's user space, as
    ///     `PDFSelection.bounds(for:)` and `PDFPage.characterBounds(at:)` return
    ///     it.
    ///   - cropBox: `page.bounds(for: .cropBox)`, unrotated.
    ///   - rotation: `page.rotation`, in degrees. Any multiple of 90, positive
    ///     or negative; anything else is treated as 0.
    public static func normalised(pdfRect: CGRect, cropBox: CGRect, rotation: Int) -> NormalisedRect {
        guard ReaderPageGeometry.isUsable(cropBox), ReaderPageGeometry.isUsable(pdfRect) else {
            return .zero
        }

        // Into unrotated, top-left, fractional space first.
        let x = (pdfRect.minX - cropBox.minX) / cropBox.width
        let y = 1 - ((pdfRect.maxY - cropBox.minY) / cropBox.height)
        let width = pdfRect.width / cropBox.width
        let height = pdfRect.height / cropBox.height

        switch ReaderPageGeometry.quarters(rotation) {
        case 1:
            return NormalisedRect(x: 1 - y - height, y: x, width: height, height: width)
        case 2:
            return NormalisedRect(x: 1 - x - width, y: 1 - y - height, width: width, height: height)
        case 3:
            return NormalisedRect(x: y, y: 1 - x - width, width: height, height: width)
        default:
            return NormalisedRect(x: x, y: y, width: width, height: height)
        }
    }

    /// The inverse: a normalised rect in displayed space back to a rect in the
    /// page's user space, for placing a `PDFAnnotation`.
    public static func pdfRect(normalised rect: NormalisedRect, cropBox: CGRect, rotation: Int) -> CGRect {
        guard ReaderPageGeometry.isUsable(cropBox) else { return .zero }

        let x: Double
        let y: Double
        let width: Double
        let height: Double

        switch ReaderPageGeometry.quarters(rotation) {
        case 1:
            width = rect.height
            height = rect.width
            x = rect.y
            y = 1 - rect.x - rect.width
        case 2:
            width = rect.width
            height = rect.height
            x = 1 - rect.x - rect.width
            y = 1 - rect.y - rect.height
        case 3:
            width = rect.height
            height = rect.width
            x = 1 - rect.y - rect.height
            y = rect.x
        default:
            width = rect.width
            height = rect.height
            x = rect.x
            y = rect.y
        }

        let originX = cropBox.minX + x * cropBox.width
        let originY = cropBox.minY + (1 - y - height) * cropBox.height
        let converted = CGRect(
            x: originX,
            y: originY,
            width: width * cropBox.width,
            height: height * cropBox.height
        )
        return ReaderPageGeometry.isUsable(converted) ? converted : .zero
    }

    /// Rotation in quarter turns, 0…3. Anything that is not a multiple of 90 is
    /// 0 — the same rule `InkTransform.displaySize(cropBox:rotation:)` applies,
    /// so the ink and the anchors cannot disagree about which way up a page is.
    public static func quarters(_ rotation: Int) -> Int {
        guard rotation % 90 == 0 else { return 0 }
        return ((rotation / 90) % 4 + 4) % 4
    }

    /// A rect UIKit and PDFKit can both make sense of.
    private static func isUsable(_ rect: CGRect) -> Bool {
        rect.width.isFinite && rect.height.isFinite
            && rect.origin.x.isFinite && rect.origin.y.isFinite
            && rect.width > 0 && rect.height > 0
    }
}
