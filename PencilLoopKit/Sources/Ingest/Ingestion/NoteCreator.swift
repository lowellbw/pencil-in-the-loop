//
//  NoteCreator.swift
//  Ingest · Ingestion
//
//  Making a document instead of receiving one (docs/11-backlog.md § B1).
//
//  Everything in the library until now arrived: scanned out of `inbox/`, pulled
//  from the relay, or handed over by the share sheet. All three converge on an
//  `InboxItem` and then on `DocumentIngestor`. So does this — a note is not a
//  second kind of document, it is the same pipeline with the bytes written
//  locally a moment earlier.
//
//  ─── WHY NOT THROUGH THE SYNC FOLDER ─────────────────────────────────────────
//  `SyncCoordinator.ingestReply` synthesises a document in-process already, and
//  it would have been the obvious thing to copy. It writes into the user's
//  `inbox/` and lets the scanner find it, which is wrong twice here: a note
//  could then only be created when a folder had been adopted — so not on a
//  plane, and not at all on a relay build — and the notebook would be pushed
//  straight back out to whoever is watching that folder. A private notebook is
//  not correspondence. So the staging directory is a temporary one, and the
//  only thing that ever sees it is the ingestor.
//

import Foundation
import Core

/// Creates a blank notebook or a written document and ingests it.
public struct NoteCreator: Sendable {

    private let paperRenderer: BlankPaperRenderer
    private let ingestor: any DocumentIngesting
    private let containerRoot: URL
    private let clock: @Sendable () -> Date

    public init(
        paperRenderer: BlankPaperRenderer = BlankPaperRenderer(),
        ingestor: any DocumentIngesting = DocumentIngestor(),
        containerRoot: URL = DocumentContainer.documentsRoot(),
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.paperRenderer = paperRenderer
        self.ingestor = ingestor
        self.containerRoot = containerRoot
        self.clock = clock
    }

    /// Blank paper, ruled and ready to write on.
    ///
    /// - Parameter existingFolderNames: what the library already holds, so two
    ///   notebooks made on one day with one title get `-2` rather than
    ///   colliding. `DocumentStoring.knownFolderNames()` is the source.
    /// - Throws: `PencilLoopError.renderFailed` if the paper cannot be drawn,
    ///   or whatever `DocumentIngestor` throws. Nothing is left in the library
    ///   on either — the notebook exists once, at the end, or not at all.
    public func createNotebook(
        title: String,
        paper: PaperStyle,
        pages: Int,
        existingFolderNames: Set<String>
    ) async throws -> IngestedDocument {
        let pdf = try paperRenderer.render(pages: pages, paper: paper, geometry: .notebook)

        let created = try await create(
            title: title,
            sourceFormat: .pdf,
            existingFolderNames: existingFolderNames
        ) { staging in
            try pdf.write(to: staging.appendingPathComponent(DocumentFileNames.document))
            return DocumentFileNames.document
        }

        // Written after the document exists, because a sidecar beside a
        // notebook that failed to ingest describes nothing.
        write(NoteSidecar(paper: paper, pageCount: created.pageCount), forFolderNamed: created.folderName)
        return created
    }

    /// A document typed in the app rather than written by hand.
    ///
    /// Only `source.md` is staged, never a PDF — the ingestor renders markdown
    /// itself, and it builds the source map in the same pass. Handing it the
    /// text rather than a rendering is what gives a typed note real quoted
    /// anchors instead of the rect-only ones a blank page falls back to.
    public func createWrittenDocument(
        title: String,
        markdown: String,
        existingFolderNames: Set<String>
    ) async throws -> IngestedDocument {
        try await create(
            title: title,
            sourceFormat: .markdown,
            existingFolderNames: existingFolderNames
        ) { staging in
            let target = staging.appendingPathComponent(DocumentFileNames.sourceMarkdown)
            try Data(markdown.utf8).write(to: target)
            return DocumentFileNames.sourceMarkdown
        }
    }

    /// The paper a notebook was ruled with, or `.plain` when there is no
    /// sidecar to say — see `NoteSidecar`.
    public func paper(forFolderNamed folderName: String) -> PaperStyle {
        let url = containerRoot
            .appendingPathComponent(folderName, isDirectory: true)
            .appendingPathComponent(DocumentFileNames.note)
        guard let data = try? Data(contentsOf: url),
              let sidecar = try? JSONDecoder().decode(NoteSidecar.self, from: data) else {
            return .plain
        }
        return sidecar.paper
    }

    // MARK: - The shared half

    /// Names the document, stages it somewhere temporary, and ingests it.
    ///
    /// `stage` writes the one file the document is made of and returns its
    /// name, which is all this needs to know to describe the directory.
    private func create(
        title: String,
        sourceFormat: SourceFormat,
        existingFolderNames: Set<String>,
        stage: (URL) throws -> String
    ) async throws -> IngestedDocument {
        let now = clock()
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let named = trimmed.isEmpty ? NoteCreator.untitled : trimmed
        let folderName = Slug.disambiguated(
            Slug.folderName(date: now, title: named),
            existing: existingFolderNames
        )

        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("note-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }

        let fileName = try stage(staging)

        let metadata = DocumentMetadata(
            id: UUID().uuidString,
            title: named,
            createdAt: now,
            origin: Origin(kind: .note),
            sourceFormat: sourceFormat
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(metadata)
            .write(to: staging.appendingPathComponent(DocumentFileNames.metadata))

        let file = staging.appendingPathComponent(fileName)
        let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0

        let item = InboxItem(
            folderName: folderName,
            directoryURL: staging,
            pdfURL: fileName == DocumentFileNames.document ? file : nil,
            sourceMarkdownURL: fileName == DocumentFileNames.sourceMarkdown ? file : nil,
            sourceMapURL: nil,
            metaURL: staging.appendingPathComponent(DocumentFileNames.metadata),
            modifiedAt: now,
            byteCount: Int64(size)
        )
        return try await ingestor.ingest(item)
    }

    /// Best effort, and deliberately silent. The notebook is already in the
    /// library by the time this runs; failing to record its ruling costs the
    /// lines on pages added later, and is not worth losing the notebook over.
    private func write(_ sidecar: NoteSidecar, forFolderNamed folderName: String) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(sidecar) else { return }
        let url = containerRoot
            .appendingPathComponent(folderName, isDirectory: true)
            .appendingPathComponent(DocumentFileNames.note)
        try? data.write(to: url)
    }

    /// What an untitled note is called. The library sorts and searches on the
    /// title, so an empty one would produce a row nobody can find again.
    private static let untitled = "Note"
}
