//
//  AnchorLadderTests.swift
//  ExportTests
//
//  The four-step ladder (docs/03-architecture.md § 3). Each rung is tested for
//  the case it exists to handle and for the case it must decline, because a
//  ladder that answers on the wrong rung puts a comment in the wrong place while
//  reporting more confidence than it has.
//

import XCTest
import Foundation
import Core

final class AnchorLadderTests: XCTestCase {

    // MARK: - Step 1 · prefix + quoted + suffix

    func testExactContextualMatchIsTheFirstRung() {
        let text = Self.document
        let anchor = Self.anchor(
            quoted: "The migration runs in a single deploy, with no dual-write window.",
            prefix: "refresh token stored in the keychain. ",
            suffix: " Rollout is gated behind auth_v2"
        )

        let resolution = AnchorResolver.resolve(anchor: anchor, in: text)

        guard case let .exact(range) = resolution else {
            return XCTFail("Expected .exact, got \(resolution.label)")
        }
        XCTAssertEqual(range.substring(of: text), anchor.quoted)
        XCTAssertEqual(range.start, Self.offset(of: anchor.quoted, in: text))
    }

    /// The only rung that can tell two identical sentences apart, which is the
    /// whole reason 32 characters of context are stored.
    func testContextDisambiguatesARepeatedQuote() {
        let text = "Alpha. The plan is wrong. Beta. The plan is wrong. Gamma."
        let quoted = "The plan is wrong."
        let anchor = Self.anchor(quoted: quoted, prefix: "Beta. ", suffix: " Gamma.")

        let resolution = AnchorResolver.resolve(anchor: anchor, in: text)
        let second = Self.offset(of: quoted, in: text, occurrence: 2)

        XCTAssertEqual(resolution, .exact(range: SourceRange(start: second, end: second + quoted.utf8.count)))
    }

    func testContextualMatchReturnsTheQuoteWithoutItsContext() {
        let text = "one two three four five"
        let range = AnchorResolver.exactContextualRange(
            prefix: "one ",
            quoted: "two three",
            suffix: " four",
            in: text
        )
        XCTAssertEqual(range, SourceRange(start: 4, end: 13))
        XCTAssertEqual(range?.substring(of: text), "two three")
    }

    func testContextualMatchDeclinesWhenTheContextMoved() {
        let text = "one two three four five"
        XCTAssertNil(
            AnchorResolver.exactContextualRange(
                prefix: "nine ",
                quoted: "two three",
                suffix: " four",
                in: text
            )
        )
    }

    // MARK: - Step 2 · the quote alone

    func testQuoteOnlyWhenTheContextMovedButTheSentenceDidNot() {
        let text = Self.document
        let quoted = "The migration runs in a single deploy, with no dual-write window."
        let anchor = Self.anchor(
            quoted: quoted,
            prefix: "some context that is no longer there. ",
            suffix: " nor is this."
        )

        let resolution = AnchorResolver.resolve(anchor: anchor, in: text)

        guard case let .quoteOnly(range) = resolution else {
            return XCTFail("Expected .quoteOnly, got \(resolution.label)")
        }
        XCTAssertEqual(range.substring(of: text), quoted)
    }

    /// With no context there is nothing to disambiguate with, so the ladder
    /// declines to claim the stronger `.exact` label.
    func testAnAnchorWithNoContextResolvesAsQuoteOnly() {
        let text = Self.document
        let anchor = Self.anchor(quoted: "Phase 2 does the shadow read.", prefix: "", suffix: "")

        XCTAssertEqual(AnchorResolver.resolve(anchor: anchor, in: text).label, "quote")
    }

    func testTheOccurrenceNearestTheStoredOffsetWins() {
        let text = "Alpha. Repeat me. Beta. Repeat me. Gamma."
        let quoted = "Repeat me."
        let first = Self.offset(of: quoted, in: text, occurrence: 1)
        let second = Self.offset(of: quoted, in: text, occurrence: 2)

        XCTAssertEqual(
            AnchorResolver.exactQuoteRange(quoted: quoted, in: text, nearOffset: second + 2)?.start,
            second
        )
        XCTAssertEqual(
            AnchorResolver.exactQuoteRange(quoted: quoted, in: text, nearOffset: first)?.start,
            first
        )
    }

    func testWithoutAStoredOffsetTheFirstOccurrenceWins() {
        let text = "Alpha. Repeat me. Beta. Repeat me. Gamma."
        XCTAssertEqual(
            AnchorResolver.exactQuoteRange(quoted: "Repeat me.", in: text)?.start,
            Self.offset(of: "Repeat me.", in: text, occurrence: 1)
        )
    }

    // MARK: - Step 4 · the rect fallback

    func testNothingMatchingFallsBackToPageAndRect() {
        let rect = NormalisedRect(x: 0.1, y: 0.2, width: 0.5, height: 0.05)
        let anchor = Anchor(
            quoted: "a sentence that was deleted in the rewrite entirely",
            prefix: "",
            suffix: "",
            pageIndex: 3,
            normalisedRect: rect
        )

        let resolution = AnchorResolver.resolve(anchor: anchor, in: Self.document)

        XCTAssertEqual(resolution, .rectFallback(pageIndex: 3, rect: rect))
        XCTAssertFalse(resolution.isTextMatch)
        XCTAssertEqual(resolution.label, "approximate")
    }

    func testAnEmptyQuoteGoesStraightToTheRect() {
        let anchor = Self.anchor(quoted: "", prefix: "x", suffix: "y")
        XCTAssertFalse(AnchorResolver.resolve(anchor: anchor, in: Self.document).isTextMatch)
    }

    func testAnEmptyDocumentGoesStraightToTheRect() {
        let anchor = Self.anchor(quoted: "anything at all", prefix: "", suffix: "")
        XCTAssertFalse(AnchorResolver.resolve(anchor: anchor, in: "").isTextMatch)
    }

    // MARK: - The ladder's order

    /// Step 1 must be tried before step 2, or a repeated quote resolves to
    /// whichever copy happens to come first in the file.
    func testStepOneIsPreferredToStepTwo() {
        let text = "Alpha. Repeat me. Beta. Repeat me. Gamma."
        let anchor = Self.anchor(quoted: "Repeat me.", prefix: "Beta. ", suffix: " Gamma.")

        let resolution = AnchorResolver.resolve(anchor: anchor, in: text)

        XCTAssertEqual(resolution.label, "exact")
        XCTAssertEqual(resolution.range?.start, Self.offset(of: "Repeat me.", in: text, occurrence: 2))
    }

    /// Step 2 must be tried before step 3, or an exact hit is reported as fuzzy
    /// and the reader is told to trust it less than they should.
    func testStepTwoIsPreferredToStepThree() {
        let text = Self.document
        let anchor = Self.anchor(quoted: "Phase 2 does the shadow read.", prefix: "no", suffix: "no")

        XCTAssertEqual(AnchorResolver.resolve(anchor: anchor, in: text).label, "quote")
    }

    /// A line number is never the answer, at any rung. Every resolution is a
    /// byte range or a rect (CLAUDE.md non-negotiable 5).
    func testEveryResolutionIsARangeOrARect() {
        let quotes = [
            "The migration runs in a single deploy, with no dual-write window.",
            "The migration runs in one single deploy, with no dual-write window.",
            "nothing like this appears in the document at all"
        ]
        for quoted in quotes {
            let resolution = AnchorResolver.resolve(anchor: Self.anchor(quoted: quoted), in: Self.document)
            switch resolution {
            case let .exact(range), let .quoteOnly(range):
                XCTAssertNotNil(range.substring(of: Self.document))
            case let .fuzzy(range, similarity):
                XCTAssertNotNil(range.substring(of: Self.document))
                XCTAssertGreaterThan(similarity, 1 - AnchorResolver.fuzzyTolerance - 0.000_1)
            case let .rectFallback(pageIndex, _):
                XCTAssertEqual(pageIndex, 0)
            }
        }
    }

    // MARK: - Support

    static let document = """
        # Auth refactor plan

        Phase 1 introduces the refresh token stored in the keychain. \
        The migration runs in a single deploy, with no dual-write window. \
        Rollout is gated behind auth_v2 for the first week.

        Phase 2 does the shadow read.
        """

    static func anchor(quoted: String, prefix: String = "", suffix: String = "") -> Anchor {
        Anchor(
            quoted: quoted,
            prefix: prefix,
            suffix: suffix,
            pageIndex: 0,
            normalisedRect: NormalisedRect(x: 0.1, y: 0.2, width: 0.5, height: 0.05),
            sourceRange: nil
        )
    }

    /// The UTF-8 offset of the nth occurrence of `needle`, computed rather than
    /// written down, so a change to the sample text cannot make an assertion
    /// quietly meaningless.
    static func offset(of needle: String, in text: String, occurrence: Int = 1) -> Int {
        var searchStart = text.startIndex
        var found = 0
        while let range = text.range(of: needle, options: [.literal], range: searchStart..<text.endIndex) {
            found += 1
            if found == occurrence {
                return text.utf8.distance(from: text.utf8.startIndex, to: range.lowerBound)
            }
            searchStart = text.index(after: range.lowerBound)
        }
        return -1
    }
}
