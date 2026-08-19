//
//  MarkdownPDFRendererTests.swift
//  IngestTests
//
//  The keystone: does a rect on a rendered page still know which bytes of
//  markdown it came from (docs/03-architecture.md § 1)?
//
//  These need a graphics context, so they run on device or in the Simulator
//  rather than under `swift test` on a Mac command line.
//

import XCTest
import Core
@testable import Ingest

final class MarkdownPDFRendererTests: XCTestCase {

    private let renderer = MarkdownPDFRenderer()
    private let geometry = PageGeometry.annotationFriendly

    private let sample = """
    # Auth refactor plan

    The migration runs in a single deploy, with no dual-write window. Rollout is
    gated behind a flag so the change can be reverted without a redeploy.

    ## Phases

    1. Shadow read for a day
    2. Cut over
    3. Remove the old path

    > This is the part that needs a second opinion.

    ```swift
    await refresh(session)
    ```

    | Phase | Days |
    | --- | --- |
    | Shadow | 1 |
    | Cutover | 1 |

    ---

    Final paragraph, with an em dash — and a café.
    """

    // MARK: - Output

    func testRendersAPdfWithPages() throws {
        let rendered = try renderer.render(try parse(sample), geometry: geometry)

        XCTAssertTrue(rendered.pageCount > 0)
        XCTAssertFalse(rendered.pdfData.isEmpty)
        XCTAssertEqual(rendered.pdfData.prefix(4), Data("%PDF".utf8))
        XCTAssertTrue(rendered.extractedText.contains("dual-write"))
    }

    func testAnEmptyDocumentStillProducesOnePage() throws {
        let rendered = try renderer.render(MarkdownDocument(source: "", blocks: []), geometry: geometry)
        XCTAssertEqual(rendered.pageCount, 1)
        XCTAssertTrue(rendered.sourceMap.isEmpty)
    }

    func testGeometryWithNoTextColumnIsARenderFailure() {
        let narrow = PageGeometry(
            pageWidth: 100,
            pageHeight: 200,
            marginTop: 10,
            marginLeft: 60,
            marginBottom: 10,
            marginRight: 60,
            bodyPointSize: 11,
            lineSpacingMultiple: 1.35,
            maxCodeColumnCharacters: 76
        )
        XCTAssertThrowsError(try renderer.render(try parse("hello"), geometry: narrow)) { error in
            guard case PencilLoopError.renderFailed = error else {
                return XCTFail("expected renderFailed, got \(error)")
            }
        }
    }

    // MARK: - The source map

    func testEverySourceMapRangeResolvesToRealText() throws {
        let document = try parse(sample)
        let rendered = try renderer.render(document, geometry: geometry)

        XCTAssertFalse(rendered.sourceMap.isEmpty)
        for entry in rendered.sourceMap.entries {
            XCTAssertTrue(entry.pageIndex >= 0)
            XCTAssertTrue(entry.pageIndex < rendered.pageCount)
            XCTAssertTrue(entry.range.isValid)
            XCTAssertNotNil(
                entry.range.substring(of: document.source),
                "entry \(entry.range) does not resolve in source.md"
            )
        }
    }

    func testRectsAreNormalisedTopLeftAndOnThePage() throws {
        let rendered = try renderer.render(try parse(sample), geometry: geometry)
        let firstPage = rendered.sourceMap.entries(onPage: 0)
        let first = try XCTUnwrap(firstPage.first)

        // The first thing on the page sits just below the top margin, which is
        // only true if the CoreText flip went the right way.
        XCTAssertTrue(first.rect.y < 0.2, "first entry at y=\(first.rect.y) — is the page upside down?")
        XCTAssertTrue(first.rect.x > 0.05)

        for entry in firstPage {
            XCTAssertTrue(entry.rect.width > 0)
            XCTAssertTrue(entry.rect.height > 0)
            XCTAssertTrue(entry.rect.minY > -0.01)
            XCTAssertTrue(entry.rect.maxY < 1.01)
            XCTAssertTrue(entry.rect.maxX < 1.01)
        }
    }

    func testEntriesRunDownThePageInRecordedOrder() throws {
        let rendered = try renderer.render(try parse("First line here.\n\nSecond line here.\n\nThird line here.\n"), geometry: geometry)
        let entries = rendered.sourceMap.entries(onPage: 0)
        XCTAssertTrue(entries.count >= 3)
        for index in 1 ..< entries.count {
            XCTAssertTrue(entries[index].rect.y >= entries[index - 1].rect.y - 0.001)
        }
    }

    func testRectToRangeLookupFindsThePassageUnderneathIt() throws {
        let document = try parse(sample)
        let rendered = try renderer.render(document, geometry: geometry)
        let entry = try XCTUnwrap(rendered.sourceMap.entries.first { entry in
            entry.range.substring(of: document.source)?.contains("dual-write") == true
        })

        let found = try XCTUnwrap(rendered.sourceMap.range(nearest: entry.rect, page: entry.pageIndex))
        XCTAssertTrue(found.overlaps(entry.range))
        XCTAssertNotNil(found.substring(of: document.source))
    }

    func testRangeToRectLookupIsTheInverse() throws {
        let document = try parse(sample)
        let rendered = try renderer.render(document, geometry: geometry)
        let entry = try XCTUnwrap(rendered.sourceMap.entries.first)

        let located = try XCTUnwrap(rendered.sourceMap.rect(containing: entry.range.start))
        XCTAssertEqual(located.page, entry.pageIndex)
        XCTAssertTrue(located.rect.intersects(entry.rect))
    }

    /// A list bullet is synthetic text with no per-code-unit table, so whatever
    /// range it is given is the range it reports for itself — and it is recorded
    /// before the words beside it. Given the whole item's range it became the
    /// first entry containing every offset in that item, and
    /// `SourceMap.rect(containing:)` answers with the first one it finds: every
    /// "scroll to this range" inside a list landed on a couple of glyphs of
    /// bullet.
    func testAnOffsetInsideAListItemDoesNotResolveToItsBullet() throws {
        let document = try parse(sample)
        let rendered = try renderer.render(document, geometry: geometry)

        let found = try XCTUnwrap(document.source.range(of: "Cut over"))
        let words = SourceRange.from(found, in: document.source)

        let located = try XCTUnwrap(rendered.sourceMap.rect(containing: words.start))
        let text = try XCTUnwrap(rendered.sourceMap.rects(forRange: words).first)

        XCTAssertEqual(located.page, text.page)
        XCTAssertTrue(
            located.rect.width >= text.rect.width * 0.5,
            "an offset inside a list item resolved to a \(located.rect.width)-wide rect "
                + "against \(text.rect.width) for the words themselves — that is the bullet"
        )
    }

    func testRectsForRangeGiveOneRectPerPage() throws {
        let document = try parse(sample)
        let rendered = try renderer.render(document, geometry: geometry)
        let whole = SourceRange.whole(of: document.source)
        let rects = rendered.sourceMap.rects(forRange: whole)

        XCTAssertFalse(rects.isEmpty)
        XCTAssertEqual(rects.count, Set(rects.map(\.page)).count)
        XCTAssertEqual(rects.map(\.page), rects.map(\.page).sorted())
    }

    func testTheTitleHeadingMapsBackToItsOwnBytes() throws {
        let markdown = "# Auth refactor plan\n\nBody paragraph.\n"
        let document = try parse(markdown)
        let rendered = try renderer.render(document, geometry: geometry)
        let entry = try XCTUnwrap(rendered.sourceMap.entries.first)
        XCTAssertEqual(entry.range.substring(of: markdown), "Auth refactor plan")
    }

    func testCodeAndTableTextAreInTheMapToo() throws {
        let document = try parse(sample)
        let rendered = try renderer.render(document, geometry: geometry)
        let quoted = rendered.sourceMap.entries.compactMap { $0.range.substring(of: document.source) }

        XCTAssertTrue(quoted.contains { $0.contains("refresh(session)") }, "code block missing from the map")
        XCTAssertTrue(quoted.contains { $0.contains("Shadow") }, "table cell missing from the map")
        XCTAssertTrue(quoted.contains { $0.contains("second opinion") }, "blockquote missing from the map")
    }

    // MARK: - Determinism and pagination

    func testTwoRunsProduceIdenticalPaginationAndSourceMaps() throws {
        let document = try parse(sample)
        let first = try renderer.render(document, geometry: geometry)
        let second = try renderer.render(document, geometry: geometry)

        XCTAssertEqual(first.pageCount, second.pageCount)
        XCTAssertEqual(first.sourceMap, second.sourceMap)
        XCTAssertEqual(first.extractedText, second.extractedText)
    }

    func testALongDocumentPaginates() throws {
        var markdown = "# Long\n\n"
        for index in 0 ..< 120 {
            markdown += "Paragraph number \(index) with enough words in it to take up a line or two of the text column on an A4 page.\n\n"
        }
        let document = try parse(markdown)
        let rendered = try renderer.render(document, geometry: geometry)

        XCTAssertTrue(rendered.pageCount > 1, "120 paragraphs should not fit on one page")
        XCTAssertFalse(rendered.sourceMap.entries(onPage: 1).isEmpty)
        XCTAssertTrue(Set(rendered.sourceMap.entries.map(\.pageIndex)).count <= rendered.pageCount)
    }

    func testHandBuiltIrRendersWithoutAParser() throws {
        let source = "Alpha beta gamma"
        let document = MarkdownDocument(
            source: source,
            blocks: [
                .paragraph(
                    inlines: [InlineRun(text: source, sourceRange: SourceRange(start: 0, end: 16))],
                    sourceRange: SourceRange(start: 0, end: 16)
                )
            ]
        )
        let rendered = try renderer.render(document, geometry: geometry)
        XCTAssertEqual(rendered.pageCount, 1)
        let entry = try XCTUnwrap(rendered.sourceMap.entries.first)
        XCTAssertEqual(entry.range.substring(of: source), source)
    }

    // MARK: - On-disk shape

    func testSourceMapEncodesLikeTheFixture() throws {
        let document = try parse(sample)
        let rendered = try renderer.render(document, geometry: geometry)
        var map = rendered.sourceMap
        map.documentId = "F7A1"

        let data = try ContractCoding.encoder().encode(map)
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertEqual(object["version"] as? Int, SourceMap.currentVersion)
        XCTAssertEqual(object["source"] as? String, "source.md")
        XCTAssertEqual(object["offsetEncoding"] as? String, SourceMap.utf8Encoding)
        XCTAssertEqual(object["documentId"] as? String, "F7A1")

        let entries = try XCTUnwrap(object["entries"] as? [[String: Any]])
        let first = try XCTUnwrap(entries.first)
        XCTAssertEqual((first["rect"] as? [Double])?.count, 4)
        XCTAssertEqual((first["range"] as? [Int])?.count, 2)

        let decoded = try ContractCoding.decoder().decode(SourceMap.self, from: data)
        XCTAssertEqual(decoded, map)
    }

    // MARK: - Helpers

    private func parse(_ markdown: String) throws -> MarkdownDocument {
        try SwiftMarkdownAdapter().parse(markdown)
    }
}
