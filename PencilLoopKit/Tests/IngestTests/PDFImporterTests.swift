//
//  PDFImporterTests.swift
//  IngestTests
//
//  The other arrival path: a document that was already a PDF
//  (docs/04-flows.md § F1).
//

import XCTest
import Core
@testable import Ingest

final class PDFImporterTests: XCTestCase {

    private let importer = PDFImporter()

    func testReadsPageCountTextAndTitle() throws {
        let markdown = "# Auth refactor plan\n\nThe migration runs in a single deploy.\n"
        let url = try writeRenderedPDF(from: markdown, named: "sample.pdf")
        defer { try? FileManager.default.removeItem(at: url) }

        let imported = try importer.read(pdfAt: url, folderName: "2026-08-18-sample")
        XCTAssertEqual(imported.pageCount, 1)
        XCTAssertTrue(imported.extractedText.contains("single deploy"))
        XCTAssertEqual(imported.metadataTitle, "Auth refactor plan")
    }

    func testAMissingFileIsUnreadableRatherThanACrash() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("nothing-\(UUID().uuidString).pdf")
        XCTAssertThrowsError(try importer.read(pdfAt: missing, folderName: "2026-08-18-missing")) { error in
            guard case let PencilLoopError.unreadableDocument(folderName, _) = error else {
                return XCTFail("expected unreadableDocument, got \(error)")
            }
            XCTAssertEqual(folderName, "2026-08-18-missing")
        }
    }

    func testRubbishBytesAreUnreadable() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("rubbish-\(UUID().uuidString).pdf")
        try Data("this is not a pdf".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertThrowsError(try importer.read(pdfAt: url, folderName: "2026-08-18-rubbish")) { error in
            guard case PencilLoopError.unreadableDocument = error else {
                return XCTFail("expected unreadableDocument, got \(error)")
            }
        }
    }

    func testTheErrorMessageNamesTheFolderSoTheLibraryRowCanShowIt() {
        let error = PencilLoopError.unreadableDocument(
            folderName: "2026-08-18-broken",
            reason: "The file is not a PDF this device can open."
        )
        XCTAssertTrue(error.message.contains("2026-08-18-broken"))
    }

    // MARK: - Helpers

    private func writeRenderedPDF(from markdown: String, named name: String) throws -> URL {
        let document = try SwiftMarkdownAdapter().parse(markdown)
        let rendered = try MarkdownPDFRenderer().render(document, geometry: .annotationFriendly)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString)-\(name)")
        try rendered.pdfData.write(to: url)
        return url
    }
}
