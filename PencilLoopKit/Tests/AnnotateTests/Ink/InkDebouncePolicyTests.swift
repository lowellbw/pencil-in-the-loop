import XCTest
import Core
@testable import Annotate

/// The autosave timing rules, which are pure arithmetic and therefore the one
/// part of the ink path that can be tested properly without a Pencil
/// (STYLE.md § 10).
final class InkDebouncePolicyTests: XCTestCase {

    private let origin = Date(timeIntervalSince1970: 1_787_000_000)

    func testStandardPolicyMatchesTheSpec() {
        let policy = InkDebouncePolicy.standard
        XCTAssertEqual(policy.debounceInterval, 0.5, accuracy: 0.0001)
        XCTAssertGreaterThan(policy.maximumDelay, policy.debounceInterval)
        XCTAssertGreaterThan(policy.recognitionDelay, policy.debounceInterval)
    }

    func testASingleChangeIsWrittenFiveHundredMillisecondsLater() {
        let policy = InkDebouncePolicy.standard
        let deadline = policy.deadline(firstChangeAt: origin, lastChangeAt: origin)
        XCTAssertEqual(deadline.timeIntervalSince(origin), 0.5, accuracy: 0.0001)
    }

    func testAFurtherChangeRestartsTheClock() {
        let policy = InkDebouncePolicy.standard
        let second = origin.addingTimeInterval(0.3)
        let deadline = policy.deadline(firstChangeAt: origin, lastChangeAt: second)
        XCTAssertEqual(deadline.timeIntervalSince(origin), 0.8, accuracy: 0.0001)
    }

    func testContinuousDrawingStillGetsWrittenAtTheCap() {
        // The failure mode a plain debounce has: a user who never stops drawing
        // never triggers a save. The cap is what makes autosave-only safe.
        let policy = InkDebouncePolicy.standard
        let stillDrawing = origin.addingTimeInterval(30)
        let deadline = policy.deadline(firstChangeAt: origin, lastChangeAt: stillDrawing)
        XCTAssertEqual(deadline.timeIntervalSince(origin), policy.maximumDelay, accuracy: 0.0001)
    }

    func testDelayIsNeverNegative() {
        let policy = InkDebouncePolicy.standard
        let late = origin.addingTimeInterval(60)
        let delay = policy.delay(from: late, firstChangeAt: origin, lastChangeAt: origin)
        XCTAssertEqual(delay, 0, accuracy: 0.0001)
        XCTAssertTrue(policy.shouldCommit(now: late, firstChangeAt: origin, lastChangeAt: origin))
    }

    func testShouldNotCommitBeforeTheDeadline() {
        let policy = InkDebouncePolicy.standard
        let soon = origin.addingTimeInterval(0.4)
        XCTAssertFalse(policy.shouldCommit(now: soon, firstChangeAt: origin, lastChangeAt: origin))
    }

    func testACapBelowTheIntervalDoesNotDisableTheDebounce() {
        let policy = InkDebouncePolicy(debounceInterval: 0.5, maximumDelay: 0.1)
        XCTAssertEqual(policy.effectiveMaximumDelay, 0.5, accuracy: 0.0001)
        let deadline = policy.deadline(firstChangeAt: origin, lastChangeAt: origin)
        XCTAssertEqual(deadline.timeIntervalSince(origin), 0.5, accuracy: 0.0001)
    }

    func testNegativeIntervalsAreClampedRatherThanTrusted() {
        let policy = InkDebouncePolicy(debounceInterval: -5, maximumDelay: -5, recognitionDelay: -5)
        XCTAssertEqual(policy.debounceInterval, 0, accuracy: 0.0001)
        XCTAssertTrue(policy.shouldCommit(now: origin, firstChangeAt: origin, lastChangeAt: origin))
    }

    func testNanosecondConversionSaturatesInsteadOfTrapping() {
        XCTAssertEqual(InkDebouncePolicy.nanoseconds(0.5), 500_000_000)
        XCTAssertEqual(InkDebouncePolicy.nanoseconds(-1), 0)
        XCTAssertEqual(InkDebouncePolicy.nanoseconds(.nan), 0)
        XCTAssertEqual(InkDebouncePolicy.nanoseconds(.infinity), 9_000_000_000_000_000_000)
    }
}
