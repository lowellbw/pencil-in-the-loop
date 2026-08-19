//
//  StorageTestFactory.swift
//  StorageTests
//
//  Fixtures shared by the test cases. Nothing here asserts; it exists so that
//  each test says what it is testing rather than how to build a document.
//

import Foundation
import Core
@testable import Storage

/// Builders for the DTOs the store takes in.
enum StorageTestFactory {

    /// A document that looks like something Ingest produced: pinned inside the
    /// app's documents root, one folder per document.
    static func ingested(
        id: UUID = UUID(),
        title: String = "Auth refactor plan",
        folderName: String = "2026-08-18-auth-refactor-plan",
        pageCount: Int = 4,
        extractedText: String = "The refactor replaces the session token with a signed assertion.",
        origin: Origin = Origin(kind: .cowork, sessionId: "session_1", threadTitle: "Q3 platform planning"),
        sourceFormat: SourceFormat = .markdown,
        sourceMap: SourceMap? = nil,
        withMarkdown: Bool = true,
        addedAt: Date = Date(timeIntervalSince1970: 1_770_000_000),
        createdAt: Date = Date(timeIntervalSince1970: 1_769_999_000)
    ) -> IngestedDocument {
        let directory = StorageLocations.documentDirectory(folderName: folderName)
        return IngestedDocument(
            id: id,
            externalId: nil,
            title: title,
            folderName: folderName,
            relativePath: SyncFolder.inboxDirectoryName + "/" + folderName,
            pdfURL: directory.appendingPathComponent("document.pdf"),
            sourceMarkdownURL: withMarkdown ? directory.appendingPathComponent("source.md") : nil,
            sourceMap: sourceMap,
            origin: origin,
            sourceFormat: sourceFormat,
            pageCount: pageCount,
            extractedText: extractedText,
            createdAt: createdAt,
            addedAt: addedAt
        )
    }

    /// An anchor with a rect at a known vertical position, so document order is
    /// testable.
    static func anchor(
        quoted: String = "a signed assertion",
        pageIndex: Int = 0,
        y: Double = 0.25,
        sourceRange: SourceRange? = nil
    ) -> Anchor {
        Anchor(
            quoted: quoted,
            prefix: "replaces the session token with ",
            suffix: " issued at login.",
            pageIndex: pageIndex,
            normalisedRect: NormalisedRect(x: 0.1, y: y, width: 0.6, height: 0.03),
            sourceRange: sourceRange
        )
    }

    /// A comment on its way in.
    static func draft(
        text: String = "Say why this is safer than a refresh token.",
        source: CommentSource = .voice,
        quoted: String = "a signed assertion",
        pageIndex: Int = 0,
        y: Double = 0.25,
        resolvedOnPage: Int? = nil,
        sourceRange: SourceRange? = nil
    ) -> CommentDraft {
        CommentDraft(
            text: text,
            source: source,
            anchor: anchor(quoted: quoted, pageIndex: pageIndex, y: y, sourceRange: sourceRange),
            resolvedOnPage: resolvedOnPage ?? pageIndex
        )
    }

    /// Bytes that stand in for an archived `PKDrawing`. Storage never reads
    /// them, so their shape does not matter — only that they are not empty.
    static func drawingData(_ marker: String = "ink") -> Data {
        Data(marker.utf8)
    }

    /// A store over a fresh in-memory container.
    static func store() throws -> DocumentStore {
        try DocumentStore.inMemory()
    }

    /// Writes a stand-in `document.pdf` into the pinned directory for a folder
    /// name, so a row backed by it really does have bytes on disk.
    ///
    /// The store asks the filesystem whether a document is still readable
    /// (`Document.hasPinnedBytes`), so a test about that question cannot fake
    /// it. Remove the returned directory in a `defer`.
    @discardableResult
    static func pinBytes(forFolderName folderName: String) throws -> URL {
        let directory = StorageLocations.documentDirectory(folderName: folderName)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("%PDF-1.4 pinned".utf8).write(to: directory.appendingPathComponent("document.pdf"))
        return directory
    }
}
