//
//  ReviewSheetFlushTests.swift
//  AppUITests
//
//  Which comments a flush writes.
//
//  Typing in the review sheet is debounced, and Send has to get those edits into
//  the store before the bundle is built from it. The flush used to do that by
//  writing *every* comment, which cost n store round trips inside the 2s bundle
//  budget and, worse, overwrote a comment edited somewhere else — a marker
//  popover in the reader — between `load(environment:)` and Send with the
//  sheet's older copy. A debounce task exists for exactly the comments this
//  sheet has typed into, and those are the ones to write.
//

import Foundation
import SwiftUI
import XCTest
@testable import AppUI
import Core

@MainActor
final class ReviewSheetFlushTests: XCTestCase {

    func testOnlyTheEditedCommentIsWritten() async {
        let comments = ReviewSheetFlushTests.comments
        let store = AppUITestStore(comments: comments)
        let environment = AppUITestEnvironment(store: store)
        let model = ReviewSheetModel(document: AppUITestSamples.detail(comments: comments))

        let edited = model.textBinding(for: comments[1].id, environment: environment)
        edited.wrappedValue = "Rewritten in the sheet."

        await model.flushPendingEdits(environment: environment)

        let written = await store.updatedCommentIds
        XCTAssertEqual(
            written,
            [comments[1].id],
            "Only the comment that was typed into has an edit to write."
        )
        let text = await store.updatedText(forCommentId: comments[1].id)
        XCTAssertEqual(text, "Rewritten in the sheet.")
    }

    /// The lost update, stated as a test: a comment this sheet never touched
    /// must not be written back over whatever else has edited it.
    func testAnUntouchedCommentIsNotWrittenBack() async {
        let comments = ReviewSheetFlushTests.comments
        let store = AppUITestStore(comments: comments)
        let environment = AppUITestEnvironment(store: store)
        let model = ReviewSheetModel(document: AppUITestSamples.detail(comments: comments))

        let edited = model.textBinding(for: comments[0].id, environment: environment)
        edited.wrappedValue = "Rewritten in the sheet."

        await model.flushPendingEdits(environment: environment)

        let written = await store.updatedCommentIds
        XCTAssertFalse(
            written.contains(comments[2].id),
            "The sheet's copy of a comment it never edited is not an edit."
        )
    }

    func testAFlushWithNothingPendingWritesNothing() async {
        let comments = ReviewSheetFlushTests.comments
        let store = AppUITestStore(comments: comments)
        let environment = AppUITestEnvironment(store: store)
        let model = ReviewSheetModel(document: AppUITestSamples.detail(comments: comments))

        await model.flushPendingEdits(environment: environment)

        let written = await store.updatedCommentIds
        XCTAssertTrue(written.isEmpty, "Send used to write all n comments whether or not any had changed.")
    }

    private static var comments: [CommentSnapshot] {
        [
            AppUITestSamples.comment(1, y: 0.1),
            AppUITestSamples.comment(2, y: 0.4),
            AppUITestSamples.comment(3, y: 0.8)
        ]
    }
}
