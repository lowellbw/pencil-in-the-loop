//
//  ReviewSheetOrderTests.swift
//  AppUITests
//
//  The review sheet's sort predicate. It looks like a detail and is not: the
//  bundle numbers comments 1…n in exactly this order, and that numbering is what
//  `review.md` shows and what an agent quotes back (docs/05-file-contracts.md).
//  Reordering it silently renumbers every comment in a review.
//

import Foundation
import XCTest
@testable import AppUI
import Core

@MainActor
final class ReviewSheetOrderTests: XCTestCase {

    // MARK: - The three keys, in order of precedence

    func testPageBeatsEverything() {
        let early = AppUITestSamples.comment(1, y: 0.9, page: 0, createdAtOffset: 100)
        let late = AppUITestSamples.comment(2, y: 0.1, page: 1, createdAtOffset: 0)
        XCTAssertTrue(ReviewSheetModel.isBefore(early, late))
        XCTAssertFalse(ReviewSheetModel.isBefore(late, early))
    }

    func testWithinAPageItIsDownThePage() {
        let top = AppUITestSamples.comment(1, y: 0.1, createdAtOffset: 100)
        let bottom = AppUITestSamples.comment(2, y: 0.8, createdAtOffset: 0)
        XCTAssertTrue(ReviewSheetModel.isBefore(top, bottom), "Position wins over when it was said.")
        XCTAssertFalse(ReviewSheetModel.isBefore(bottom, top))
    }

    func testTwoCommentsOnTheSameLineAreOldestFirst() {
        let first = AppUITestSamples.comment(1, y: 0.42, createdAtOffset: 0)
        let second = AppUITestSamples.comment(2, y: 0.42, createdAtOffset: 60)
        XCTAssertTrue(ReviewSheetModel.isBefore(first, second))
        XCTAssertFalse(ReviewSheetModel.isBefore(second, first))
    }

    // MARK: - Behaving like a sort predicate

    func testItIsIrreflexive() {
        let comment = AppUITestSamples.comment(1, y: 0.3)
        XCTAssertFalse(
            ReviewSheetModel.isBefore(comment, comment),
            "A predicate that says a value precedes itself makes `sorted(by:)` undefined."
        )
    }

    func testAShuffledDocumentSortsIntoReadingOrder() {
        let comments = [
            AppUITestSamples.comment(5, y: 0.20, page: 2),
            AppUITestSamples.comment(2, y: 0.55, page: 0, createdAtOffset: 10),
            AppUITestSamples.comment(4, y: 0.80, page: 1),
            AppUITestSamples.comment(1, y: 0.10, page: 0, createdAtOffset: 90),
            AppUITestSamples.comment(3, y: 0.55, page: 0, createdAtOffset: 20)
        ]
        let sorted = comments.sorted(by: ReviewSheetModel.isBefore)
        XCTAssertEqual(
            sorted.map(\.id),
            [1, 2, 3, 4, 5].map(AppUITestSamples.id),
            "Page, then down the page, then oldest first."
        )
    }

    // MARK: - The same order the markers and the capture model use

    func testItAgreesWithTheOrderCommentsAreHeldInWhileReading() {
        // `CommentCaptureModel.inDocumentOrder(_:)` sorts by the same three
        // keys. Two orders that disagree would put marker 3 next to comment 4 in
        // the sheet, which is the kind of thing nobody notices until an agent
        // quotes the wrong one back.
        let comments = [
            AppUITestSamples.comment(3, y: 0.60, page: 1),
            AppUITestSamples.comment(1, y: 0.15, page: 0),
            AppUITestSamples.comment(2, y: 0.75, page: 0)
        ]
        XCTAssertEqual(
            comments.sorted(by: ReviewSheetModel.isBefore).map(\.id),
            CommentCaptureModel.inDocumentOrder(comments).map(\.id)
        )
    }
}
