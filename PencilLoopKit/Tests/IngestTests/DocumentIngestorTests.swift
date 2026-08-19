//
//  DocumentIngestorTests.swift
//  IngestTests
//
//  One ingest path (docs/04-flows.md § F1), and the promise that nothing is
//  ever thrown away.
//

import XCTest
import Core
@testable import Ingest

final class DocumentIngestorTests: XCTestCase {

    private var root: URL = FileManager.default.temporaryDirectory
    private var container: URL = FileManager.default.temporaryDirectory

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ingest-\(UUID().uuidString)", isDirectory: true)
        container = root.appendingPathComponent("container", isDirectory: true)
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Markdown

    func testMarkdownIsRenderedPinnedAndMapped() async throws {
        let item = try makeInbox(
            folderName: "2026-08-18-auth-refactor-plan",
            markdown: "# Auth refactor plan\n\nThe migration runs in a single deploy.\n",
            meta: #"{"id":"F7A1","origin":{"kind":"cowork","sessionId":"8f3c1d"}}"#
        )

        let ingested = try await ingestor().ingest(item)

        XCTAssertEqual(ingested.title, "Auth refactor plan")
        XCTAssertEqual(ingested.folderName, "2026-08-18-auth-refactor-plan")
        XCTAssertEqual(ingested.relativePath, "inbox/2026-08-18-auth-refactor-plan")
        XCTAssertEqual(ingested.sourceFormat, .markdown)
        XCTAssertEqual(ingested.origin.kind, .cowork)
        XCTAssertEqual(ingested.externalId, "F7A1")
        XCTAssertTrue(ingested.pageCount > 0)
        XCTAssertTrue(ingested.extractedText.contains("single deploy"))

        // Pinned into the container, not left in the folder.
        XCTAssertTrue(ingested.pdfURL.path.hasPrefix(container.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: ingested.pdfURL.path))
        let markdownURL = try XCTUnwrap(ingested.sourceMarkdownURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: markdownURL.path))

        // sourcemap.json written next to document.pdf.
        let mapURL = container
            .appendingPathComponent("2026-08-18-auth-refactor-plan")
            .appendingPathComponent(DocumentFileNames.sourceMap)
        XCTAssertTrue(FileManager.default.fileExists(atPath: mapURL.path))

        let map = try XCTUnwrap(ingested.sourceMap)
        XCTAssertFalse(map.isEmpty)
        let source = try String(contentsOf: markdownURL, encoding: .utf8)
        for entry in map.entries {
            XCTAssertNotNil(entry.range.substring(of: source))
        }

        // The id is what lets a source map found on its own be matched back to
        // its document, and it is only knowable here — the renderer has never
        // heard of meta.json.
        XCTAssertEqual(map.documentId, "F7A1")
        let written = try ContractCoding.decoder().decode(SourceMap.self, from: Data(contentsOf: mapURL))
        XCTAssertEqual(written.documentId, "F7A1")
    }

    func testMetaTitleBeatsTheMarkdownHeading() async throws {
        let item = try makeInbox(
            folderName: "2026-08-18-plan",
            markdown: "# Heading title\n\nbody\n",
            meta: #"{"title":"Meta title"}"#
        )
        let ingested = try await ingestor().ingest(item)
        XCTAssertEqual(ingested.title, "Meta title")
    }

    func testMalformedMetaJsonNeverBlocksIngest() async throws {
        let item = try makeInbox(
            folderName: "2026-08-18-broken-meta",
            markdown: "# Still fine\n\nbody\n",
            meta: "{ this is not json"
        )
        let ingested = try await ingestor().ingest(item)
        XCTAssertEqual(ingested.title, "Still fine")
        XCTAssertEqual(ingested.origin, .manual)
        XCTAssertNil(ingested.externalId)
    }

    func testMarkdownTheParserRejectsIsStillRendered() async throws {
        let item = try makeInbox(
            folderName: "2026-08-18-refuses",
            markdown: "some text the parser will not have\n",
            meta: nil
        )
        let ingested = try await ingestor(parser: RefusingParser()).ingest(item)
        XCTAssertTrue(ingested.pageCount > 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: ingested.pdfURL.path))
    }

    // MARK: - PDF

    func testAnExistingPdfIsImportedRatherThanRendered() async throws {
        let folderName = "2026-08-18-paper"
        let directory = root.appendingPathComponent("inbox/\(folderName)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let document = try SwiftMarkdownAdapter().parse("# A paper\n\nWith a sentence in it.\n")
        let rendered = try MarkdownPDFRenderer().render(document, geometry: .annotationFriendly)
        let pdfURL = directory.appendingPathComponent(DocumentFileNames.document)
        try rendered.pdfData.write(to: pdfURL)

        let item = InboxItem(
            folderName: folderName,
            directoryURL: directory,
            pdfURL: pdfURL,
            modifiedAt: Date(timeIntervalSince1970: 1_770_000_000)
        )

        let ingested = try await ingestor().ingest(item)
        XCTAssertEqual(ingested.sourceFormat, .pdf)
        XCTAssertEqual(ingested.title, "A paper")
        XCTAssertNil(ingested.sourceMarkdownURL)
        XCTAssertNil(ingested.sourceMap)
        XCTAssertTrue(ingested.extractedText.contains("sentence"))
    }

    // MARK: - Failure

    func testAnEmptyFolderIsNothingToIngest() async throws {
        let directory = root.appendingPathComponent("inbox/2026-08-18-empty", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let item = InboxItem(
            folderName: "2026-08-18-empty",
            directoryURL: directory,
            modifiedAt: Date()
        )

        do {
            _ = try await ingestor().ingest(item)
            XCTFail("expected nothingToIngest")
        } catch let error as PencilLoopError {
            guard case let .nothingToIngest(folderName) = error else {
                return XCTFail("expected nothingToIngest, got \(error)")
            }
            XCTAssertEqual(folderName, "2026-08-18-empty")
        }
    }

    /// A folder holding markdown that is not UTF-8 plainly does contain a
    /// document. Saying it contains none sends the reader looking for a file
    /// that is sitting right there, which is the one thing the error row exists
    /// to prevent (docs/04-flows.md § F1).
    func testMarkdownThatIsNotUtf8IsReportedAsUnreadableRatherThanAbsent() async throws {
        let folderName = "2026-08-18-latin1"
        let directory = root.appendingPathComponent("inbox/\(folderName)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        // A heading, then a byte no UTF-8 sequence can begin with.
        let markdownURL = directory.appendingPathComponent(DocumentFileNames.sourceMarkdown)
        try (Data("# Caf".utf8) + Data([0xE9]) + Data("\n\nbody\n".utf8)).write(to: markdownURL)

        let item = InboxItem(
            folderName: folderName,
            directoryURL: directory,
            sourceMarkdownURL: markdownURL,
            modifiedAt: Date(timeIntervalSince1970: 1_760_000_000)
        )

        do {
            _ = try await ingestor().ingest(item)
            XCTFail("expected unreadableDocument")
        } catch let error as PencilLoopError {
            guard case let .unreadableDocument(reported, reason) = error else {
                return XCTFail("expected unreadableDocument, got \(error)")
            }
            XCTAssertEqual(reported, folderName)
            XCTAssertTrue(reason.contains("UTF-8"), reason)
            XCTAssertFalse(
                error.message.contains("contains no document"),
                "The folder does contain a document; the row must not claim otherwise."
            )
        }

        // And the bytes are still pinned, so nothing was thrown away.
        let pinned = container
            .appendingPathComponent(folderName)
            .appendingPathComponent(DocumentFileNames.sourceMarkdown)
        XCTAssertTrue(FileManager.default.fileExists(atPath: pinned.path))
    }

    func testMetadataAloneNeverThrows() async throws {
        let missing = root.appendingPathComponent("inbox/absent", isDirectory: true)
        let metadata = await ingestor().metadata(at: missing)
        XCTAssertEqual(metadata, .empty)
    }

    func testAddedAtComesFromTheInjectedClock() async throws {
        let moment = Date(timeIntervalSince1970: 1_780_000_000)
        let item = try makeInbox(folderName: "2026-08-18-clock", markdown: "# Clock\n", meta: nil)
        let ingested = try await ingestor(clock: { moment }).ingest(item)
        XCTAssertEqual(ingested.addedAt, moment)
        XCTAssertEqual(ingested.createdAt, item.modifiedAt)
    }

    // MARK: - Helpers

    /// A parser that always fails, standing in for markdown swift-markdown
    /// cannot make sense of.
    private struct RefusingParser: MarkdownParsing {
        func parse(_ markdown: String) throws -> MarkdownDocument {
            throw PencilLoopError.markdownParseFailed(reason: "test")
        }
    }

    private func ingestor(
        parser: any MarkdownParsing = SwiftMarkdownAdapter(),
        clock: @escaping @Sendable () -> Date = { Date(timeIntervalSince1970: 1_790_000_000) }
    ) -> DocumentIngestor {
        DocumentIngestor(containerRoot: container, parser: parser, clock: clock)
    }

    private func makeInbox(
        folderName: String,
        markdown: String,
        meta: String?
    ) throws -> InboxItem {
        let directory = root.appendingPathComponent("inbox/\(folderName)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let markdownURL = directory.appendingPathComponent(DocumentFileNames.sourceMarkdown)
        try Data(markdown.utf8).write(to: markdownURL)

        var metaURL: URL?
        if let meta {
            let url = directory.appendingPathComponent(DocumentFileNames.metadata)
            try Data(meta.utf8).write(to: url)
            metaURL = url
        }

        return InboxItem(
            folderName: folderName,
            directoryURL: directory,
            sourceMarkdownURL: markdownURL,
            metaURL: metaURL,
            modifiedAt: Date(timeIntervalSince1970: 1_760_000_000)
        )
    }
}
