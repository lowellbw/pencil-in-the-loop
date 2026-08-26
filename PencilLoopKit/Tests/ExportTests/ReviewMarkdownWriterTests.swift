//
//  ReviewMarkdownWriterTests.swift
//  ExportTests
//
//  `review.md` has a golden fixture, so this is the one place in Wave 1 where a
//  test can be an equality against a byte-exact target rather than a set of
//  plausible-looking assertions. The fixture is read from
//  contracts/fixtures/review.md rather than copied here: a second copy would
//  drift, and check_json.py already holds that one against docs/05.
//

import XCTest
import Foundation
import Core
@testable import Export

final class ReviewMarkdownWriterTests: XCTestCase {

    // MARK: - The golden fixture

    /// ─── THE ONE DIVERGENCE ──────────────────────────────────────────────
    /// contracts/fixtures/review.md says "3 comments" in its header and then
    /// lists two. So does the fenced block in docs/05-file-contracts.md it was
    /// transcribed from, byte for byte, which is why check_json.py is happy
    /// with it: the fixture is a faithful copy of an abridged example.
    ///
    /// A writer cannot reproduce that and stay honest — the count has to
    /// describe what is in the file. Everything else matches exactly, and this
    /// test substitutes that single token so the rest is still an equality.
    /// Raised as a fixture change request in this unit's report.
    /// ─────────────────────────────────────────────────────────────────────
    func testMatchesTheGoldenFixtureExceptForItsCommentCount() throws {
        let fixture = try String(contentsOf: ExportTestFixtures.goldenReviewMarkdown, encoding: .utf8)
        let expected = fixture.replacingOccurrences(
            of: "\u{00B7} 3 comments \u{00B7}",
            with: "\u{00B7} 2 comments \u{00B7}"
        )
        XCTAssertNotEqual(
            expected,
            fixture,
            "The fixture no longer says '· 3 comments ·'; if it was corrected, delete this substitution."
        )

        let generated = ExportTestFixtures.markdownWriter().markdown(
            for: ExportTestFixtures.draft(),
            comments: ExportTestFixtures.reviewComments(),
            inkPages: ExportTestFixtures.inkPages()
        )

        // Line-wise first: the element diff names the line that moved.
        XCTAssertEqual(
            generated.components(separatedBy: "\n"),
            expected.components(separatedBy: "\n")
        )
        XCTAssertEqual(generated, expected)
    }

    func testTheCountLineDescribesWhatIsActuallyInTheFile() {
        let generated = ExportTestFixtures.markdownWriter().markdown(
            for: ExportTestFixtures.draft(),
            comments: ExportTestFixtures.reviewComments(),
            inkPages: ExportTestFixtures.inkPages()
        )
        XCTAssertTrue(
            generated.contains("Reviewed 18 Aug 2026, 21:14 \u{00B7} 2 comments \u{00B7} 2 inked pages"),
            generated
        )
    }

    // MARK: - The structure the fixture fixes

    func testTheDocumentOpensWithItsTitle() {
        XCTAssertTrue(Self.render().hasPrefix("# Review \u{2014} Auth refactor plan\n\n"))
    }

    func testCommentHeadingsAreNumberedAndOneBasedByPage() {
        let rendered = Self.render()
        XCTAssertTrue(rendered.contains("### 1 \u{2014} page 1"), rendered)
        XCTAssertTrue(rendered.contains("### 2 \u{2014} page 2"), rendered)
    }

    func testEachCommentCarriesItsSourceLine() {
        let rendered = Self.render()
        XCTAssertTrue(rendered.contains("*voice, transcribed*"))
        XCTAssertTrue(rendered.contains("*handwriting, recognised*"))
    }

    /// The closing paragraph is not decoration: it tells the model to match on
    /// the quote rather than on a line number, and docs/05 says that measurably
    /// improves how reliably edits land.
    func testTheClosingParagraphIsAlwaysWritten() {
        let bare = ExportTestFixtures.draft(comments: [], closingInstruction: "")
        let rendered = ExportTestFixtures.markdownWriter().markdown(for: bare)

        XCTAssertTrue(rendered.contains("## How to locate these passages"))
        XCTAssertTrue(rendered.contains("Match on the quote,"))
        XCTAssertTrue(rendered.contains("not on a line number"))
        XCTAssertTrue(rendered.hasSuffix("the document may have changed since.\n"))
    }

    /// A line number never appears as an anchor anywhere in the payload
    /// (CLAUDE.md non-negotiable 5).
    func testNoLineNumberIsEverPresentedAsAnAnchor() {
        let rendered = Self.render()
        XCTAssertFalse(rendered.lowercased().contains("line 1"))
        XCTAssertFalse(rendered.lowercased().contains("at line"))
        XCTAssertFalse(rendered.lowercased().contains("lineNumber".lowercased()))
    }

    // MARK: - Excerpts are verbatim

    /// The fixture's `await refresh(session)   // no backoff` keeps its run of
    /// spaces. A reflowed quote is not "exact text from the document you
    /// produced", which is what the closing paragraph promises.
    func testAnExcerptIsNeverReflowed() {
        XCTAssertTrue(Self.render().contains("> await refresh(session)   // no backoff"))
    }

    func testAMultiLineExcerptGetsAMarkerPerLine() {
        let comment = ReviewComment(
            id: "C1",
            index: 1,
            text: "This block is wrong.",
            source: .typed,
            anchor: Anchor(
                quoted: "first line\n\nthird line",
                pageIndex: 0,
                normalisedRect: .zero
            )
        )
        let rendered = ExportTestFixtures.markdownWriter().markdown(
            for: ExportTestFixtures.draft(),
            comments: [comment]
        )
        XCTAssertTrue(rendered.contains("> first line\n>\n> third line"), rendered)
    }

    func testAVeryLongExcerptIsNotWrapped() {
        let long = String(repeating: "word ", count: 60) + "end."
        let comment = ReviewComment(
            id: "C1",
            index: 1,
            text: "Too long.",
            source: .typed,
            anchor: Anchor(quoted: long, pageIndex: 0, normalisedRect: .zero)
        )
        let rendered = ExportTestFixtures.markdownWriter().markdown(
            for: ExportTestFixtures.draft(),
            comments: [comment]
        )
        XCTAssertTrue(rendered.contains("> " + long), "The excerpt was reflowed")
    }

    // MARK: - Counts, sections and toggles

    func testSingularCounts() {
        let rendered = ExportTestFixtures.markdownWriter().markdown(
            for: ExportTestFixtures.draft(comments: [ExportTestFixtures.firstComment()]),
            comments: [ExportTestFixtures.reviewComments()[0]],
            inkPages: [ReviewInkPage(pageIndex: 0, image: InkImage.fileName(forPageIndex: 0))]
        )
        XCTAssertTrue(rendered.contains("\u{00B7} 1 comment \u{00B7} 1 inked page"), rendered)
        XCTAssertTrue(rendered.contains("Page 1 has handwritten marks"), rendered)
    }

    func testThreeInkedPagesAreListedWithAnOxfordFreeConjunction() {
        let pages = [0, 2, 6].map {
            ReviewInkPage(pageIndex: $0, image: InkImage.fileName(forPageIndex: $0))
        }
        let rendered = ExportTestFixtures.markdownWriter().markdown(
            for: ExportTestFixtures.draft(),
            comments: ExportTestFixtures.reviewComments(),
            inkPages: pages
        )
        XCTAssertTrue(rendered.contains("Pages 1, 3 and 7 have handwritten marks"), rendered)
        XCTAssertTrue(rendered.contains("`ink/page-07.png`"), rendered)
    }

    func testAnEmptyClosingInstructionDropsItsSection() {
        let rendered = ExportTestFixtures.markdownWriter().markdown(
            for: ExportTestFixtures.draft(closingInstruction: "   \n  "),
            comments: ExportTestFixtures.reviewComments()
        )
        XCTAssertFalse(rendered.contains("## What I want done"))
    }

    func testNoInkDropsTheHandwrittenSection() {
        let rendered = ExportTestFixtures.markdownWriter().markdown(
            for: ExportTestFixtures.draft(),
            comments: ExportTestFixtures.reviewComments()
        )
        XCTAssertFalse(rendered.contains("## Handwritten pages"))
        XCTAssertFalse(rendered.contains("inked page"))
    }

    func testCommentsToggledOffDropsTheSectionAndTheCount() {
        let include = ReviewIncludeOptions(comments: false)
        let rendered = ExportTestFixtures.markdownWriter().markdown(
            for: ExportTestFixtures.draft(include: include),
            comments: [],
            inkPages: ExportTestFixtures.inkPages()
        )
        XCTAssertFalse(rendered.contains("## Comments"))
        XCTAssertFalse(rendered.contains("### 1"))
        // The count line drops the comment part rather than claiming zero.
        XCTAssertTrue(rendered.contains("Reviewed 18 Aug 2026, 21:14 \u{00B7} 2 inked pages\n"), rendered)
        XCTAssertTrue(rendered.contains("## Handwritten pages"))
    }

    func testRecognisedHandwritingIsOfferedUnderTheImages() {
        let pages = [
            ReviewInkPage(
                pageIndex: 0,
                image: InkImage.fileName(forPageIndex: 0),
                recognisedText: "do we? check the mobile SDK"
            )
        ]
        let rendered = ExportTestFixtures.markdownWriter().markdown(
            for: ExportTestFixtures.draft(),
            comments: ExportTestFixtures.reviewComments(),
            inkPages: pages
        )
        XCTAssertTrue(rendered.contains("Recognised handwriting, page 1:"), rendered)
        XCTAssertTrue(rendered.contains("> do we? check the mobile SDK"), rendered)
    }

    // MARK: - The origin line

    func testOriginLineWithoutAThreadOrASession() {
        let rendered = ExportTestFixtures.markdownWriter().markdown(
            for: ExportTestFixtures.draft(origin: Origin(kind: .manual))
        )
        XCTAssertTrue(rendered.contains("\nOrigin: Added manually\n"), rendered)
    }

    func testALongSessionIdIsAbbreviated() {
        let origin = Origin(kind: .claudeCode, sessionId: "session_0134GYfPm1zZP9SXNzonjiGW")
        let rendered = ExportTestFixtures.markdownWriter().markdown(
            for: ExportTestFixtures.draft(origin: origin)
        )
        XCTAssertTrue(rendered.contains("Origin: Claude Code \u{00B7} session session_0134\u{2026}"), rendered)
    }

    func testABlankSessionIdIsNotShown() {
        let origin = Origin(kind: .cowork, sessionId: "   ", threadTitle: "Planning")
        let rendered = ExportTestFixtures.markdownWriter().markdown(
            for: ExportTestFixtures.draft(origin: origin)
        )
        XCTAssertTrue(rendered.contains("Origin: Cowork \u{00B7} \"Planning\"\n"), rendered)
        XCTAssertFalse(rendered.contains("session"))
    }

    // MARK: - Approximate anchors

    /// A rect fallback has to be described as approximate wherever it appears.
    /// An exact match can be edited blind; this cannot.
    func testARectFallbackIsDescribedAsApproximate() {
        let rendered = ExportTestFixtures.markdownWriter().markdown(
            for: ExportTestFixtures.draft(),
            comments: ExportTestFixtures.reviewComments(),
            resolutions: [
                "C1": .rectFallback(pageIndex: 0, rect: NormalisedRect(x: 0, y: 0, width: 1, height: 0.1))
            ]
        )
        XCTAssertTrue(rendered.contains("position approximate"), rendered)
        // …and only on the comment that fell back.
        XCTAssertEqual(Self.occurrences(of: "position approximate", in: rendered), 1)
    }

    func testATextMatchIsDescribedSilently() {
        let rendered = ExportTestFixtures.markdownWriter().markdown(
            for: ExportTestFixtures.draft(),
            comments: ExportTestFixtures.reviewComments(),
            resolutions: [
                "C1": .exact(range: SourceRange(start: 1204, end: 1268)),
                "C2": .fuzzy(range: SourceRange(start: 10, end: 40), similarity: 0.9)
            ]
        )
        XCTAssertFalse(rendered.contains("approximate"))
        XCTAssertTrue(rendered.contains("*voice, transcribed*"))
    }

    // MARK: - Wrapping

    func testGeneratedProseIsWrappedAtEightyFiveCharacters() {
        let long = String(repeating: "instruction ", count: 40)
        let rendered = ExportTestFixtures.markdownWriter().markdown(
            for: ExportTestFixtures.draft(closingInstruction: long)
        )
        let wrapped = rendered
            .components(separatedBy: "\n")
            .filter { $0.hasPrefix("instruction") }

        XCTAssertGreaterThan(wrapped.count, 1, "A 480-character instruction should wrap")
        for line in wrapped {
            XCTAssertLessThanOrEqual(line.count, ReviewMarkdownWriter.wrapWidth, line)
        }
    }

    func testParagraphBreaksInTheClosingInstructionSurvive() {
        let rendered = ExportTestFixtures.markdownWriter().markdown(
            for: ExportTestFixtures.draft(closingInstruction: "First point.\n\nSecond point.")
        )
        XCTAssertTrue(rendered.contains("First point.\n\nSecond point."), rendered)
    }

    // MARK: - Support

    static func render() -> String {
        ExportTestFixtures.markdownWriter().markdown(
            for: ExportTestFixtures.draft(),
            comments: ExportTestFixtures.reviewComments(),
            inkPages: ExportTestFixtures.inkPages()
        )
    }

    static func occurrences(of needle: String, in text: String) -> Int {
        guard !needle.isEmpty else { return 0 }
        var count = 0
        var searchStart = text.startIndex
        while let found = text.range(of: needle, options: [.literal], range: searchStart..<text.endIndex) {
            count += 1
            searchStart = found.upperBound
        }
        return count
    }
}
