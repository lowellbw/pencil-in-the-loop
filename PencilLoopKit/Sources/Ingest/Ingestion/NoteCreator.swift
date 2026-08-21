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

/// Creates a blank notebook and ingests it, and re-rules or renames one
/// afterwards.
public struct NoteCreator: Sendable {

    /// How many sheets a new notebook starts with.
    ///
    /// Enough to think in without deciding anything: more can be added at any
    /// time, and a blank page costs a few kilobytes. Asking somebody to predict
    /// how much they are about to write is asking the wrong question, which is
    /// why there is no longer a stepper anywhere near this.
    public static let defaultPageCount = 8

    /// What a new notebook is ruled with until somebody says otherwise.
    ///
    /// Lined, because a note is handwriting and handwriting sits on lines. The
    /// ruling is changed from the page itself
    /// (`setPaper(_:forFolderNamed:pageCount:)`), which is where it can be seen
    /// while it is being chosen.
    public static let defaultPaper: PaperStyle = .lined

    /// What an untitled note is called until its first sentence names it.
    ///
    /// The library sorts and searches on the title, so an empty one would
    /// produce a row nobody can find again. AppUI compares against this to know
    /// whether a note has ever been named — see `NoteAutoTitle`.
    public static let untitled = "Note"

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
        title: String = "",
        paper: PaperStyle = NoteCreator.defaultPaper,
        pages: Int = NoteCreator.defaultPageCount,
        existingFolderNames: Set<String>
    ) async throws -> IngestedDocument {
        let pdf = try paperRenderer.render(pages: pages, paper: paper, geometry: .notebook)
        let created = try await create(title: title, pdf: pdf, existingFolderNames: existingFolderNames)

        // Written after the document exists, because a sidecar beside a
        // notebook that failed to ingest describes nothing.
        write(NoteSidecar(paper: paper, pageCount: created.pageCount), forFolderNamed: created.folderName)
        return created
    }

    /// Adds sheets to the end of a notebook, ruled like the ones already in it.
    ///
    /// **Append only, and that is not a simplification.** Ink is stored per
    /// page index, comments anchor to one, and the canvas pool is keyed by one.
    /// Inserting a page anywhere but the end would renumber every stroke and
    /// every anchor in the document after it, silently.
    ///
    /// Regenerating the whole PDF rather than splicing is safe for the same
    /// reason it is cheap: blank pages have no reflow, so the existing pages
    /// come out identical, and `DocumentStore.upsert` deliberately leaves ink,
    /// comments and reading position alone when a source is regenerated.
    ///
    /// - Important: the reader must have closed the document first. This
    ///   overwrites `document.pdf` in place, and PDFKit holds the file open.
    /// - Throws: `PencilLoopError.renderFailed`, or whatever `DocumentIngestor`
    ///   throws. The old PDF is left untouched on either.
    public func addPages(
        _ count: Int,
        toFolderNamed folderName: String,
        currentPageCount: Int
    ) async throws -> IngestedDocument {
        try await regenerate(
            folderName: folderName,
            pages: currentPageCount + count,
            paper: paper(forFolderNamed: folderName)
        )
    }

    /// Re-rules a notebook, keeping the pages it has and everything on them.
    ///
    /// The ruling is printed into `document.pdf` rather than drawn over it —
    /// that is what stops handwriting drifting off the lines at any zoom — so
    /// changing it means rendering the paper again. Blank pages have no reflow,
    /// so the same page count comes out the same size in the same order, and
    /// `DocumentStore.upsert` leaves ink, comments and the reading position
    /// alone when a source is regenerated. A stroke stays exactly where it was
    /// written; only what is under it changes.
    ///
    /// - Important: the reader must have closed the document first. This
    ///   overwrites `document.pdf` in place, and PDFKit holds the file open.
    /// - Throws: `PencilLoopError.renderFailed`, or whatever `DocumentIngestor`
    ///   throws. The old PDF is left untouched on either.
    public func setPaper(
        _ chosen: PaperStyle,
        forFolderNamed folderName: String,
        pageCount: Int
    ) async throws -> IngestedDocument {
        try await regenerate(folderName: folderName, pages: max(1, pageCount), paper: chosen)
    }

    /// Writes a new title into a note's `meta.json`.
    ///
    /// The store holds the title the library shows; this is the copy that
    /// survives a re-ingest, and adding paper to a notebook is a re-ingest —
    /// `regenerate` carries `meta.json` across so the document keeps its id, so
    /// without this a rename would silently come back undone the next time
    /// somebody pressed Add Pages.
    ///
    /// **Best effort and deliberately non-throwing.** The rename has already
    /// happened as far as the user is concerned; a note whose sidecar file
    /// could not be rewritten is a note that may be renamed again later, which
    /// is not worth an error message over.
    ///
    /// - Note: `folderName` is untouched, here and everywhere. It is the
    ///   identity ink, comments and sent reviews are filed under
    ///   (Protocols.swift § DocumentStoring.setTitle).
    public func rename(to title: String, forFolderNamed folderName: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return }
        let url = containerRoot
            .appendingPathComponent(folderName, isDirectory: true)
            .appendingPathComponent(DocumentFileNames.metadata)
        guard let data = try? Data(contentsOf: url),
              var metadata = try? ContractCoding.decoder().decode(DocumentMetadata.self, from: data)
        else { return }
        metadata.title = trimmed
        guard let rewritten = try? ContractCoding.encoder().encode(metadata) else { return }
        try? rewritten.write(to: url)
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

    /// Names the notebook, stages its PDF somewhere temporary, and ingests it.
    private func create(
        title: String,
        pdf: Data,
        existingFolderNames: Set<String>
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

        let file = staging.appendingPathComponent(DocumentFileNames.document)
        try pdf.write(to: file)

        let metadata = DocumentMetadata(
            id: UUID().uuidString,
            title: named,
            createdAt: now,
            origin: Origin(kind: .note),
            sourceFormat: .pdf
        )
        let metadataBytes = try ContractCoding.encoder().encode(metadata)
        try metadataBytes.write(to: staging.appendingPathComponent(DocumentFileNames.metadata))

        let item = InboxItem(
            folderName: folderName,
            directoryURL: staging,
            pdfURL: file,
            sourceMarkdownURL: nil,
            sourceMapURL: nil,
            metaURL: staging.appendingPathComponent(DocumentFileNames.metadata),
            modifiedAt: now,
            byteCount: Int64(pdf.count)
        )
        let created = try await ingestor.ingest(item)

        // `DocumentIngestor` reads meta.json but does not copy it: for a
        // document that arrived, `InboxItemPinner` has already put it in the
        // container. A note has no pinner, so without this the directory has
        // no meta.json at all — and re-ingesting it later, which is what
        // adding pages and re-ruling do, would mint a fresh id and orphan every
        // stroke.
        write(metadataBytes, named: DocumentFileNames.metadata, forFolderNamed: created.folderName)
        return created
    }

    /// Renders the notebook's paper again and re-ingests it in place.
    ///
    /// The one route by which a notebook's pages change, whether more are being
    /// added or the ruling under them is being swapped. Both are the same three
    /// steps — render, carry `meta.json` across, ingest — and having written
    /// them twice would be two chances to forget the second one, which is the
    /// step that keeps the document's id and therefore every stroke on it.
    private func regenerate(
        folderName: String,
        pages: Int,
        paper: PaperStyle
    ) async throws -> IngestedDocument {
        let pdf = try paperRenderer.render(pages: pages, paper: paper, geometry: .notebook)

        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("note-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }

        try pdf.write(to: staging.appendingPathComponent(DocumentFileNames.document))

        // The existing meta.json is carried across rather than rewritten, so
        // the document keeps its id, its title and the date it was started.
        // Minting a new one here would look like a different document to
        // everything downstream.
        let directory = containerRoot.appendingPathComponent(folderName, isDirectory: true)
        let metaURL = staging.appendingPathComponent(DocumentFileNames.metadata)
        let existingMeta = directory.appendingPathComponent(DocumentFileNames.metadata)
        if let data = try? Data(contentsOf: existingMeta) {
            try data.write(to: metaURL)
        }

        let item = InboxItem(
            folderName: folderName,
            directoryURL: staging,
            pdfURL: staging.appendingPathComponent(DocumentFileNames.document),
            sourceMarkdownURL: nil,
            sourceMapURL: nil,
            metaURL: metaURL,
            modifiedAt: clock(),
            byteCount: Int64(pdf.count)
        )
        let rebuilt = try await ingestor.ingest(item)
        write(NoteSidecar(paper: paper, pageCount: rebuilt.pageCount), forFolderNamed: folderName)
        return rebuilt
    }

    /// Best effort, and deliberately silent. The notebook is already in the
    /// library by the time this runs; failing to record its ruling costs the
    /// lines on pages added later, and is not worth losing the notebook over.
    private func write(_ sidecar: NoteSidecar, forFolderNamed folderName: String) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(sidecar) else { return }
        write(data, named: DocumentFileNames.note, forFolderNamed: folderName)
    }

    /// Puts one file in the document's directory in the container, if it can.
    private func write(_ data: Data, named name: String, forFolderNamed folderName: String) {
        let url = containerRoot
            .appendingPathComponent(folderName, isDirectory: true)
            .appendingPathComponent(name)
        try? data.write(to: url)
    }
}
