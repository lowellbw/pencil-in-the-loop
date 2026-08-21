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

    // MARK: - One tap

    /// The library's New button passes nothing at all, so the defaults are what
    /// a new note actually is.
    func testANotebookMadeWithNothingSpecifiedIsUsable() async throws {
        let created = try await creator.createNotebook(existingFolderNames: [])

        XCTAssertEqual(created.title, NoteCreator.untitled)
        XCTAssertEqual(created.pageCount, NoteCreator.defaultPageCount)
        XCTAssertEqual(creator.paper(forFolderNamed: created.folderName), NoteCreator.defaultPaper)
        XCTAssertEqual(created.origin.kind, .note)
    }

    /// Untitled is now the ordinary case, so two notes made in one sitting all
    /// want the same folder name.
    func testTwoUntitledNotesInOneDayDoNotCollide() async throws {
        let first = try await creator.createNotebook(existingFolderNames: [])
        let second = try await creator.createNotebook(existingFolderNames: [first.folderName])
        XCTAssertNotEqual(first.folderName, second.folderName)
    }

    // MARK: - Renaming

    /// The store holds what the library shows; `meta.json` holds what survives
    /// a re-ingest. Without the second, a rename comes back undone the next
    /// time somebody adds paper — which is what `addPages` does below.
    func testARenameSurvivesAddingPages() async throws {
        let created = try await creator.createNotebook(existingFolderNames: [])
        creator.rename(to: "Cutover plan", forFolderNamed: created.folderName)

        let grown = try await creator.addPages(
            2, toFolderNamed: created.folderName, currentPageCount: created.pageCount
        )
        XCTAssertEqual(grown.title, "Cutover plan")
        XCTAssertEqual(grown.id, created.id)
        XCTAssertEqual(grown.folderName, created.folderName, "the folder is the identity and does not move")
    }

    func testAnEmptyRenameLeavesTheNameAlone() async throws {
        let created = try await creator.createNotebook(title: "Field notes", existingFolderNames: [])
        creator.rename(to: "   ", forFolderNamed: created.folderName)

        let grown = try await creator.addPages(
            1, toFolderNamed: created.folderName, currentPageCount: created.pageCount
        )
        XCTAssertEqual(grown.title, "Field notes")
    }

    // MARK: - Re-ruling

    func testChangingThePaperKeepsThePagesAndTheIdentity() async throws {
        let created = try await creator.createNotebook(
            title: "Squared", paper: .grid, pages: 3, existingFolderNames: []
        )
        let reruled = try await creator.setPaper(
            .lined, forFolderNamed: created.folderName, pageCount: created.pageCount
        )

        XCTAssertEqual(reruled.pageCount, 3, "re-ruling is not a resize")
        XCTAssertEqual(reruled.id, created.id, "a new id would orphan every stroke on the page")
        XCTAssertEqual(reruled.folderName, created.folderName)
        XCTAssertEqual(creator.paper(forFolderNamed: created.folderName), .lined)
    }

    /// Pages added after a re-ruling match what is on screen now, not what the
    /// notebook was made with.
    func testPagesAddedAfterAReRulingMatchTheNewPaper() async throws {
        let created = try await creator.createNotebook(
            title: "Squared", paper: .grid, pages: 1, existingFolderNames: []
        )
        _ = try await creator.setPaper(
            .plain, forFolderNamed: created.folderName, pageCount: created.pageCount
        )
        _ = try await creator.addPages(
            2, toFolderNamed: created.folderName, currentPageCount: 1
        )
        XCTAssertEqual(creator.paper(forFolderNamed: created.folderName), .plain)
    }

    // MARK: - Growing

    /// Adding paper must not make a different document. Everything downstream
    /// — the ink, the comments, the reading position — is keyed on identity,
    /// and a new id would orphan all of it.
    func testAddingPagesKeepsTheDocumentsIdentity() async throws {
        let created = try await creator.createNotebook(
            title: "Working notes", paper: .grid, pages: 2, existingFolderNames: []
        )
        let grown = try await creator.addPages(
            3, toFolderNamed: created.folderName, currentPageCount: created.pageCount
        )

        XCTAssertEqual(grown.pageCount, 5)
        XCTAssertEqual(grown.folderName, created.folderName)
        XCTAssertEqual(grown.id, created.id, "a new id would orphan every stroke in the notebook")
        XCTAssertEqual(grown.title, created.title)
    }

    /// "You can add more pages later, and they will match" is a promise the
    /// sheet makes in as many words.
    func testAddedPagesAreRuledLikeTheOnesAlreadyThere() async throws {
        let created = try await creator.createNotebook(
            title: "Squared up", paper: .grid, pages: 1, existingFolderNames: []
        )
        _ = try await creator.addPages(
            2, toFolderNamed: created.folderName, currentPageCount: created.pageCount
        )
        XCTAssertEqual(creator.paper(forFolderNamed: created.folderName), .grid)
    }

    func testGrowingRewritesThePDFInPlace() async throws {
        let created = try await creator.createNotebook(
            title: "Longhand", paper: .lined, pages: 2, existingFolderNames: []
        )
        _ = try await creator.addPages(
            4, toFolderNamed: created.folderName, currentPageCount: created.pageCount
        )
        let document = try XCTUnwrap(PDFDocument(url: created.pdfURL))
        XCTAssertEqual(document.pageCount, 6, "the reader opens this exact URL and nothing else")
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
