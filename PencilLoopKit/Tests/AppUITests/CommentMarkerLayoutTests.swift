//
//  CommentMarkerLayoutTests.swift
//  AppUITests
//
//  Where the dots go. Pure arithmetic, and the one part of the marker layer
//  with a right answer.
//

import CoreGraphics
import XCTest
@testable import AppUI
import Core

@MainActor
final class CommentMarkerLayoutTests: XCTestCase {

    private let rect = AppUITestSamples.pageRect

    // MARK: - Nothing to draw

    func testAPageWithNoAreaPlacesNothing() {
        let placements = CommentMarkerLayout.placements(
            for: [AppUITestSamples.comment(1, y: 0.2)],
            pageIndex: 0,
            pageRect: CGRect(x: 10, y: 10, width: 0, height: 0)
        )
        XCTAssertTrue(placements.isEmpty, "A page mid-layout is not an error; it just has no markers yet.")
    }

    func testCommentsOnOtherPagesAreIgnoredRatherThanRejected() {
        let placements = CommentMarkerLayout.placements(
            for: [
                AppUITestSamples.comment(1, y: 0.2, page: 1),
                AppUITestSamples.comment(2, y: 0.4, page: 2)
            ],
            pageIndex: 0,
            pageRect: rect
        )
        XCTAssertTrue(placements.isEmpty, "The caller may pass the whole document's list.")
    }

    // MARK: - Placement

    func testAMarkerSitsInTheOuterMarginAtItsAnchorsHeight() throws {
        let placements = CommentMarkerLayout.placements(
            for: [AppUITestSamples.comment(1, y: 0.5)],
            pageIndex: 0,
            pageRect: rect
        )
        XCTAssertEqual(placements.count, 1)
        let placement = try XCTUnwrap(placements.first)

        // y: 0.5 plus half of a 0.02-high rect is 0.51 of the way down.
        XCTAssertEqual(placement.centre.y, rect.minY + 0.51 * rect.height, accuracy: 0.5)

        // x is inside the page, in from the trailing edge, and nowhere near the
        // text column — the right margin is where handwriting goes.
        XCTAssertLessThan(placement.centre.x, rect.maxX)
        XCTAssertGreaterThan(
            placement.centre.x,
            rect.maxX - CommentMarkerLayout.Metrics.standard.maximumTrailingInset - 1
        )
    }

    func testTheTrailingInsetIsClampedOnANarrowPage() {
        let narrow = CGRect(x: 0, y: 0, width: 40, height: 400)
        let x = CommentMarkerLayout.markerX(in: narrow)
        XCTAssertEqual(
            x,
            narrow.maxX - CommentMarkerLayout.Metrics.standard.minimumTrailingInset,
            "A proportional inset on a tiny page would put the marker off the edge."
        )
    }

    func testMarkersComeBackTopToBottomWhateverOrderTheyWentInAs() {
        let placements = CommentMarkerLayout.placements(
            for: [
                AppUITestSamples.comment(3, y: 0.8),
                AppUITestSamples.comment(1, y: 0.1),
                AppUITestSamples.comment(2, y: 0.45)
            ],
            pageIndex: 0,
            pageRect: rect
        )
        XCTAssertEqual(placements.count, 3)
        XCTAssertEqual(placements.map(\.centre.y), placements.map(\.centre.y).sorted())
        XCTAssertEqual(placements.first?.commentIds, [AppUITestSamples.id(1)])
    }

    // MARK: - Clustering

    func testTwoCommentsOnTheSameLineBecomeOneMarkerWithACount() {
        // 0.60 and 0.612 of 594pt is about 7pt apart — inside `clusterSpacing`.
        let placements = CommentMarkerLayout.placements(
            for: [
                AppUITestSamples.comment(1, y: 0.60),
                AppUITestSamples.comment(2, y: 0.612)
            ],
            pageIndex: 0,
            pageRect: rect
        )
        XCTAssertEqual(placements.count, 1, "A pile of overlapping dots reads as one dot, badly.")
        XCTAssertEqual(placements.first?.count, 2)
        XCTAssertTrue(placements.first?.showsCount ?? false)
        XCTAssertEqual(placements.first?.commentIds, [AppUITestSamples.id(1), AppUITestSamples.id(2)])
        XCTAssertEqual(placements.first?.id, AppUITestSamples.id(1), "The id is the first comment's, so it is stable across layout passes.")
    }

    func testASingleCommentDrawsABareDot() {
        let placements = CommentMarkerLayout.placements(
            for: [AppUITestSamples.comment(1, y: 0.3)],
            pageIndex: 0,
            pageRect: rect
        )
        XCTAssertEqual(placements.first?.count, 1)
        XCTAssertFalse(placements.first?.showsCount ?? true, "One comment is a dot, not a badge reading 1.")
    }

    func testTwoNearbyButDistinctLinesArePushedApartRatherThanMerged() {
        // Far enough apart to be two lines, close enough to collide as dots.
        let metrics = CommentMarkerLayout.Metrics(clusterSpacing: 4, minimumSeparation: 20)
        let placements = CommentMarkerLayout.placements(
            for: [
                AppUITestSamples.comment(1, y: 0.50),
                AppUITestSamples.comment(2, y: 0.52)
            ],
            pageIndex: 0,
            pageRect: rect,
            metrics: metrics
        )
        XCTAssertEqual(placements.count, 2, "Different lines should read as different lines.")
        let gap = placements[1].centre.y - placements[0].centre.y
        XCTAssertGreaterThanOrEqual(gap, metrics.minimumSeparation - 0.001)
    }

    // MARK: - Staying on the page

    func testAMarkerAtTheVeryTopOrBottomStaysOnThePage() {
        let placements = CommentMarkerLayout.placements(
            for: [
                AppUITestSamples.comment(1, y: 0.0),
                AppUITestSamples.comment(2, y: 0.99)
            ],
            pageIndex: 0,
            pageRect: rect
        )
        let half = CommentMarkerLayout.Metrics.standard.diameter / 2
        for placement in placements {
            XCTAssertGreaterThanOrEqual(placement.centre.y, rect.minY + half - 0.001)
            XCTAssertLessThanOrEqual(placement.centre.y, rect.maxY - half + 0.001)
        }
    }

    func testTheAnchorsCentreIsMeasuredWithNoVerticalFlip() {
        // NormalisedRect is top-left origin, y down — the same as view space —
        // so an anchor a tenth of the way down the document is a tenth of the
        // way down the page rect. A flip here would put every marker in the
        // wrong half of the page and look plausible.
        let anchor = Anchor(
            quoted: "x",
            pageIndex: 0,
            normalisedRect: NormalisedRect(x: 0, y: 0.1, width: 1, height: 0)
        )
        XCTAssertEqual(
            CommentMarkerLayout.centreY(of: anchor, in: rect),
            rect.minY + 0.1 * rect.height,
            accuracy: 0.001
        )
    }
}
