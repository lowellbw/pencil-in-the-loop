//
//  ReviewSqueezeScopeTests.swift
//  AppUITests
//
//  When does a squeeze mean "dictate the closing instruction"?
//
//  A squeeze cannot be simulated and the Pencil Pro cannot be tested in the
//  Simulator, so what is exercised here is the only part that can be wrong on
//  its own: the rule that decides whether a squeeze arriving now was aimed at
//  that field. It is wrong in two opposite directions — too strict and the
//  gesture feels broken, too loose and squeezing for something else starts
//  recording — and neither shows up until somebody is holding the device.
//

import XCTest
import Foundation
@testable import AppUI

final class ReviewSqueezeScopeTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_755_000_000)

    /// The Pencil is in a hand, in a case, or over something else entirely.
    func testASqueezeWithNoHoverIsIgnored() {
        XCTAssertFalse(ReviewSheet.shouldDictate(lastHoverAt: nil, now: now))
    }

    func testASqueezeWhileHoveringDictates() {
        XCTAssertTrue(ReviewSheet.shouldDictate(lastHoverAt: now, now: now))
    }

    /// The point of the grace period: a hand tightening around the Pencil can
    /// lift it out of the 12mm hover range, and refusing then would make the
    /// gesture feel unreliable rather than scoped.
    func testHoverAMomentAgoStillCounts() {
        XCTAssertTrue(
            ReviewSheet.shouldDictate(lastHoverAt: now.addingTimeInterval(-1.0), now: now)
        )
    }

    /// A Pencil put down two seconds ago is aimed at nothing.
    func testStaleHoverDoesNot() {
        XCTAssertFalse(
            ReviewSheet.shouldDictate(lastHoverAt: now.addingTimeInterval(-4), now: now)
        )
    }

    /// Clocks move. A hover stamped in the future would otherwise pass every
    /// check for ever, which is the failure that never gets noticed.
    func testAHoverStampedInTheFutureIsNotTrusted() {
        XCTAssertFalse(
            ReviewSheet.shouldDictate(lastHoverAt: now.addingTimeInterval(60), now: now)
        )
    }
}
