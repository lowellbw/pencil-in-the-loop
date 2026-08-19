//
//  MarkdownFallbackTests.swift
//  IngestTests
//
//  docs/04-flows.md § F1: never throw a document away.
//

import XCTest
import Core
@testable import Ingest

final class MarkdownFallbackTests: XCTestCase {

    func testPreformattedKeepsEveryByteOfTheSource() {
        let markdown = "# Title\n\nSomething the parser hated: \u{0007}\n"
        let document = MarkdownFallback.preformatted(markdown)

        XCTAssertEqual(document.source, markdown)
        XCTAssertEqual(document.blocks.count, 1)
        guard case let .codeBlock(language, code, contentRange, range) = document.blocks[0] else {
            return XCTFail("expected one preformatted block")
        }
        XCTAssertNil(language)
        XCTAssertEqual(code, markdown)
        XCTAssertEqual(range, SourceRange.whole(of: markdown))
        XCTAssertEqual(contentRange, range)
        XCTAssertEqual(range.substring(of: markdown), markdown)
    }

    func testPreformattedStillFindsATitle() {
        let document = MarkdownFallback.preformatted("# Auth refactor plan\n\nbody\n")
        XCTAssertEqual(document.title, "Auth refactor plan")
    }

    func testPreformattedSkipsLeadingBlankLinesBeforeGivingUp() {
        XCTAssertEqual(MarkdownFallback.headingLine(in: "\n\n# Late title\n"), "Late title")
        XCTAssertNil(MarkdownFallback.headingLine(in: "body first\n\n# Not a title\n"))
        XCTAssertNil(MarkdownFallback.headingLine(in: "#no space\n"))
        XCTAssertNil(MarkdownFallback.headingLine(in: "#   \n"))
    }

    func testEmptySourceProducesAnEmptyDocumentRatherThanAnEmptyBlock() {
        let document = MarkdownFallback.preformatted("")
        XCTAssertTrue(document.blocks.isEmpty)
        XCTAssertNil(document.title)
    }
}
