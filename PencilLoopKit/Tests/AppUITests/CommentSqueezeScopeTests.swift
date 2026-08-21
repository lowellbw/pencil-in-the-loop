//
//  CommentSqueezeScopeTests.swift
//  AppUITests
//
//  When does a squeeze belong to the reader?
//
//  The sibling of `ReviewSqueezeScopeTests`, and for the same reason: a squeeze
//  cannot be simulated and a Pencil Pro does not exist in the Simulator, so what
//  is exercised here is the only part that can be wrong on its own — the rule
//  deciding whether a squeeze arriving now was aimed at this screen.
//
//  It is wrong in two opposite directions, and this app has now shipped both.
//  Too loose, and a squeeze meant for the review sheet opened a second comment
//  popover behind it, recording into the same engine and throwing away the
//  transcript in front. Too strict — refusing every squeeze while anything was
//  presented over the reader — and the squeeze meant to *stop* a recording was
//  refused too, because the reader's own popover is a presentation as well;
//  that left the microphone open with no gesture able to close it, which is the
//  worse of the two by some distance.
//

import XCTest
@testable import AppUI

final class CommentSqueezeScopeTests: XCTestCase {

    /// Nothing open, nothing on top: the ordinary first squeeze, which opens a
    /// popover and starts talking.
    func testAnUncoveredSqueezeIsHandled() {
        XCTAssertTrue(
            CommentGestureController.shouldHandleSqueeze(isCovered: false, ownsPopover: false)
        )
    }

    /// The reason the scoping exists at all: with the review sheet on top and
    /// no popover of our own, a squeeze is aimed at the sheet. Starting a
    /// recording behind it is the bug this rule was written for.
    func testASqueezeUnderAnotherScreenIsRefused() {
        XCTAssertFalse(
            CommentGestureController.shouldHandleSqueeze(isCovered: true, ownsPopover: false)
        )
    }

    /// **The regression this rule was rewritten for.** The reader's own comment
    /// popover makes `isCovered` true, so a rule that only asked that question
    /// refused the second squeeze — the one that stops the recording.
    func testASqueezeReachingOurOwnPopoverIsAlwaysHandled() {
        XCTAssertTrue(
            CommentGestureController.shouldHandleSqueeze(isCovered: true, ownsPopover: true),
            "stopping is not scoped: a squeeze must always reach a popover the reader owns"
        )
    }

    /// The same answer without the presentation, so that the rule cannot come
    /// to depend on `isCovered` for a popover it owns.
    func testOwningAPopoverIsEnoughOnItsOwn() {
        XCTAssertTrue(
            CommentGestureController.shouldHandleSqueeze(isCovered: false, ownsPopover: true)
        )
    }
}
