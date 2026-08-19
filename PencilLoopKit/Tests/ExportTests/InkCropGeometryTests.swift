//
//  InkCropGeometryTests.swift
//  ExportTests
//
//  The crop arithmetic, which is the only part of ink export that can be tested
//  off a device. Rasterising a `PKDrawing` over a `PDFPage` cannot: PencilKit
//  needs Pencil input to produce anything, and faking a drawing would prove
//  nothing (STYLE.md § 10).
//
//  **What to check by hand on device, once there is one:**
//
//  1. Draw an arrow in the right margin pointing at a paragraph. The exported
//     PNG must show the paragraph, not just the arrow — position is content.
//  2. Draw on page 1 and page 3 of a 50-page document. Exactly two PNGs, named
//     `ink/page-01.png` and `ink/page-03.png`.
//  3. Draw a stroke that runs off the page edge. The crop clamps to the page and
//     the stroke is not lost.
//  4. Draw on a page rotated 90° in the source PDF. The content underneath is
//     the right way up and lines up with the strokes.
//  5. Cover a whole A4 page in ink. The PNG's long edge is 2048px, not 3368.
//

import XCTest
import Foundation
import CoreGraphics
import Core
@testable import Export

final class InkCropGeometryTests: XCTestCase {

    // MARK: - The union

    func testMultipleStrokesAreUnioned() throws {
        let crop = try XCTUnwrap(
            InkCropper.cropRect(
                strokeBounds: [
                    CGRect(x: 100, y: 200, width: 100, height: 50),
                    CGRect(x: 150, y: 300, width: 50, height: 20)
                ],
                pageSize: Self.page
            )
        )
        // Union is (100, 200, 100, 120); 15% of 100 and of 120 on each side.
        XCTAssertEqual(crop.minX, 85, accuracy: 0.001)
        XCTAssertEqual(crop.minY, 182, accuracy: 0.001)
        XCTAssertEqual(crop.width, 130, accuracy: 0.001)
        XCTAssertEqual(crop.height, 156, accuracy: 0.001)
    }

    func testTheUnionCoversEveryStrokeRegardlessOfOrder() throws {
        let bounds = [
            CGRect(x: 400, y: 700, width: 20, height: 20),
            CGRect(x: 60, y: 90, width: 10, height: 10),
            CGRect(x: 220, y: 400, width: 30, height: 30)
        ]
        let forwards = try XCTUnwrap(InkCropper.cropRect(strokeBounds: bounds, pageSize: Self.page))
        let backwards = try XCTUnwrap(
            InkCropper.cropRect(strokeBounds: Array(bounds.reversed()), pageSize: Self.page)
        )
        XCTAssertEqual(forwards, backwards)
        for stroke in bounds {
            XCTAssertTrue(forwards.contains(stroke.origin), "\(stroke) fell outside the crop")
        }
    }

    func testPaddingIsFifteenPercentOfTheUnionOnEachSide() throws {
        let union = CGRect(x: 200, y: 300, width: 200, height: 100)
        let crop = try XCTUnwrap(InkCropper.cropRect(strokeBounds: [union], pageSize: Self.page))
        XCTAssertEqual(crop.width, union.width * (1 + 2 * CGFloat(InkImage.paddingFraction)), accuracy: 0.001)
        XCTAssertEqual(crop.height, union.height * (1 + 2 * CGFloat(InkImage.paddingFraction)), accuracy: 0.001)
        XCTAssertEqual(crop.midX, union.midX, accuracy: 0.001)
        XCTAssertEqual(crop.midY, union.midY, accuracy: 0.001)
    }

    func testNullAndInfiniteBoundsAreIgnored() throws {
        let crop = try XCTUnwrap(
            InkCropper.cropRect(
                strokeBounds: [.null, CGRect(x: 200, y: 300, width: 200, height: 100), .infinite],
                pageSize: Self.page
            )
        )
        XCTAssertEqual(crop.width, 260, accuracy: 0.001)
    }

    func testNoStrokesMeansNoCrop() {
        XCTAssertNil(InkCropper.cropRect(strokeBounds: [], pageSize: Self.page))
        XCTAssertNil(InkCropper.cropRect(strokeBounds: [.null], pageSize: Self.page))
    }

    func testAPageWithNoSizeMeansNoCrop() {
        let bounds = [CGRect(x: 10, y: 10, width: 10, height: 10)]
        XCTAssertNil(InkCropper.cropRect(strokeBounds: bounds, pageSize: .zero))
        XCTAssertNil(InkCropper.cropRect(strokeBounds: bounds, pageSize: CGSize(width: -1, height: 10)))
    }

    // MARK: - Degenerate strokes

    /// A single tap is a zero-size bounds at a real position. 15% of nothing is
    /// nothing, so a floor keeps it visible — and keeps it where it was.
    func testASingleDotStillProducesAVisibleCrop() throws {
        let crop = try XCTUnwrap(
            InkCropper.cropRect(strokeBounds: [CGRect(x: 300, y: 400, width: 0, height: 0)], pageSize: Self.page)
        )
        XCTAssertGreaterThan(crop.width, 1)
        XCTAssertGreaterThan(crop.height, 1)
        XCTAssertEqual(crop.midX, 300, accuracy: 0.001)
        XCTAssertEqual(crop.midY, 400, accuracy: 0.001)
    }

    /// A single vertical line has zero width and must not become a one-pixel
    /// image of nothing.
    func testAVerticalStrokeGetsAWidth() throws {
        let crop = try XCTUnwrap(
            InkCropper.cropRect(strokeBounds: [CGRect(x: 300, y: 100, width: 0, height: 400)], pageSize: Self.page)
        )
        XCTAssertGreaterThanOrEqual(crop.width, Self.page.width * InkCropper.minimumCropFraction - 0.001)
        XCTAssertEqual(crop.height, 400 * 1.3, accuracy: 0.001)
    }

    // MARK: - Clamping

    /// Ink drawn off the margin is legal — `NormalisedRect` says so — but the
    /// crop cannot render page content that is not there.
    func testACropIsClampedToThePage() throws {
        let crop = try XCTUnwrap(
            InkCropper.cropRect(strokeBounds: [CGRect(x: -30, y: -20, width: 60, height: 40)], pageSize: Self.page)
        )
        XCTAssertEqual(crop.minX, 0, accuracy: 0.001)
        XCTAssertEqual(crop.minY, 0, accuracy: 0.001)
        XCTAssertLessThanOrEqual(crop.maxX, Self.page.width)
        XCTAssertLessThanOrEqual(crop.maxY, Self.page.height)
    }

    func testAFullPageOfInkCropsToTheWholePage() throws {
        let crop = try XCTUnwrap(
            InkCropper.cropRect(
                strokeBounds: [CGRect(origin: .zero, size: Self.page)],
                pageSize: Self.page
            )
        )
        XCTAssertEqual(crop, CGRect(origin: .zero, size: Self.page))
    }

    func testInkEntirelyOffThePageProducesNoCrop() {
        XCTAssertNil(
            InkCropper.cropRect(
                strokeBounds: [CGRect(x: 5_000, y: 5_000, width: 10, height: 10)],
                pageSize: Self.page
            )
        )
    }

    // MARK: - The 2048px cap

    func testTheLongEdgeIsCappedAtTwoThousandAndFortyEight() {
        let fullPage = CGRect(origin: .zero, size: Self.page)
        let pixels = InkCropper.pixelSize(for: fullPage, scale: 4)

        XCTAssertLessThanOrEqual(max(pixels.width, pixels.height), CGFloat(InkImage.maxLongEdgePixels))
        XCTAssertGreaterThan(max(pixels.width, pixels.height), CGFloat(InkImage.maxLongEdgePixels) - 2)
        // …and the aspect ratio survives the cap.
        XCTAssertEqual(pixels.width / pixels.height, fullPage.width / fullPage.height, accuracy: 0.01)
    }

    func testTheCapAppliesToTheLongEdgeWhicheverItIs() {
        let landscape = CGRect(x: 0, y: 0, width: 2_000, height: 300)
        let pixels = InkCropper.pixelSize(for: landscape, scale: 4)
        XCTAssertLessThanOrEqual(pixels.width, CGFloat(InkImage.maxLongEdgePixels))
        XCTAssertGreaterThan(pixels.width, CGFloat(InkImage.maxLongEdgePixels) - 2)
        XCTAssertLessThan(pixels.height, pixels.width)
    }

    /// A cap is a ceiling, not a size. A margin note is a small image.
    func testASmallCropIsNotBlownUpToReachTheCap() {
        let crop = CGRect(x: 0, y: 0, width: 120, height: 60)
        let pixels = InkCropper.pixelSize(for: crop, scale: 2)
        XCTAssertEqual(pixels.width, 240)
        XCTAssertEqual(pixels.height, 120)
    }

    func testTheRenderedScaleNeverExceedsTheRequestedScale() {
        let small = CGRect(x: 0, y: 0, width: 10, height: 10)
        XCTAssertEqual(InkCropper.renderedScale(for: small, scale: 2), 2, accuracy: 0.000_1)

        let huge = CGRect(x: 0, y: 0, width: 8_000, height: 100)
        XCTAssertLessThan(InkCropper.renderedScale(for: huge, scale: 2), 1)
    }

    func testAnEmptyCropHasNoPixels() {
        XCTAssertEqual(InkCropper.pixelSize(for: .zero, scale: 2), .zero)
        XCTAssertEqual(InkCropper.renderedScale(for: .zero, scale: 2), 0)
        XCTAssertEqual(
            InkCropper.pixelSize(for: CGRect(x: 0, y: 0, width: 10, height: 10), scale: 0),
            .zero
        )
    }

    /// Whatever the crop, the output is at least one pixel each way: a PNG of
    /// zero width is not a file anyone can open.
    func testEveryNonEmptyCropProducesAtLeastOnePixel() {
        for width in [0.4, 1.0, 40.0, 4_000.0] {
            let pixels = InkCropper.pixelSize(
                for: CGRect(x: 0, y: 0, width: CGFloat(width), height: 1),
                scale: 2
            )
            XCTAssertGreaterThanOrEqual(pixels.width, 1)
            XCTAssertGreaterThanOrEqual(pixels.height, 1)
        }
    }

    // MARK: - Filenames

    /// The path in `review.json` and the path in `review.md` both come from
    /// here, and the schema's pattern is `^ink/page-[0-9]{2,}\.png$`.
    func testFilenamesAreOneBasedAndZeroPadded() {
        XCTAssertEqual(InkImage.fileName(forPageIndex: 0), "ink/page-01.png")
        XCTAssertEqual(InkImage.fileName(forPageIndex: 2), "ink/page-03.png")
        XCTAssertEqual(InkImage.fileName(forPageIndex: 9), "ink/page-10.png")
        XCTAssertEqual(InkImage.fileName(forPageIndex: 99), "ink/page-100.png")
    }

    // MARK: - Support

    /// A4 portrait, the only geometry v1 ships.
    static let page = CGSize(
        width: CGFloat(PageGeometry.annotationFriendly.pageWidth),
        height: CGFloat(PageGeometry.annotationFriendly.pageHeight)
    )
}
