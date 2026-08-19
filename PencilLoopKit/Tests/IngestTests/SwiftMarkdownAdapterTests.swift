//
//  SwiftMarkdownAdapterTests.swift
//  IngestTests
//
//  IR round-trips and — the part that actually matters — source ranges for
//  every block type. Lists, code blocks and tables get the most attention
//  because their nodes cover syntax the reader never sees, which is exactly
//  where an offset quietly goes wrong.
//

import XCTest
import Core
@testable import Ingest

final class SwiftMarkdownAdapterTests: XCTestCase {

    private let adapter = SwiftMarkdownAdapter()

    // MARK: - Shape

    func testDocumentKeepsItsSourceVerbatim() throws {
        let markdown = "# Title\n\nBody text.\n"
        let document = try adapter.parse(markdown)
        XCTAssertEqual(document.source, markdown)
        XCTAssertEqual(document.title, "Title")
    }

    func testTitleIsTheFirstLevelOneHeadingOnly() throws {
        let markdown = "## Not this\n\n# This one\n\n# Nor this\n"
        let document = try adapter.parse(markdown)
        XCTAssertEqual(document.title, "This one")
    }

    func testTitleIsNilWithoutALevelOneHeading() throws {
        let document = try adapter.parse("Just a paragraph.\n")
        XCTAssertNil(document.title)
    }

    func testEmptySourceParsesToNothingRatherThanThrowing() throws {
        let document = try adapter.parse("")
        XCTAssertTrue(document.blocks.isEmpty)
        XCTAssertTrue(document.plainText.isEmpty)
    }

    func testBlockKindsSurviveTheRoundTrip() throws {
        let markdown = """
        # Heading

        A paragraph.

        - one
        - two

        > quoted

        ```swift
        let x = 1
        ```

        ---
        """
        let document = try adapter.parse(markdown)
        var kinds: [String] = []
        for block in document.blocks {
            switch block {
            case .heading: kinds.append("heading")
            case .paragraph: kinds.append("paragraph")
            case .list: kinds.append("list")
            case .blockquote: kinds.append("blockquote")
            case .codeBlock: kinds.append("code")
            case .thematicBreak: kinds.append("rule")
            case .table: kinds.append("table")
            }
        }
        XCTAssertEqual(kinds, ["heading", "paragraph", "list", "blockquote", "code", "rule"])
    }

    // MARK: - Inline attributes

    func testInlineAttributesAndLinkDestination() throws {
        let markdown = "Plain *soft* **hard** `code` [text](https://example.com/a) done.\n"
        let document = try adapter.parse(markdown)
        let runs = try XCTUnwrap(paragraphRuns(document.blocks.first))

        XCTAssertTrue(runs.contains { $0.text == "soft" && $0.attributes.contains(.emphasis) })
        XCTAssertTrue(runs.contains { $0.text == "hard" && $0.attributes.contains(.strong) })
        XCTAssertTrue(runs.contains { $0.text == "code" && $0.attributes.contains(.code) })

        let link = try XCTUnwrap(runs.first { $0.attributes.contains(.link) })
        XCTAssertEqual(link.text, "text")
        XCTAssertEqual(link.linkDestination, "https://example.com/a")
    }

    // MARK: - Source ranges

    func testEveryInlineRunPointsAtItsOwnBytes() throws {
        let markdown = "Some **bold** and `code` here.\n"
        let document = try adapter.parse(markdown)
        let runs = try XCTUnwrap(paragraphRuns(document.blocks.first))

        let bold = try XCTUnwrap(runs.first { $0.attributes.contains(.strong) })
        XCTAssertEqual(bold.sourceRange.substring(of: markdown), "bold")

        let code = try XCTUnwrap(runs.first { $0.attributes.contains(.code) })
        XCTAssertEqual(code.sourceRange.substring(of: markdown), "code")
    }

    func testOffsetsAreBytesNotCharacters() throws {
        let markdown = "Café ☕ with **bóld** after.\n"
        let document = try adapter.parse(markdown)
        let runs = try XCTUnwrap(paragraphRuns(document.blocks.first))
        let bold = try XCTUnwrap(runs.first { $0.attributes.contains(.strong) })

        XCTAssertEqual(bold.sourceRange.substring(of: markdown), "bóld")
        XCTAssertEqual(bold.sourceRange.length, "bóld".utf8.count)
        // The character index and the byte index disagree here; the byte one wins.
        XCTAssertTrue(bold.sourceRange.start > 12)
    }

    func testHeadingRangeCoversItsLine() throws {
        let markdown = "intro\n\n## A heading\n\nafter\n"
        let document = try adapter.parse(markdown)
        let heading = try XCTUnwrap(document.blocks.first { block in
            if case .heading = block { return true }
            return false
        })
        let text = try XCTUnwrap(heading.sourceRange.substring(of: markdown))
        XCTAssertTrue(text.contains("A heading"))
        XCTAssertFalse(text.contains("after"))
    }

    func testListItemRangesAreDistinctAndOrdered() throws {
        let markdown = "- first item\n- second item\n- third item\n"
        let document = try adapter.parse(markdown)
        guard case let .list(ordered, items, listRange)? = document.blocks.first else {
            return XCTFail("expected a list")
        }
        XCTAssertFalse(ordered)
        XCTAssertEqual(items.count, 3)
        XCTAssertTrue(listRange.length > 0)

        XCTAssertTrue(items[0].sourceRange.start < items[1].sourceRange.start)
        XCTAssertTrue(items[1].sourceRange.start < items[2].sourceRange.start)

        for (index, expected) in ["first item", "second item", "third item"].enumerated() {
            let runs = try XCTUnwrap(paragraphRuns(items[index].blocks.first))
            let run = try XCTUnwrap(runs.first)
            XCTAssertEqual(run.text, expected)
            XCTAssertEqual(run.sourceRange.substring(of: markdown), expected)
        }
    }

    func testOrderedListIsMarkedOrdered() throws {
        let markdown = "1. alpha\n2. beta\n"
        let document = try adapter.parse(markdown)
        guard case let .list(ordered, items, _)? = document.blocks.first else {
            return XCTFail("expected a list")
        }
        XCTAssertTrue(ordered)
        XCTAssertEqual(items.count, 2)
    }

    func testNestedListBecomesAListInsideAnItem() throws {
        let markdown = "- outer\n    - inner\n"
        let document = try adapter.parse(markdown)
        guard case let .list(_, items, _)? = document.blocks.first else {
            return XCTFail("expected a list")
        }
        let nested = items[0].blocks.contains { block in
            if case .list = block { return true }
            return false
        }
        XCTAssertTrue(nested)
    }

    func testCodeBlockKeepsItsTextVerbatimAndNamesItsLanguage() throws {
        let markdown = "before\n\n```swift\nlet x = 1\nlet y = 2\n```\n\nafter\n"
        let document = try adapter.parse(markdown)
        guard case let .codeBlock(language, code, contentRange, range)? = document.blocks.first(where: { block in
            if case .codeBlock = block { return true }
            return false
        }) else {
            return XCTFail("expected a code block")
        }
        XCTAssertEqual(language, "swift")
        XCTAssertEqual(code, "let x = 1\nlet y = 2\n")

        let quoted = try XCTUnwrap(range.substring(of: markdown))
        XCTAssertTrue(quoted.contains("let x = 1"))
        XCTAssertFalse(quoted.contains("before"))
        XCTAssertFalse(quoted.contains("after"))

        // The content range names the code and not the fences, which is what an
        // agent asked to edit the code needs (MarkdownIR.swift § codeBlock).
        XCTAssertEqual(contentRange.substring(of: markdown), code)
        XCTAssertTrue(contentRange.start >= range.start)
        XCTAssertTrue(contentRange.end <= range.end)
    }

    func testIndentedCodeBlockHasNoLanguage() throws {
        let markdown = "text\n\n    indented code\n"
        let document = try adapter.parse(markdown)
        guard case let .codeBlock(language, code, contentRange, range)? = document.blocks.last else {
            return XCTFail("expected a code block")
        }
        XCTAssertNil(language)
        XCTAssertTrue(code.contains("indented code"))

        // An indented block has no fences to exclude, and the parser strips the
        // indentation from `code`, so the content range falls back to the block
        // range rather than guessing.
        XCTAssertEqual(contentRange, range)
    }

    func testTableCellsCarryTheirOwnRanges() throws {
        let markdown = """
        | Name | Count |
        | --- | --- |
        | alpha | 1 |
        | beta | 2 |
        """
        let document = try adapter.parse(markdown)
        guard case let .table(header, rows, tableRange)? = document.blocks.first else {
            return XCTFail("expected a table")
        }
        XCTAssertEqual(header.map(\.plainText), ["Name", "Count"])
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].cells.map(\.plainText), ["alpha", "1"])
        XCTAssertEqual(rows[1].cells.map(\.plainText), ["beta", "2"])
        XCTAssertTrue(tableRange.length > 0)

        let cellRun = try XCTUnwrap(rows[0].cells.first?.inlines.first)
        XCTAssertEqual(cellRun.sourceRange.substring(of: markdown), "alpha")

        let headerRun = try XCTUnwrap(header.first?.inlines.first)
        XCTAssertEqual(headerRun.sourceRange.substring(of: markdown), "Name")
    }

    func testBlockquoteKeepsItsChildBlocks() throws {
        let markdown = "> quoted line\n>\n> second para\n"
        let document = try adapter.parse(markdown)
        guard case let .blockquote(blocks, range)? = document.blocks.first else {
            return XCTFail("expected a blockquote")
        }
        XCTAssertEqual(blocks.count, 2)
        XCTAssertTrue(range.length > 0)
        let runs = try XCTUnwrap(paragraphRuns(blocks.first))
        XCTAssertEqual(runs.first?.sourceRange.substring(of: markdown), "quoted line")
    }

    func testThematicBreakCarriesARange() throws {
        let markdown = "a\n\n---\n\nb\n"
        let document = try adapter.parse(markdown)
        guard case let .thematicBreak(range)? = document.blocks.first(where: { block in
            if case .thematicBreak = block { return true }
            return false
        }) else {
            return XCTFail("expected a thematic break")
        }
        XCTAssertTrue(range.length > 0)
        XCTAssertEqual(range.substring(of: markdown)?.contains("---"), true)
    }

    func testEveryRangeInTheDocumentResolvesToText() throws {
        let markdown = """
        # Plan

        A paragraph with **bold**, *emphasis*, `code` and a [link](./x.md).

        - item one
        - item two
            - nested

        > A quote with `code` in it.

        ```python
        def go():
            return 1
        ```

        | Col | Val |
        | --- | --- |
        | a | 1 |

        ---

        Final paragraph — with an em dash and a café.
        """
        let document = try adapter.parse(markdown)
        XCTAssertFalse(document.blocks.isEmpty)
        assertRangesResolve(document.blocks, in: markdown)
    }

    func testASoftBreakIsOneByteWideNotAWholeParagraph() throws {
        let markdown = "first line here\nsecond line here\n"
        let document = try adapter.parse(markdown)
        let runs = try XCTUnwrap(paragraphRuns(document.blocks.first))

        // Whether or not the break merged into its neighbour, no run may claim
        // the whole paragraph on behalf of a single space.
        for run in runs where run.text == " " {
            XCTAssertTrue(run.sourceRange.length <= 2, "a break claimed \(run.sourceRange)")
        }
        let covered = runs.map(\.sourceRange).reduce(0) { $0 + $1.length }
        XCTAssertTrue(covered <= markdown.utf8.count)
    }

    // MARK: - Failure handling

    func testMalformedMarkdownStillProducesADocument() throws {
        let markdown = """
        # Broken

        ```swift
        let unterminated = "fence

        | ragged | table
        | --- |
        | one |

        [unclosed link](
        """
        let document = try adapter.parse(markdown)
        XCTAssertFalse(document.blocks.isEmpty)
        XCTAssertEqual(document.source, markdown)
        assertRangesResolve(document.blocks, in: markdown)
    }

    func testWhitespaceOnlySourceIsNotAFailure() throws {
        let document = try adapter.parse("\n\n   \n")
        XCTAssertTrue(document.blocks.isEmpty)
    }

    func testCarriageReturnsDoNotShiftOffsets() throws {
        let markdown = "para one\r\n\r\nSome **bold** text.\r\n"
        let document = try adapter.parse(markdown)
        assertRangesResolve(document.blocks, in: markdown)
        let last = try XCTUnwrap(document.blocks.last)
        let runs = try XCTUnwrap(paragraphRuns(last))
        let bold = try XCTUnwrap(runs.first { $0.attributes.contains(.strong) })
        XCTAssertEqual(bold.sourceRange.substring(of: markdown), "bold")
    }

    // MARK: - Helpers

    private func paragraphRuns(_ block: MarkdownBlock?) -> [InlineRun]? {
        guard let block else { return nil }
        switch block {
        case let .paragraph(inlines, _): return inlines
        case let .heading(_, inlines, _): return inlines
        default: return nil
        }
    }

    /// Every range in the tree must be valid, inside the source, and land on
    /// scalar boundaries — otherwise `substring(of:)` returns nil and the round
    /// trip is broken.
    private func assertRangesResolve(_ blocks: [MarkdownBlock], in source: String) {
        for block in blocks {
            assertResolves(block.sourceRange, in: source, label: "block")
            switch block {
            case let .heading(_, inlines, _), let .paragraph(inlines, _):
                inlines.forEach { assertResolves($0.sourceRange, in: source, label: "inline") }
            case let .blockquote(inner, _):
                assertRangesResolve(inner, in: source)
            case let .list(_, items, _):
                for item in items {
                    assertResolves(item.sourceRange, in: source, label: "list item")
                    assertRangesResolve(item.blocks, in: source)
                }
            case let .table(header, rows, _):
                for cell in header + rows.flatMap(\.cells) {
                    assertResolves(cell.sourceRange, in: source, label: "cell")
                    cell.inlines.forEach { assertResolves($0.sourceRange, in: source, label: "cell run") }
                }
            case .codeBlock, .thematicBreak:
                break
            }
        }
    }

    private func assertResolves(_ range: SourceRange, in source: String, label: String) {
        XCTAssertTrue(range.isValid, "\(label) range \(range) is not valid")
        XCTAssertTrue(range.end <= source.utf8.count, "\(label) range \(range) runs past the source")
        XCTAssertNotNil(range.substring(of: source), "\(label) range \(range) does not resolve")
    }
}
