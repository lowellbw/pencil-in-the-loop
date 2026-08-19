//
//  NormalisedRect.swift
//  Core · Contracts
//
//  A rectangle in normalised page coordinates, encoded as the JSON array
//  `[x, y, width, height]` to match `review.json` and `sourcemap.json`.
//
//  CGRect is deliberately absent from every Codable contract in this package.
//  Its coding format is keyed (`{"origin":{"x":…}}`), it is a CoreGraphics type
//  we do not control, and docs/05-file-contracts.md shows a four-element array.
//  Convert at the edges: PDFKit and PencilKit hand you CGRects, and the module
//  that touches them is the module that normalises them.
//

import Foundation

/// A rectangle expressed as fractions of a page, origin top-left.
///
/// **Coordinate space — read this before converting anything.** `x` and `y` are
/// fractions of page width and height, measured from the **top-left** corner
/// with `y` increasing **downwards**, matching UIKit view space. PDF user space
/// is bottom-up, so any conversion out of `PDFPage.bounds(for:)` must flip:
/// `y = 1 - (pdfY + height) / pageHeight`. Getting this backwards puts every
/// comment marker at the wrong end of the page, and nothing will crash to tell
/// you.
///
/// Values are not clamped on decode. A rect may legitimately extend past a page
/// edge (a stroke drawn off the margin), so `0…1` is a convention, not a rule.
/// Use `clamped()` when you need it inside the unit square.
///
/// Encodes as `[x, y, width, height]`, four JSON numbers, in that order.
public struct NormalisedRect: Codable, Sendable, Hashable {

    /// Distance from the left page edge, as a fraction of page width.
    public var x: Double
    /// Distance from the **top** page edge, as a fraction of page height.
    public var y: Double
    /// Width, as a fraction of page width.
    public var width: Double
    /// Height, as a fraction of page height.
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    /// Build a normalised rect from a CGRect-shaped set of point values by
    /// dividing through by the page size.
    ///
    /// Takes four Doubles rather than a CGRect so that Core stays free of
    /// CoreGraphics. Pass the values already flipped into top-left origin
    /// space — this initialiser divides, it does not flip.
    ///
    /// - Returns: a rect of zeroes when `pageWidth` or `pageHeight` is zero or
    ///   negative, rather than producing infinities.
    public init(
        cgRectLikeX x: Double,
        y: Double,
        width: Double,
        height: Double,
        inPageWidth pageWidth: Double,
        pageHeight: Double
    ) {
        guard pageWidth > 0, pageHeight > 0 else {
            self.init(x: 0, y: 0, width: 0, height: 0)
            return
        }
        self.init(
            x: x / pageWidth,
            y: y / pageHeight,
            width: width / pageWidth,
            height: height / pageHeight
        )
    }

    /// The whole page.
    public static let unit = NormalisedRect(x: 0, y: 0, width: 1, height: 1)

    /// A rect of zero size at the origin. Used as the "no useful geometry"
    /// value; prefer it to an optional in DTOs that must stay Codable-simple.
    public static let zero = NormalisedRect(x: 0, y: 0, width: 0, height: 0)

    // MARK: - Derived geometry

    public var minX: Double { min(x, x + width) }
    public var maxX: Double { max(x, x + width) }
    public var minY: Double { min(y, y + height) }
    public var maxY: Double { max(y, y + height) }
    public var midX: Double { (minX + maxX) / 2 }
    public var midY: Double { (minY + maxY) / 2 }
    public var area: Double { abs(width * height) }
    public var isEmpty: Bool { width == 0 || height == 0 }

    /// Straight-line distance between the centres of two rects, in normalised
    /// units. Used by `SourceMap.range(nearest:page:)` to pick the closest
    /// laid-out run to a touch point.
    public func centreDistance(to other: NormalisedRect) -> Double {
        let dx = midX - other.midX
        let dy = midY - other.midY
        return (dx * dx + dy * dy).squareRoot()
    }

    public func contains(x pointX: Double, y pointY: Double) -> Bool {
        pointX >= minX && pointX <= maxX && pointY >= minY && pointY <= maxY
    }

    public func intersects(_ other: NormalisedRect) -> Bool {
        minX <= other.maxX && maxX >= other.minX && minY <= other.maxY && maxY >= other.minY
    }

    // MARK: - Combining

    /// The smallest rect containing both. The ink cropper unions every stroke's
    /// bounding box this way before padding (docs/05-file-contracts.md § Ink
    /// images).
    ///
    /// An empty rect at the origin is treated as "nothing", so
    /// `.zero.union(r) == r`. That makes `reduce(.zero, { $0.union($1) })` do
    /// the right thing over a stroke list.
    public func union(_ other: NormalisedRect) -> NormalisedRect {
        if self == .zero { return other }
        if other == .zero { return self }
        let newMinX = min(minX, other.minX)
        let newMinY = min(minY, other.minY)
        let newMaxX = max(maxX, other.maxX)
        let newMaxY = max(maxY, other.maxY)
        return NormalisedRect(
            x: newMinX,
            y: newMinY,
            width: newMaxX - newMinX,
            height: newMaxY - newMinY
        )
    }

    /// Grow (negative fraction) or shrink (positive fraction) by a proportion of
    /// this rect's own size, on all four sides.
    ///
    /// The ink cropper wants `insetBy(fraction: -0.15)` — 15% padding on each
    /// side so the surrounding text stays visible for context.
    public func insetBy(fraction: Double) -> NormalisedRect {
        let dx = width * fraction
        let dy = height * fraction
        return NormalisedRect(
            x: x + dx,
            y: y + dy,
            width: width - dx * 2,
            height: height - dy * 2
        )
    }

    /// Clamp into the unit square, discarding any part that falls off the page.
    public func clamped() -> NormalisedRect {
        let newMinX = min(max(minX, 0), 1)
        let newMinY = min(max(minY, 0), 1)
        let newMaxX = min(max(maxX, 0), 1)
        let newMaxY = min(max(maxY, 0), 1)
        return NormalisedRect(
            x: newMinX,
            y: newMinY,
            width: max(0, newMaxX - newMinX),
            height: max(0, newMaxY - newMinY)
        )
    }

    /// Multiply back out to a point size. Returns a tuple rather than a CGRect
    /// so Core stays CoreGraphics-free; the caller builds the CGRect.
    public func denormalised(
        inPageWidth pageWidth: Double,
        pageHeight: Double
    ) -> (x: Double, y: Double, width: Double, height: Double) {
        (x * pageWidth, y * pageHeight, width * pageWidth, height * pageHeight)
    }

    // MARK: - Codable

    /// Encodes as `[x, y, width, height]`.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.unkeyedContainer()
        try container.encode(x)
        try container.encode(y)
        try container.encode(width)
        try container.encode(height)
    }

    /// Decodes `[x, y, width, height]`. A shorter array throws; extra elements
    /// are ignored so a future format that appends a fifth number still reads.
    public init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        let x = try container.decode(Double.self)
        let y = try container.decode(Double.self)
        let width = try container.decode(Double.self)
        let height = try container.decode(Double.self)
        self.init(x: x, y: y, width: width, height: height)
    }
}

extension NormalisedRect: CustomStringConvertible {
    public var description: String {
        "[\(x), \(y), \(width), \(height)]"
    }
}
