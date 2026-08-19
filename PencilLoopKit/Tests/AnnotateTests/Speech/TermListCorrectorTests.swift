//
//  TermListCorrectorTests.swift
//  AnnotateTests · Speech
//
//  Half of these prove the corrector fixes jargon. The other half prove it
//  keeps its hands off everything else, which is the half that matters more:
//  a missed correction is a typo, a wrong one is a different sentence.
//

import XCTest
import Core
@testable import Annotate

final class TermListCorrectorTests: XCTestCase {

    private let corrector = TermListCorrector()

    // MARK: Term list

    func testTitleWordsRankAboveEverythingElse() {
        let terms = corrector.terms(
            forDocumentText: "The renderer walks the AttributedString once per page.",
            title: "Deterministic pagination"
        )

        XCTAssertEqual(terms.first, "Deterministic")
        XCTAssertTrue(terms.contains("pagination"))
    }

    func testIdentifiersAndCodeSpansAreCollected() {
        let text = """
        Call `saveDrawing(_:pageIndex:documentId:)` after the debounce. The
        source_map is written alongside, and PKCanvasView is recycled with the
        page view.
        """
        let terms = corrector.terms(forDocumentText: text, title: "Ink")

        XCTAssertTrue(terms.contains("saveDrawing"))
        XCTAssertTrue(terms.contains("pageIndex"))
        XCTAssertTrue(terms.contains("source_map"))
        XCTAssertTrue(terms.contains("PKCanvasView"))
    }

    func testShortAndOrdinaryWordsAreNotTerms() {
        let terms = corrector.terms(
            forDocumentText: "The PDF is A4. This is the same thing every time.",
            title: "A note"
        )

        XCTAssertFalse(terms.contains("The"))
        XCTAssertFalse(terms.contains("This"))
        XCTAssertFalse(terms.contains("A4"))
        XCTAssertFalse(terms.contains("same"))
    }

    func testTermsAreDeduplicatedAndCapped() {
        let words = (0..<400).map { "Identifier\($0)Term" }.joined(separator: " ")
        let terms = corrector.terms(
            forDocumentText: words + " " + words,
            title: "Overflow"
        )

        XCTAssertLessThanOrEqual(terms.count, TermListCorrector.maximumTerms)
        XCTAssertEqual(Set(terms.map { $0.lowercased() }).count, terms.count)
    }

    func testAnEmptyDocumentYieldsAnEmptyList() {
        XCTAssertEqual(corrector.terms(forDocumentText: "", title: ""), [])
    }

    // MARK: Correction that fires

    func testAKnownTermIsRecasedToTheDocumentSpelling() {
        XCTAssertEqual(
            corrector.correct("pencilkit draws the stroke", against: ["PencilKit"]),
            "PencilKit draws the stroke"
        )
    }

    func testAOneEditSlipIsCorrected() {
        XCTAssertEqual(
            corrector.correct("the annotaton is anchored", against: ["annotation"]),
            "the annotation is anchored"
        )
    }

    func testATwoEditSlipIsCorrectedOnlyForALongToken() {
        XCTAssertEqual(
            corrector.correct("the Levinstein distance", against: ["Levenshtein"]),
            "the Levenshtein distance"
        )
    }

    func testPunctuationAndSpacingSurviveExactly() {
        XCTAssertEqual(
            corrector.correct("  annotaton,\nplease. ", against: ["annotation"]),
            "  annotation,\nplease. "
        )
    }

    // MARK: Correction that refuses

    func testAnOrdinaryEnglishWordIsNeverRewritten() {
        // Without the common-word guard, "later" is exactly one edit from
        // "Layer" and would be silently corrupted.
        XCTAssertEqual(
            corrector.correct("we can do that later", against: ["Layer"]),
            "we can do that later"
        )
    }

    func testTheSameTermStillCorrectsANonWord() {
        XCTAssertEqual(
            corrector.correct("the layar is thin", against: ["Layer"]),
            "the Layer is thin"
        )
    }

    func testShortTokensAreNeverFuzzyCorrected() {
        XCTAssertEqual(
            corrector.correct("note that", against: ["notes"]),
            "note that"
        )
        XCTAssertEqual(
            corrector.correct("cade", against: ["code"]),
            "cade"
        )
    }

    func testADifferentFirstLetterIsNeverACorrection() {
        XCTAssertEqual(
            corrector.correct("the banner text", against: ["Manner"]),
            "the banner text"
        )
    }

    func testATieBetweenTwoTermsChangesNothing() {
        XCTAssertEqual(
            corrector.correct("parsee output", against: ["parse", "parsed"]),
            "parsee output"
        )
    }

    func testATokenFarFromEveryTermIsLeftAlone() {
        XCTAssertEqual(
            corrector.correct("the quick brown fox", against: ["PencilKit", "annotation"]),
            "the quick brown fox"
        )
    }

    func testAnEmptyTermListIsAPassThrough() {
        let transcript = "nothing here should move at all"
        XCTAssertEqual(corrector.correct(transcript, against: []), transcript)
    }

    func testMultiWordTermsDoNotCorruptSingleTokens() {
        XCTAssertEqual(
            corrector.correct("the source map is stale", against: ["source map"]),
            "the source map is stale"
        )
    }

    // MARK: Thresholds

    func testTheEditDistanceAllowanceIsAtMostAFifthOfTheToken() {
        XCTAssertEqual(TermListCorrector.maximumEditDistance(forTokenLength: 3), 0)
        XCTAssertEqual(TermListCorrector.maximumEditDistance(forTokenLength: 4), 0)
        XCTAssertEqual(TermListCorrector.maximumEditDistance(forTokenLength: 5), 1)
        XCTAssertEqual(TermListCorrector.maximumEditDistance(forTokenLength: 9), 1)
        XCTAssertEqual(TermListCorrector.maximumEditDistance(forTokenLength: 10), 2)
        XCTAssertEqual(TermListCorrector.maximumEditDistance(forTokenLength: 40), 2)
    }

    func testEditDistanceCountsWhatItShould() {
        XCTAssertEqual(
            TermListCorrector.editDistance(Array("kitten"), Array("sitting"), limit: 9),
            3
        )
        XCTAssertEqual(
            TermListCorrector.editDistance(Array("anchor"), Array("anchor"), limit: 2),
            0
        )
        XCTAssertEqual(
            TermListCorrector.editDistance(Array(""), Array("anchor"), limit: 9),
            6
        )
    }

    func testEditDistanceAbandonsPastTheLimit() {
        let distance = TermListCorrector.editDistance(
            Array("completely"),
            Array("different"),
            limit: 2
        )
        XCTAssertGreaterThan(distance, 2)
    }

    // MARK: End to end

    func testATranscriptIsRepairedAgainstItsOwnDocument() {
        let text = """
        The AnchorResolver climbs four steps. `normalisedRect` is the last
        fallback, and the PKCanvasView overlay is recycled per page.
        """
        let terms = corrector.terms(forDocumentText: text, title: "Anchor resolution")
        let repaired = corrector.correct("the AnchorResolvor step is unclear", against: terms)

        XCTAssertEqual(repaired, "the AnchorResolver step is unclear")
    }
}
