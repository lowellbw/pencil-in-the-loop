//
//  NoteCreatorTests.swift
//  IngestTests
//
//  Does making a document produce the same thing as receiving one?
//
//  That is the claim the whole feature rests on — a note is not a second kind
//  of document, it is the ordinary pipeline with the bytes written a moment
//  earlier. If what comes out of here differs from what comes out of a scanned
//  inbox directory, then the reader, the ink layer and export are all being
//  asked to handle a case nobody wrote them for.
//
//  These render a PDF, so they need a graphics context: device or Simulator,
//  not `swift test` on a Mac command line.
//

import XCTest
import Foundation
import PDFKit
import Core
@testable import Ingest

final class NoteCreatorTests: XCTestCase {

    private var containerRoot: URL!
    private var creator: NoteCreator!

    override func setUpWithError() throws {
        try super.setUpWithError()
        containerRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: containerRoot, withIntermediateDirectories: true)
        creator = NoteCreator(
            ingestor: DocumentIngestor(containerRoot: containerRoot),
            containerRoot: containerRoot,
            clock: { Date(timeIntervalSince1970: 1_755_000_000) }
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: containerRoot)
        try super.tearDownWithError()
    }

    // MARK: - A notebook

    func testANotebookIngestsAsAnOrdinaryDocument() async throws {
        let created = try await creator.createNotebook(
            title: "Reading notes", paper: .lined, pages: 6, existingFolderNames: []
        )

        XCTAssertEqual(created.title, "Reading notes")
        XCTAssertEqual(created.pageCount, 6)
        XCTAssertEqual(created.sourceFormat, .pdf)
        XCTAssertEqual(created.origin.kind, .note)
        XCTAssertNil(created.sourceMarkdownURL, "blank paper has no source text")
        XCTAssertNil(created.sourceMap, "and therefore no source map, like an imported PDF")
    }

    /// The reader opens `pdfURL` and nothing else. If the bytes are not in the
    /// container under that name the notebook is a row that opens on nothing.
    func testTheNotebooksPagesAreInTheContainer() async throws {
        let created = try await creator.createNotebook(
            title: "Field notes", paper: .grid, pages: 3, existingFolderNames: []
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: created.pdfURL.path))
        let document = try XCTUnwrap(PDFDocument(url: created.pdfURL))
        XCTAssertEqual(document.pageCount, 3)
    }

    func testTheFolderNameGoesThroughSlug() async throws {
        let created = try await creator.createNotebook(
            title: "Reading Notes!", paper: .plain, pages: 1, existingFolderNames: []
        )
        XCTAssertEqual(
            created.folderName,
            Slug.folderName(date: Date(timeIntervalSince1970: 1_755_000_000), title: "Reading Notes!")
        )
    }

    /// Two notebooks called the same thing on the same day is an ordinary
    /// Tuesday, not an error.
    func testASecondNotebookWithTheSameNameIsDisambiguated() async throws {
        let first = try await creator.createNotebook(
            title: "Ideas", paper: .lined, pages: 1, existingFolderNames: []
        )
        let second = try await creator.createNotebook(
            title: "Ideas", paper: .lined, pages: 1, existingFolderNames: [first.folderName]
        )
        XCTAssertNotEqual(first.folderName, second.folderName)
    }

    /// An empty title would produce a row nobody can find again.
    func testAnUntitledNotebookStillGetsAName() async throws {
        let created = try await creator.createNotebook(
            title: "   ", paper: .plain, pages: 1, existingFolderNames: []
        )
        XCTAssertFalse(created.title.trimmingCharacters(in: .whitespaces).isEmpty)
        XCTAssertFalse(created.folderName.hasSuffix("-"))
    }

    // MARK: - The sidecar

    func testThePaperIsRememberedSoLaterPagesCanMatch() async throws {
        let created = try await creator.createNotebook(
            title: "Squared", paper: .grid, pages: 2, existingFolderNames: []
        )
        XCTAssertEqual(creator.paper(forFolderNamed: created.folderName), .grid)
    }

    /// Every document that arrived from somewhere else has no sidecar, and
    /// nothing may require one.
    func testADocumentWithNoSidecarReadsAsPlain() {
        XCTAssertEqual(creator.paper(forFolderNamed: "2026-08-19-something-sent"), .plain)
    }

    // MARK: - A written document

    func testATypedDocumentIsRenderedAndMapped() async throws {
        let created = try await creator.createWrittenDocument(
            title: "Auth refactor",
            markdown: "# Auth refactor\n\nThe token is minted once and reused.\n",
            existingFolderNames: []
        )

        XCTAssertEqual(created.sourceFormat, .markdown)
        XCTAssertEqual(created.origin.kind, .note)
        XCTAssertNotNil(created.sourceMarkdownURL, "the markdown is kept beside the rendering")
        XCTAssertNotNil(created.sourceMap, "a typed note gets quoted anchors, not rect-only ones")
        XCTAssertTrue(created.extractedText.contains("minted once"))
    }

    // MARK: - Refusals

    func testANotebookWithNoPagesIsRefusedBeforeAnythingIsWritten() async throws {
        do {
            _ = try await creator.createNotebook(
                title: "Empty", paper: .plain, pages: 0, existingFolderNames: []
            )
            XCTFail("a notebook with no pages should not be created")
        } catch {
            let contents = try FileManager.default.contentsOfDirectory(
                at: containerRoot, includingPropertiesForKeys: nil
            )
            XCTAssertTrue(contents.isEmpty, "a refused notebook left \(contents.count) directory(ies) behind")
        }
    }
}
