//
//  BlankPaperRendererTests.swift
//  IngestTests
//
//  Does a sheet of paper come out the right size, the right count, and with
//  the ruling actually on it?
//
//  The last of those is the one worth writing. Asserting that `render` returned
//  some bytes proves nothing — a renderer that drew no lines at all returns a
//  perfectly valid PDF of the right length, and the failure would only show up
//  on a device, as blank paper the user asked to be ruled. So the ruling is
//  checked the way the user checks it: by looking at the page.
//
//  These need a graphics context, so they run on device or in the Simulator
//  rather than under `swift test` on a Mac command line.
//

import XCTest
import Foundation
import PDFKit
import UIKit
import Core
@testable import Ingest

final class BlankPaperRendererTests: XCTestCase {

    private let renderer = BlankPaperRenderer()
    private let geometry = PageGeometry.notebook

    // MARK: - Shape

    func testTheRequestedNumberOfPagesComesBack() throws {
        for count in [1, 4, 30] {
            let data = try renderer.render(pages: count, paper: .lined, geometry: geometry)
            let document = try XCTUnwrap(PDFDocument(data: data))
            XCTAssertEqual(document.pageCount, count)
        }
    }

    func testEveryPageIsTheGeometrysSize() throws {
        let data = try renderer.render(pages: 3, paper: .grid, geometry: geometry)
        let document = try XCTUnwrap(PDFDocument(data: data))

        for index in 0..<document.pageCount {
            let page = try XCTUnwrap(document.page(at: index))
            let bounds = page.bounds(for: .mediaBox)
            XCTAssertEqual(bounds.width, geometry.pageWidth, accuracy: 1)
            XCTAssertEqual(bounds.height, geometry.pageHeight, accuracy: 1)
        }
    }

    /// A note has no text layer, and `PDFImporter` documents that as fine
    /// rather than as an error. Worth pinning, because the day somebody draws
    /// the ruling with text characters this stops being true and search fills
    /// with rubbish.
    func testAPageHasNoTextOnIt() throws {
        let data = try renderer.render(pages: 2, paper: .lined, geometry: geometry)
        let document = try XCTUnwrap(PDFDocument(data: data))
        let page = try XCTUnwrap(document.page(at: 0))

        XCTAssertEqual(page.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "", "")
    }

    // MARK: - The ruling is really there

    /// The test this file exists for. Plain paper must be blank, and lined and
    /// grid must not be — checked by rendering the page and counting the pixels
    /// that are not white.
    func testPlainPaperIsBlankAndRuledPaperIsNot() throws {
        let plain = try inkedPixelCount(of: .plain)
        let lined = try inkedPixelCount(of: .lined)
        let grid = try inkedPixelCount(of: .grid)

        XCTAssertEqual(plain, 0, "plain paper drew \(plain) marks; it should draw none")
        XCTAssertGreaterThan(lined, 0, "lined paper drew nothing — the ruling is missing")
        XCTAssertGreaterThan(grid, lined, "a grid should put more marks on the page than lines alone")
    }

    /// The ruling stays inside the margins, so nothing is clipped by a printer
    /// and the page has a clean edge.
    func testTheRulingStaysInsideTheMargins() throws {
        let image = try firstPageImage(of: .grid)
        let scale = Double(image.width) / geometry.pageWidth

        // A band just inside the page edge, outside the left margin.
        let strip = CGRect(
            x: 0,
            y: 0,
            width: (geometry.marginLeft - 2) * scale,
            height: Double(image.height)
        )
        XCTAssertEqual(
            try inkedPixels(in: image, within: strip), 0,
            "the ruling reached into the left margin"
        )
    }

    // MARK: - Refusals

    func testAskingForNoPagesIsRefused() {
        XCTAssertThrowsError(try renderer.render(pages: 0, paper: .plain, geometry: geometry))
    }

    func testAskingForMorePagesThanAllowedIsRefused() {
        XCTAssertThrowsError(
            try renderer.render(
                pages: BlankPaperRenderer.maximumPages + 1, paper: .plain, geometry: geometry
            )
        )
    }

    func testGeometryWithNoRoomToWriteIsRefused() {
        let airless = PageGeometry(
            pageWidth: 100, pageHeight: 100,
            marginTop: 60, marginLeft: 60, marginBottom: 60, marginRight: 60,
            bodyPointSize: 11, lineSpacingMultiple: 1.35, maxCodeColumnCharacters: 76
        )
        XCTAssertThrowsError(try renderer.render(pages: 1, paper: .lined, geometry: airless))
    }

    // MARK: - Looking at the page

    private func firstPageImage(of paper: PaperStyle) throws -> CGImage {
        let data = try renderer.render(pages: 1, paper: paper, geometry: geometry)
        let document = try XCTUnwrap(PDFDocument(data: data))
        let page = try XCTUnwrap(document.page(at: 0))
        let bounds = page.bounds(for: .mediaBox)

        let renderer = UIGraphicsImageRenderer(size: bounds.size)
        let image = renderer.image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: CGPoint.zero, size: bounds.size))
            context.cgContext.translateBy(x: 0, y: bounds.height)
            context.cgContext.scaleBy(x: 1, y: -1)
            page.draw(with: .mediaBox, to: context.cgContext)
        }
        return try XCTUnwrap(image.cgImage)
    }

    private func inkedPixelCount(of paper: PaperStyle) throws -> Int {
        let image = try firstPageImage(of: paper)
        return try inkedPixels(
            in: image,
            within: CGRect(x: 0, y: 0, width: Double(image.width), height: Double(image.height))
        )
    }

    /// Pixels within `region` that are darker than nearly-white.
    ///
    /// The threshold is generous because the ruling is deliberately light and
    /// antialiasing spreads it further; anything that is not paper counts.
    private func inkedPixels(in image: CGImage, within region: CGRect) throws -> Int {
        let width = image.width
        let height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height)

        let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        )
        let target = try XCTUnwrap(context)
        target.setFillColor(UIColor.white.cgColor)
        target.fill(CGRect(x: 0, y: 0, width: width, height: height))
        target.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        var count = 0
        let minimumX = max(0, Int(region.minX))
        let maximumX = min(width, Int(region.maxX))
        let minimumY = max(0, Int(region.minY))
        let maximumY = min(height, Int(region.maxY))

        for y in minimumY..<max(minimumY, maximumY) {
            for x in minimumX..<max(minimumX, maximumX) where pixels[y * width + x] < 250 {
                count += 1
            }
        }
        return count
    }
}
