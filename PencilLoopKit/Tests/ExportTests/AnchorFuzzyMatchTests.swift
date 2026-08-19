//
//  AnchorFuzzyMatchTests.swift
//  ExportTests
//
//  Step 3 of the ladder, which is the rung that has to be pinned hardest: it is
//  the only one that can be *nearly* right. The threshold is exercised on both
//  sides of the boundary, because "within 15%" is a contract shared with
//  whatever re-implements the resolver on the agent's side.
//

import XCTest
import Foundation
import Core

final class AnchorFuzzyMatchTests: XCTestCase {

    // MARK: - What it is for

    /// The case the rung exists for: the document was regenerated and the
    /// sentence came back reworded.
    func testARewordedSentenceStillResolves() {
        let quoted = "The migration runs in a single deploy, with no dual-write window."
        let reworded = Self.document.replacingOccurrences(
            of: "runs in a single deploy",
            with: "runs in one single deploy"
        )

        guard let match = AnchorResolver.fuzzyQuoteRange(quoted: quoted, in: reworded) else {
            return XCTFail("A three-edit rewording should still resolve")
        }
        XCTAssertEqual(
            match.range.substring(of: reworded),
            "The migration runs in one single deploy, with no dual-write window."
        )
        XCTAssertGreaterThan(match.similarity, 0.9)
        XCTAssertLessThan(match.similarity, 1)
    }

    /// The second case: nothing changed but the line breaks. Whitespace is
    /// normalised before comparing, so this is a perfect match — and the range
    /// still points into the original, un-normalised text, newlines included.
    func testReflowedWhitespaceIsAPerfectMatch() {
        let quoted = "The migration runs in a single deploy, with no dual-write window."
        let reflowed = Self.document.replacingOccurrences(
            of: "with no dual-write window.",
            with: "with\n   no dual-write   window."
        )

        guard let match = AnchorResolver.fuzzyQuoteRange(quoted: quoted, in: reflowed) else {
            return XCTFail("Re-wrapping is not an edit")
        }
        XCTAssertEqual(match.similarity, 1, accuracy: 0.000_001)
        XCTAssertEqual(
            match.range.substring(of: reflowed),
            "The migration runs in a single deploy, with\n   no dual-write   window."
        )
    }

    /// Even at zero tolerance, because normalisation happens before the
    /// distance is measured rather than being part of it.
    func testReflowedWhitespaceMatchesAtZeroTolerance() {
        let quoted = "The migration runs in a single deploy"
        let reflowed = Self.document.replacingOccurrences(of: "runs in a", with: "runs\n\tin  a")
        XCTAssertNotNil(AnchorResolver.fuzzyQuoteRange(quoted: quoted, in: reflowed, tolerance: 0))
    }

    // MARK: - The threshold, from both sides

    /// A twenty-character quote tolerates three edits: 0.15 × 20 = 3.
    func testExactlyFifteenPercentIsAccepted() {
        let match = AnchorResolver.fuzzyQuoteRange(
            quoted: Self.needle,
            in: Self.haystack(editing: 3)
        )
        XCTAssertNotNil(match)
        XCTAssertEqual(match?.similarity ?? 0, 1 - AnchorResolver.fuzzyTolerance, accuracy: 0.000_001)
    }

    func testOneEditPastFifteenPercentIsRefused() {
        XCTAssertNil(
            AnchorResolver.fuzzyQuoteRange(quoted: Self.needle, in: Self.haystack(editing: 4))
        )
    }

    func testEveryEditCountUpToTheThresholdIsAccepted() {
        for edits in 0...3 {
            XCTAssertNotNil(
                AnchorResolver.fuzzyQuoteRange(quoted: Self.needle, in: Self.haystack(editing: edits)),
                "\(edits) edits in a 20-character quote is within 15%"
            )
        }
    }

    /// The similarity a caller reports is never below `1 - tolerance`, which is
    /// what `AnchorResolution.fuzzy` promises.
    func testSimilarityNeverFallsBelowOneMinusTolerance() {
        for edits in 0...3 {
            let similarity = AnchorResolver.fuzzyQuoteRange(
                quoted: Self.needle,
                in: Self.haystack(editing: edits)
            )?.similarity ?? 0
            XCTAssertGreaterThanOrEqual(similarity, 1 - AnchorResolver.fuzzyTolerance - 0.000_001)
        }
    }

    /// A tighter tolerance narrows the gate, and the parameter is the only thing
    /// that moves.
    func testATighterToleranceRefusesWhatTheDefaultAccepts() {
        let haystack = Self.haystack(editing: 3)
        XCTAssertNotNil(AnchorResolver.fuzzyQuoteRange(quoted: Self.needle, in: haystack))
        XCTAssertNil(AnchorResolver.fuzzyQuoteRange(quoted: Self.needle, in: haystack, tolerance: 0.05))
    }

    // MARK: - What it refuses outright

    /// A short quote is within 15% of far too many other short quotes, and a
    /// confident wrong answer is worse than a rect fallback.
    func testQuotesBelowTheMinimumLengthAreRefused() {
        let short = String(repeating: "a", count: AnchorResolver.minimumFuzzyLength - 1)
        XCTAssertNil(AnchorResolver.fuzzyQuoteRange(quoted: short, in: "xx " + short + " yy"))
    }

    func testTheMinimumLengthItselfIsAccepted() {
        let atLimit = "abcdefghijkl"
        XCTAssertEqual(atLimit.count, AnchorResolver.minimumFuzzyLength)
        XCTAssertNotNil(AnchorResolver.fuzzyQuoteRange(quoted: atLimit, in: "xx " + atLimit + " yy"))
    }

    func testAQuoteWhoseWhitespaceCollapsesBelowTheMinimumIsRefused() {
        // Ten characters, seven once the whitespace collapses. The length that
        // decides is the normalised one, because that is the string compared.
        XCTAssertNil(AnchorResolver.fuzzyQuoteRange(quoted: "a b  c   d", in: "zzz a b c d zzz"))
    }

    func testAnEmptyDocumentMatchesNothing() {
        XCTAssertNil(AnchorResolver.fuzzyQuoteRange(quoted: Self.needle, in: ""))
    }

    // MARK: - The primitives

    func testNormalisedWhitespaceCollapsesAndTrims() {
        XCTAssertEqual(
            AnchorResolver.normalisedWhitespace("  one\ttwo\n\n three   four \n"),
            "one two three four"
        )
        XCTAssertEqual(AnchorResolver.normalisedWhitespace("   "), "")
        XCTAssertEqual(AnchorResolver.normalisedWhitespace("single"), "single")
    }

    func testLevenshteinCountsTheThreeOperations() {
        XCTAssertEqual(AnchorResolver.levenshteinDistance("kitten", "sitting"), 3)
        XCTAssertEqual(AnchorResolver.levenshteinDistance("", "abc"), 3)
        XCTAssertEqual(AnchorResolver.levenshteinDistance("abc", ""), 3)
        XCTAssertEqual(AnchorResolver.levenshteinDistance("abc", "abc"), 0)
        XCTAssertEqual(AnchorResolver.levenshteinDistance("abc", "abd"), 1)
    }

    /// An accented letter is one edit, not two: the comparison is over
    /// `Character`s, not bytes.
    func testLevenshteinComparesCharactersNotBytes() {
        XCTAssertEqual(AnchorResolver.levenshteinDistance("café", "cafe"), 1)
        XCTAssertEqual(AnchorResolver.levenshteinDistance("café", "café"), 0)
    }

    /// A quote containing multi-byte characters still comes back as a range that
    /// slices where it says it does — the offsets are UTF-8 bytes, the
    /// comparison is characters, and the two must not be confused.
    func testRangesAreUTF8OffsetsEvenWithMultiByteText() {
        let text = "Préambule. Le déploiement se fait en une seule étape, sans fenêtre. Fin."
        let quoted = "Le déploiement se fait en une seule étape, sans fenêtre."

        guard let match = AnchorResolver.fuzzyQuoteRange(quoted: quoted, in: text) else {
            return XCTFail("An exact quote should match at zero distance")
        }
        XCTAssertEqual(match.range.substring(of: text), quoted)
        XCTAssertEqual(match.range.length, quoted.utf8.count)
        XCTAssertGreaterThan(match.range.length, quoted.count)
    }

    // MARK: - Support

    static let document = """
        Phase 1 introduces the refresh token stored in the keychain. \
        The migration runs in a single deploy, with no dual-write window. \
        Rollout is gated behind auth_v2 for the first week.
        """

    /// Twenty characters, so `0.15 × count` is exactly 3.
    static let needle = "abcdefghijklmnopqrst"

    /// `needle` with its first `edits` characters replaced, buried in a document
    /// that shares none of them.
    static func haystack(editing edits: Int) -> String {
        let mutated = String(repeating: "Z", count: edits) + String(needle.dropFirst(edits))
        return "prelude words " + mutated + " and the tail"
    }
}
