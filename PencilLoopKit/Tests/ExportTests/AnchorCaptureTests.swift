//
//  AnchorCaptureTests.swift
//  ExportTests
//
//  Capture, from docs/02-spec.md § S3: "the nearest text selection to the touch
//  point, expanded to a sensible unit — a sentence if one is identifiable,
//  otherwise the line. Store the selected string plus 32 characters of context
//  either side, the page index, and a normalised rect."
//
//  The round trip is the test that matters: an anchor captured today must
//  resolve on rung 1 against the document it was captured from. If it does not,
//  every other rung is being asked to cover for a capture bug.
//

import XCTest
import Foundation
import Core

final class AnchorCaptureTests: XCTestCase {

    // MARK: - Context

    func testCapturesThirtyTwoCharactersEitherSide() {
        let text = Self.text
        let selection = Self.range(of: "Delta epsilon zeta.", in: text)

        let anchor = AnchorResolver.captureAnchor(
            in: text,
            selection: selection,
            pageIndex: 2,
            normalisedRect: Self.rect,
            sourceRange: selection
        )

        XCTAssertEqual(anchor.quoted, "Delta epsilon zeta.")
        XCTAssertEqual(anchor.prefix.count, AnchorResolver.contextLength)
        XCTAssertEqual(anchor.suffix.count, AnchorResolver.contextLength)
        XCTAssertTrue(text.contains(anchor.contextualQuote))
        XCTAssertEqual(anchor.pageIndex, 2)
        XCTAssertEqual(anchor.normalisedRect, Self.rect)
        XCTAssertEqual(anchor.sourceRange, selection)
    }

    func testContextIsClampedAtTheStartOfTheDocument() {
        let text = "Alpha beta. Gamma delta epsilon zeta eta theta iota kappa lambda mu nu."
        let anchor = AnchorResolver.captureAnchor(
            in: text,
            selection: Self.range(of: "Alpha beta.", in: text),
            pageIndex: 0,
            normalisedRect: Self.rect,
            sourceRange: nil
        )

        XCTAssertEqual(anchor.quoted, "Alpha beta.")
        XCTAssertEqual(anchor.prefix, "")
        XCTAssertFalse(anchor.suffix.isEmpty)
        XCTAssertNil(anchor.sourceRange)
    }

    func testContextIsClampedAtTheEndOfTheDocument() {
        let text = "Alpha beta gamma delta epsilon zeta eta theta iota. Final."
        let anchor = AnchorResolver.captureAnchor(
            in: text,
            selection: Self.range(of: "Final.", in: text),
            pageIndex: 0,
            normalisedRect: Self.rect,
            sourceRange: nil
        )

        XCTAssertEqual(anchor.quoted, "Final.")
        XCTAssertEqual(anchor.suffix, "")
        XCTAssertFalse(anchor.prefix.isEmpty)
    }

    /// Not trimmed, not re-wrapped, not whitespace-collapsed. Normalisation
    /// belongs to step 3 and nowhere else, because a quote trimmed at capture
    /// will not match exactly at step 1.
    func testQuotedTextIsStoredVerbatim() {
        let text = "before\nawait refresh(session)   // no backoff\nafter"
        let anchor = AnchorResolver.captureAnchor(
            in: text,
            selection: Self.range(of: "refresh(session)", in: text),
            pageIndex: 0,
            normalisedRect: Self.rect,
            sourceRange: nil
        )
        XCTAssertEqual(anchor.quoted, "await refresh(session)   // no backoff")
    }

    // MARK: - Expansion to a unit

    func testACaretExpandsToItsSentence() {
        let text = Self.text
        let caretAt = Self.range(of: "epsilon", in: text).start
        let caret = SourceRange(start: caretAt, end: caretAt)

        let unit = AnchorResolver.expandToUnit(caret, in: text)

        XCTAssertEqual(unit.substring(of: text), "Delta epsilon zeta.")
    }

    func testExpansionFallsBackToTheLineWhenThereIsNoSentence() {
        let text = Self.text
        let caretAt = Self.range(of: "terminator", in: text).start
        let caret = SourceRange(start: caretAt, end: caretAt)

        XCTAssertEqual(
            AnchorResolver.expandToUnit(caret, in: text).substring(of: text),
            "Second line with no terminator"
        )
    }

    /// A fragment after the last full stop on a line is a sentence still being
    /// written, so it ends where the line does — not at the start of the line,
    /// which would swallow the finished sentences before it.
    func testATrailingFragmentExpandsToTheEndOfItsLine() {
        let text = "One. Two three"
        let caretAt = Self.range(of: "three", in: text).start
        let caret = SourceRange(start: caretAt, end: caretAt)

        XCTAssertEqual(AnchorResolver.expandToUnit(caret, in: text).substring(of: text), "Two three")
    }

    /// Expanding an already-whole unit changes nothing, which is what makes it
    /// safe for `captureAnchor(…)` to expand whatever it is handed.
    func testExpansionIsIdempotent() {
        let text = Self.text
        let once = AnchorResolver.expandToUnit(Self.range(of: "epsilon", in: text), in: text)
        let twice = AnchorResolver.expandToUnit(once, in: text)
        XCTAssertEqual(once, twice)
        XCTAssertEqual(once.substring(of: text), "Delta epsilon zeta.")
    }

    /// A full stop with no space after it is a decimal point, a version number
    /// or a file extension — not the end of a sentence.
    func testAFullStopInsideAVersionNumberDoesNotEndASentence() {
        let text = "We shipped 1.2.3 to the fleet. Then we stopped."
        let caretAt = Self.range(of: "fleet", in: text).start
        let caret = SourceRange(start: caretAt, end: caretAt)

        XCTAssertEqual(
            AnchorResolver.expandToUnit(caret, in: text).substring(of: text),
            "We shipped 1.2.3 to the fleet."
        )
    }

    func testAnInvalidSelectionIsReturnedUnchanged() {
        let inverted = SourceRange(start: 40, end: 3)
        XCTAssertEqual(AnchorResolver.expandToUnit(inverted, in: Self.text), inverted)

        let beyondTheEnd = SourceRange(start: 9_000, end: 9_001)
        XCTAssertEqual(AnchorResolver.expandToUnit(beyondTheEnd, in: Self.text), beyondTheEnd)
    }

    func testAnEmptyDocumentLeavesTheSelectionAlone() {
        let selection = SourceRange(start: 0, end: 0)
        XCTAssertEqual(AnchorResolver.expandToUnit(selection, in: ""), selection)
    }

    // MARK: - The round trip

    /// The property the whole design rests on: capture, then resolve, lands on
    /// rung 1 with the same bytes.
    func testACapturedAnchorResolvesExactlyAgainstItsOwnDocument() {
        let text = Self.text
        let caretAt = Self.range(of: "epsilon", in: text).start
        let anchor = AnchorResolver.captureAnchor(
            in: text,
            selection: SourceRange(start: caretAt, end: caretAt),
            pageIndex: 1,
            normalisedRect: Self.rect,
            sourceRange: nil
        )

        let resolution = AnchorResolver.resolve(anchor: anchor, in: text)

        XCTAssertEqual(resolution.label, "exact")
        XCTAssertEqual(resolution.range?.substring(of: text), anchor.quoted)
    }

    /// And on a document that has since been reworded, it lands on rung 3
    /// rather than on a rect.
    func testACapturedAnchorSurvivesARewording() {
        let text = Self.text
        let anchor = AnchorResolver.captureAnchor(
            in: text,
            selection: Self.range(of: "Delta epsilon zeta.", in: text),
            pageIndex: 1,
            normalisedRect: Self.rect,
            sourceRange: nil
        )
        // One substitution in a nineteen-character quote: inside 15%, where
        // "Delta epsilon eta zeta." — four edits — would not be.
        let regenerated = text.replacingOccurrences(
            of: "Delta epsilon zeta.",
            with: "Delta epsilon beta."
        )

        XCTAssertEqual(AnchorResolver.resolve(anchor: anchor, in: regenerated).label, "fuzzy")
    }

    // MARK: - Support

    /// Long enough either side of the middle sentence that a 32-character
    /// context is not silently clamped, which would make the clamping tests
    /// below pass for the wrong reason.
    static let text = """
        Prologue one two three four five six seven. Delta epsilon zeta. \
        Eta theta iota kappa lambda mu nu xi omicron.
        Second line with no terminator
        """

    static let rect = NormalisedRect(x: 0.12, y: 0.34, width: 0.76, height: 0.04)

    static func range(of needle: String, in text: String) -> SourceRange {
        guard let found = text.range(of: needle, options: [.literal]) else {
            return SourceRange(start: 0, end: 0)
        }
        return SourceRange.from(found, in: text)
    }
}
