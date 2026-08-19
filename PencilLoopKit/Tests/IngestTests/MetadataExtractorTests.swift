//
//  MetadataExtractorTests.swift
//  IngestTests
//
//  Title precedence is a frozen order (DocumentMetadata.swift § title,
//  docs/02-spec.md § S1). The term-list tests moved out with the term list
//  itself; the one implementation lives in Annotate and is covered by
//  Tests/AnnotateTests/Speech/TermListCorrectorTests.swift.
//

import XCTest
import Core
@testable import Ingest

final class MetadataExtractorTests: XCTestCase {

    private let extractor = MetadataExtractor()

    // MARK: - Title precedence

    func testMetadataTitleWinsOverEverything() {
        let title = extractor.title(
            metadataTitle: "From meta",
            pdfTitle: "From PDF",
            markdownTitle: "From H1",
            fileName: "2026-08-18-from-filename"
        )
        XCTAssertEqual(title, "From meta")
    }

    func testPdfTitleWinsOverMarkdownAndFilename() {
        let title = extractor.title(
            metadataTitle: nil,
            pdfTitle: "From PDF",
            markdownTitle: "From H1",
            fileName: "2026-08-18-from-filename"
        )
        XCTAssertEqual(title, "From PDF")
    }

    func testMarkdownHeadingWinsOverFilename() {
        let title = extractor.title(
            metadataTitle: nil,
            pdfTitle: nil,
            markdownTitle: "From H1",
            fileName: "2026-08-18-from-filename"
        )
        XCTAssertEqual(title, "From H1")
    }

    func testFilenameIsTheLastResort() {
        let title = extractor.title(
            metadataTitle: nil,
            pdfTitle: nil,
            markdownTitle: nil,
            fileName: "2026-08-18-auth-refactor-plan"
        )
        XCTAssertEqual(title, "Auth refactor plan")
    }

    func testBlankCandidatesAreSkippedRatherThanWinning() {
        let title = extractor.title(
            metadataTitle: "   ",
            pdfTitle: "",
            markdownTitle: "\n",
            fileName: "notes.pdf"
        )
        XCTAssertEqual(title, "Notes")
    }

    func testThereIsAlwaysATitle() {
        XCTAssertEqual(
            extractor.title(metadataTitle: nil, pdfTitle: nil, markdownTitle: nil, fileName: ""),
            "Document"
        )
    }

    func testReadableNameStripsTheDatePrefixAndTheExtension() {
        XCTAssertEqual(extractor.readableName(fromFileName: "2026-08-18-q3-plan"), "Q3 plan")
        XCTAssertEqual(extractor.readableName(fromFileName: "auth_refactor_plan.pdf"), "Auth refactor plan")
        XCTAssertEqual(extractor.readableName(fromFileName: "paper.v2.pdf"), "Paper.v2")
    }

    // MARK: - meta.json

    func testMetaJsonDecodes() throws {
        let json = """
        {
          "id": "F7A1",
          "title": "Auth refactor plan",
          "createdAt": "2026-08-18T18:22:04Z",
          "origin": { "kind": "cowork", "sessionId": "8f3c1d" },
          "sourceFormat": "markdown",
          "pageCount": 4
        }
        """
        let metadata = extractor.metadata(fromMetaJSON: try XCTUnwrap(json.data(using: .utf8)))
        XCTAssertEqual(metadata.title, "Auth refactor plan")
        XCTAssertEqual(metadata.id, "F7A1")
        XCTAssertNil(metadata.uuid)
        XCTAssertEqual(metadata.origin?.kind, .cowork)
        XCTAssertEqual(metadata.sourceFormat, .markdown)
        XCTAssertEqual(metadata.pageCount, 4)
    }

    func testMalformedMetaJsonNeverBlocksIngest() throws {
        let broken = try XCTUnwrap("{\"title\": ".data(using: .utf8))
        XCTAssertEqual(extractor.metadata(fromMetaJSON: broken), .empty)
        XCTAssertEqual(extractor.metadata(fromMetaJSON: Data()), .empty)
        XCTAssertEqual(extractor.metadata(fromMetaJSON: broken).resolvedOrigin, .manual)
    }

    func testWrongTypesAreDroppedFieldByField() throws {
        let json = try XCTUnwrap(#"{"title": 42, "pageCount": "four", "origin": "cowork"}"#.data(using: .utf8))
        let metadata = extractor.metadata(fromMetaJSON: json)
        XCTAssertNil(metadata.title)
        XCTAssertNil(metadata.pageCount)
        XCTAssertEqual(metadata.resolvedOrigin, .manual)
    }

    // MARK: - Page count

    func testMeasuredPageCountBeatsTheClaim() {
        XCTAssertEqual(extractor.pageCount(measured: 7, claimed: 4), 7)
        XCTAssertEqual(extractor.pageCount(measured: 0, claimed: 4), 4)
        XCTAssertEqual(extractor.pageCount(measured: 0, claimed: nil), 0)
    }
}
