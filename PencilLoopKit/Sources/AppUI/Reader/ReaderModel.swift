//
//  ReaderModel.swift
//  AppUI · Reader
//
//  Everything the reader knows that is not a view: the document, the ink stack,
//  the comment capture, the chrome, the reading position and the reading clock.
//
//  It exists so that the SwiftUI view can be rebuilt as often as SwiftUI likes
//  without any of that being rebuilt with it. The canvas pool in particular must
//  outlive every view update: it owns the debounced ink that has not reached
//  disk yet, and a pool rebuilt mid-scroll is a pool that has forgotten the
//  strokes the reader made half a second ago.
//

import Foundation
import Observation
import PDFKit
import UIKit
import Annotate
import Core
import Ingest

/// The reader's state, one document at a time.
///
/// **Isolation.** Main actor, like everything in AppUI. It awaits into the
/// store, the settings and the ink coordinator; none of them are main-actor and
/// none of them are awaited on a touch path.
///
/// **On failure:** opening a document that is missing, has no file, or will not
/// parse sets `unavailableMessage` and leaves `isReady` false. The reader shows
/// that sentence instead of a page. Nothing here throws at a view, and nothing
/// shows a spinner waiting on anything (CLAUDE.md non-negotiable 1).
@Observable
public final class ReaderModel {

    // MARK: - What the views read

    /// The open document, once the store has answered.
    public private(set) var detail: DocumentDetail?

    /// The parsed PDF. Nil until it is open, and for a row that has no file.
    public private(set) var document: PDFDocument?

    /// Comment capture for this document: the Pencil gestures, the popover and
    /// the markers all hang off it. Nil until a document is open.
    public private(set) var capture: CommentCaptureModel?

    /// User-facing sentence for a document that cannot be shown, or nil.
    public private(set) var unavailableMessage: String?

    /// True once the document and the ink stack are both open.
    ///
    /// The PDF view is not built before this. PDFKit asks for overlays as soon
    /// as it has a document, and an overlay asked for before
    /// `PageCanvasPool.open(documentId:pages:)` has returned is a canvas that
    /// draws strokes and then discards them
    /// (Annotate/Ink/PageCanvasPool.swift).
    public private(set) var isReady = false

    /// Whether the toolbar is showing. Auto-hides on scroll, returns on tap
    /// (docs/01-design-principles.md § 4).
    public private(set) var isChromeVisible = true

    /// Whether the tool picker is up. Never pinned, never visible until
    /// summoned (docs/01-design-principles.md § Specific choices).
    public private(set) var isToolPickerVisible = false

    /// The page wash, read from `AppSettings` when the document opens and
    /// changed from the page itself (`setPageTint(_:environment:)`).
    public private(set) var pageTint: PageTint = .none

    /// What a notebook's pages are ruled with, or `.plain` for anything that
    /// did not come from `NoteCreator`. Only meaningful when `canAddPages`.
    public private(set) var paper: PaperStyle = .plain

    /// Zero-based page the reader is on: restored on open, persisted as it
    /// changes.
    public private(set) var currentPageIndex = 0

    /// Bumped whenever the pages have moved on screen, so the marker layer
    /// redraws and nothing else does. Reading it in a view is what subscribes
    /// that view to scrolling; no other view should.
    public private(set) var geometryRevision = 0

    /// How many comments the toolbar counts.
    public var commentCount: Int {
        self.capture?.comments.count ?? self.detail?.comments.count ?? 0
    }

    // MARK: - What the views do not read

    /// The ink stack. Public so the overlay provider can reach it; created once
    /// per document and never rebuilt while one is open.
    public private(set) var canvasPool: PageCanvasPool?

    /// The reader's half of the comment seam
    /// (Comment/Seam/CommentPageResolving.swift). One per model, reused across
    /// documents — it holds no document state, only the view and the canvases.
    public let pageResolver = ReaderPageResolver()

    /// The document currently open, if any.
    public private(set) var documentId: UUID?

    /// Called when something the library shows about this document has changed:
    /// a comment saved, deleted or restored, and the ink flushed when the reader
    /// closes or the scene goes away.
    ///
    /// The reader does not write `.reviewing` itself and must not — see
    /// § Annotation below — but the sidebar sits beside it in the split view and
    /// nothing else tells it to look again (`LibraryReloadSignal`).
    public var onDocumentChanged: (() -> Void)?

    private var environment: (any AppEnvironment)?
    private var toolPicker: InkToolPickerController?
    private var sessionStartedAt: Date?
    private var pageWriteTask: Task<Void, Never>?
    private var settingsWriteTask: Task<Void, Never>?

    public init() {}

    // MARK: - Opening and closing

    /// Loads a document, its ink stack and its comment capture.
    ///
    /// One store round trip for everything the reader needs
    /// (Core/Contracts/DTOs.swift, `DocumentDetail`), then one settings read,
    /// then the pool. Cold launch to a readable page has a one-second budget
    /// (docs/03-architecture.md § Performance targets) and this is the whole of
    /// what spends it.
    public func open(documentId newDocumentId: UUID, environment newEnvironment: any AppEnvironment) async {
        guard self.documentId != newDocumentId else { return }
        await self.closeCurrent()

        // `documentId` is the claim on this model, and every step below rechecks
        // it after an await. SwiftUI cancels a `.task(id:)` when the id changes
        // but does not wait for it to unwind, so a reader switched from one
        // document to another has an old open and a new open in flight at once.
        // Whoever holds the claim wins; the other tears its own work down.
        self.documentId = newDocumentId
        self.environment = newEnvironment
        self.unavailableMessage = nil

        let loaded: DocumentDetail?
        do {
            loaded = try await newEnvironment.store.detail(id: newDocumentId)
        } catch {
            ReaderLog.reader.error("The library could not be read for a document the reader was asked to open.")
            self.unavailableMessage = "This document could not be opened."
            return
        }
        guard self.documentId == newDocumentId else { return }

        guard let detail = loaded else {
            self.unavailableMessage = "This document is no longer in the library."
            return
        }
        self.detail = detail
        self.currentPageIndex = ReaderModel.clamp(detail.lastReadPage, pageCount: detail.pageCount)
        self.paper = detail.origin.kind == .note
            ? NoteCreator().paper(forFolderNamed: detail.folderName)
            : .plain

        let settings = await newEnvironment.settings.settings
        guard self.documentId == newDocumentId else { return }
        self.pageTint = settings.pageTint

        // A folder that was seen and could not be ingested has a library row, an
        // error to show, and no bytes (Core/Contracts/DTOs.swift,
        // `DocumentDetail.pdfURL`).
        guard let url = detail.pdfURL else {
            self.unavailableMessage = "This document arrived without a file. Its folder could not be read when it was imported."
            return
        }
        guard let document = PDFDocument(url: url) else {
            self.unavailableMessage = "This document could not be opened. The file may be damaged."
            return
        }

        // `document` is deliberately *not* published yet. Publishing it makes
        // SwiftUI re-render, which hands the document to PDFKit, which asks for
        // a page overlay straight away — and the ink pool below is opened with
        // an `await`, so it would not exist yet. The overlay provider would
        // return nil for every page, and **PDFKit never asks a second time**:
        // the reader would show the document with no canvas over it and the
        // Pencil would mark nothing, silently, for ever.
        //
        // So the pool is built first and everything is published together at
        // the end. The cost is that the page appears a few milliseconds later;
        // the alternative is an app whose entire purpose does not work.
        let coordinator = InkPersistenceCoordinator(
            store: newEnvironment.store,
            recogniser: newEnvironment.recogniser
        )
        let picker = InkToolPickerController(defaults: settings.ink)
        let pool = PageCanvasPool(coordinator: coordinator, toolPicker: picker, defaults: settings.ink)
        picker.onDefaultsChange = { [weak self] defaults in
            self?.applyInkDefaults(defaults)
        }
        await pool.open(documentId: newDocumentId, pages: detail.pages)
        guard self.documentId == newDocumentId else {
            // Someone else opened a document while this one was starting. This
            // pool has strokes nobody will ever make on it, but closing it
            // rather than dropping it is what keeps the ink coordinator's
            // bookkeeping honest.
            await pool.close()
            return
        }

        let capture = CommentCaptureModel(
            environment: newEnvironment,
            detail: detail,
            resolver: self.pageResolver
        )
        capture.onCommentsChanged = { [weak self] in
            self?.onDocumentChanged?()
        }
        self.capture = capture
        self.toolPicker = picker
        self.canvasPool = pool

        // Last, and after the pool: this is what provokes the layout that asks
        // for the overlays.
        self.document = document
        self.sessionStartedAt = Date()
        self.isReady = true
    }

    /// Writes everything outstanding and lets go of the document.
    ///
    /// Ink first: `PageCanvasPool.close()` flushes the debounce, and a stroke
    /// made in the last 500ms exists only in the coordinator until it does.
    public func close() async {
        await self.closeCurrent()
    }

    /// Adds sheets to the end of a notebook and reopens it on the same page.
    ///
    /// **The order here is the whole of it.** PDFKit holds `document.pdf` open,
    /// so the reader closes first — which also flushes the debounced ink and
    /// the reading position — then the file is rewritten, then it reopens.
    /// Rewriting underneath a live `PDFDocument` is how you get a reader
    /// showing pages that no longer exist.
    ///
    /// Reopening rather than growing in place is deliberate. `synchronise(_:)`
    /// hands PDFKit a document exactly once and the overlay provider is asked
    /// exactly once per page; that seam has already produced two silent
    /// no-ink bugs, and a feature that adds paper is not worth risking the one
    /// that lets you write on it. `restoreReadingPosition` puts the reader back
    /// where it was.
    ///
    /// - Note: only a notebook can grow. There is no sensible meaning to
    ///   appending blank paper to a paper somebody sent you.
    public func addPages(_ count: Int, environment: any AppEnvironment) async {
        guard let growing = self.documentId, let detail = self.detail,
              detail.origin.kind == .note else { return }
        let folderName = detail.folderName
        let currentPageCount = detail.pageCount

        await self.closeCurrent()
        do {
            let grown = try await NoteCreator().addPages(
                count, toFolderNamed: folderName, currentPageCount: currentPageCount
            )
            _ = try await environment.store.upsert(grown)
            self.onDocumentChanged?()
        } catch {
            // The notebook is exactly as it was, so reopening below puts the
            // reader back on it rather than leaving an empty detail column.
            self.unavailableMessage = SyncFolderChoice.describe(error)
        }
        await self.open(documentId: growing, environment: environment)
    }

    /// Whether this document is one the app wrote and can therefore extend or
    /// re-rule.
    public var canAddPages: Bool {
        detail?.origin.kind == .note && isReady
    }

    /// Re-rules the open notebook and reopens it on the same page.
    ///
    /// The same order, and the same reasons, as `addPages(_:environment:)`:
    /// PDFKit holds `document.pdf` open, so the reader closes first — which
    /// flushes the debounced ink and the reading position — then the paper is
    /// rendered again, then it reopens. Ink, comments and the reading position
    /// survive, because the page count has not changed and `upsert` leaves them
    /// alone when a source is regenerated (`NoteCreator.setPaper`).
    public func setPaper(_ chosen: PaperStyle, environment: any AppEnvironment) async {
        guard let changing = self.documentId, let detail = self.detail,
              detail.origin.kind == .note, chosen != self.paper else { return }
        let folderName = detail.folderName
        let pageCount = detail.pageCount

        await self.closeCurrent()
        do {
            let reruled = try await NoteCreator().setPaper(
                chosen, forFolderNamed: folderName, pageCount: pageCount
            )
            _ = try await environment.store.upsert(reruled)
            self.onDocumentChanged?()
        } catch {
            // The notebook is exactly as it was, so reopening below puts the
            // reader back on it with the old ruling rather than nothing.
            self.unavailableMessage = SyncFolderChoice.describe(error)
        }
        await self.open(documentId: changing, environment: environment)
    }

    /// Changes the page wash from the page it washes.
    ///
    /// Written through to `AppSettings` because the tint is a reading
    /// preference rather than a property of one document — the next document
    /// opens the way this one looks. It is set here, in the reader, because
    /// this is the only screen where the difference between Cream and Sepia is
    /// visible while it is being chosen.
    public func setPageTint(_ chosen: PageTint, environment: any AppEnvironment) async {
        guard chosen != self.pageTint else { return }
        self.pageTint = chosen
        var settings = await environment.settings.settings
        settings.pageTint = chosen
        do {
            try await environment.settings.update(settings)
        } catch {
            ReaderLog.reader.error("The page tint could not be saved; it holds for this session.")
        }
    }

    /// Renames the open document.
    ///
    /// Two writes, and both are needed. The store holds what the library shows;
    /// `meta.json` holds what survives a re-ingest, and adding a page to a
    /// notebook is a re-ingest — so a rename recorded in the store alone comes
    /// back undone the next time somebody presses Add Pages
    /// (Protocols.swift § DocumentStoring.setTitle).
    ///
    /// The folder name never changes. It is the identity every stroke, comment
    /// and sent review is filed under.
    ///
    /// Any document can be renamed, not only a note — the field is the same
    /// field. A document that is later *re-sent* arrives with its sender's
    /// title again, because the sender's `meta.json` is the one that lands in
    /// `inbox/`, and that is right: the rename was local and the document has
    /// moved on.
    ///
    /// - Parameter title: whatever is in the field. Empty or whitespace is
    ///   ignored rather than refused: a document with no name is a row nobody
    ///   can find again, and the old name is a better answer than an error.
    public func rename(to title: String, environment: any AppEnvironment) async {
        guard let documentId = self.documentId, var detail = self.detail else { return }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false, trimmed != detail.title else { return }
        do {
            try await environment.store.setTitle(trimmed, documentId: documentId)
        } catch {
            ReaderLog.reader.error("This document could not be renamed.")
            return
        }
        NoteCreator().rename(to: trimmed, forFolderNamed: detail.folderName)
        detail.title = trimmed
        self.detail = detail
        self.onDocumentChanged?()
    }

    private func closeCurrent() async {
        guard let closing = self.documentId else { return }
        let pool = self.canvasPool
        let capture = self.capture

        self.pageWriteTask?.cancel()
        self.settingsWriteTask?.cancel()
        self.hideToolPicker()
        capture?.detach()

        await self.flushReadingTime()
        await self.writeLastReadPage()
        if let pool {
            await pool.close()
            // The debounced ink has only now reached the store, and the first
            // stroke on a document is what `markAnnotated` promoted it on.
            // Nothing else tells the sidebar (§ Annotation).
            self.onDocumentChanged?()
        }
        // A newer document has taken the model over; everything below would
        // dismantle its state rather than this one's.
        guard self.documentId == closing else { return }

        await self.nameIfUnnamed()
        guard self.documentId == closing else { return }

        self.pageResolver.forgetOverlays()
        self.canvasPool = nil
        self.toolPicker = nil
        self.capture = nil
        self.document = nil
        self.detail = nil
        self.isReady = false

        // Last, and load-bearing: `open(documentId:environment:)` returns early
        // for the document it already has, and a reader that is closed and
        // reopened — back to the library and straight in again — asks for the
        // same one. Leaving this set is a blank page on the second open.
        self.documentId = nil
    }

    /// Names an untitled note after the first sentence written in it.
    ///
    /// Runs when the note is closed, which is the moment the ink has been
    /// flushed and the recogniser has had the whole session to read page one.
    ///
    /// **Silent, best-effort, and never in anybody's way.** A note with no
    /// recognised handwriting — no recogniser in this build, a page of
    /// diagrams, a recogniser that declined — keeps the name it has, and the
    /// rename in the page's own menu is the answer to all of those. A note
    /// somebody has already named is never touched
    /// (`NoteAutoTitle.isUnnamed(_:untitled:)`).
    private func nameIfUnnamed() async {
        guard let environment = self.environment,
              let documentId = self.documentId,
              let detail = self.detail,
              detail.origin.kind == .note,
              NoteAutoTitle.isUnnamed(detail.title, untitled: NoteCreator.untitled) else { return }

        // Read back rather than taken from `detail`: recognition runs off the
        // main actor while the note is open and writes straight to the store,
        // so the copy the reader loaded on open never has it.
        guard let pages = try? await environment.store.pages(documentId: documentId) else { return }
        let recognised = pages
            .sorted { $0.pageIndex < $1.pageIndex }
            .compactMap(\.recognisedInk)
            .first { $0.isEmpty == false }
        guard let recognised, let title = NoteAutoTitle.title(fromRecognisedInk: recognised) else { return }

        try? await environment.store.setTitle(title, documentId: documentId)
        NoteCreator().rename(to: title, forFolderNamed: detail.folderName)
        self.onDocumentChanged?()
    }

    /// Accumulates reading time until the calling task is cancelled.
    ///
    /// A loop rather than a timer, and a minute rather than a second: the store
    /// coalesces (Core/Contracts/Protocols.swift,
    /// `addReadingSeconds(_:documentId:)`) but a write a second would still be a
    /// write a second, and the number is only ever read back as "12 minutes" in
    /// the review sheet.
    public func trackReadingTime() async {
        while !Task.isCancelled {
            do {
                try await Task.sleep(for: .seconds(60))
            } catch {
                return
            }
            await self.flushReadingTime()
        }
    }

    // MARK: - Chrome

    /// Tap anywhere on the page: chrome comes back, or goes away again.
    public func toggleChrome() {
        self.isChromeVisible.toggle()
    }

    /// The reader started scrolling. Chrome hides, exactly like Books
    /// (docs/01-design-principles.md § 4).
    public func noteScrollActivity() {
        guard self.isChromeVisible else { return }
        self.isChromeVisible = false
    }

    /// Puts the chrome back, for a caller that has just shown something over
    /// the page and wants the toolbar with it.
    public func showChrome() {
        self.isChromeVisible = true
    }

    /// The pages have moved. Cheap by design: one integer, read by the marker
    /// layer and by nothing else.
    public func noteGeometryChanged() {
        self.geometryRevision &+= 1
    }

    // MARK: - The tool picker

    /// Summons the picker, or puts it away. The toolbar button's whole job.
    public func toggleToolPicker() {
        guard let picker = self.toolPicker, let responder = self.toolPickerResponder() else {
            ReaderLog.reader.error("The tool picker was asked for before the reader had a view to attach it to.")
            return
        }
        picker.toggle(for: responder)
        self.isToolPickerVisible = picker.isVisible
    }

    private func hideToolPicker() {
        guard let picker = self.toolPicker, let responder = self.toolPickerResponder() else { return }
        picker.setVisible(false, for: responder)
        self.isToolPickerVisible = false
    }

    /// The PDF view is the right responder: it outlives every page, so the
    /// picker does not vanish when a canvas recycles
    /// (Annotate/Ink/InkToolPickerController.swift). A canvas is the fallback
    /// for the case where it will not take first responder, since
    /// `PKCanvasView` always will.
    private func toolPickerResponder() -> UIResponder? {
        if let view = self.pageResolver.view, view.canBecomeFirstResponder {
            return view
        }
        return self.pageResolver.anyCanvas
    }

    private func applyInkDefaults(_ defaults: InkDefaults) {
        self.canvasPool?.applyDefaults(defaults)
        guard let environment = self.environment else { return }

        // The picker fires on every width nudge. Settling first turns a drag
        // along the width slider into one write instead of forty.
        self.settingsWriteTask?.cancel()
        self.settingsWriteTask = Task {
            do {
                try await Task.sleep(for: .seconds(0.5))
            } catch {
                return
            }
            var settings = await environment.settings.settings
            settings.ink = defaults
            do {
                try await environment.settings.update(settings)
            } catch {
                ReaderLog.reader.error("The chosen ink could not be saved; it stays selected for this session.")
            }
        }
    }

    // MARK: - Reading position

    /// The reader scrolled onto another page.
    public func notePageChanged(_ index: Int) {
        guard index != self.currentPageIndex, index >= 0 else { return }
        self.currentPageIndex = index
        self.pageWriteTask?.cancel()
        self.pageWriteTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(1.5))
            } catch {
                return
            }
            await self?.writeLastReadPage()
        }
    }

    private func writeLastReadPage() async {
        guard let environment = self.environment, let documentId = self.documentId else { return }
        do {
            try await environment.store.setLastReadPage(self.currentPageIndex, documentId: documentId)
        } catch {
            ReaderLog.reader.error("The reading position could not be saved; the document reopens where it last saved.")
        }
    }

    // MARK: - Reading time

    /// The scene became active, or stopped being active. The clock only runs
    /// while the reader is in front of someone, and the ink is flushed on the
    /// way out — `InkLifecycleObserver` does the same from the notification
    /// side, and flushing twice finds nothing the second time.
    public func noteActive(_ isActive: Bool) async {
        if isActive {
            self.sessionStartedAt = Date()
            return
        }
        await self.flushReadingTime()
        self.sessionStartedAt = nil
        if let pool = self.canvasPool {
            await pool.flush()
            self.onDocumentChanged?()
        }
    }

    private func flushReadingTime() async {
        guard let startedAt = self.sessionStartedAt,
              let environment = self.environment,
              let documentId = self.documentId else { return }
        let now = Date()
        let seconds = now.timeIntervalSince(startedAt)
        self.sessionStartedAt = now
        guard seconds > 0 else { return }
        do {
            try await environment.store.addReadingSeconds(seconds, documentId: documentId)
        } catch {
            ReaderLog.reader.error("Reading time could not be recorded for this document.")
        }
    }

    // MARK: - Annotation

    // ─── `.unread → .reviewing` IS NOT DONE HERE ─────────────────────────────
    // The reader used to promote the document itself: it polled
    // `DocumentSummary.hasInk` and the comment count on every reading-time tick,
    // on backgrounding and on close, and wrote `.reviewing` when it saw one.
    //
    // Storage already does it, at the only moment that cannot be missed or
    // raced — inside the write. `DocumentStore.addComment(_:documentId:)` and
    // `saveDrawing(_:pageIndex:documentId:)` both call `markAnnotated`, which
    // is "on the first annotation, never on open" (docs/04-flows.md § F2)
    // stated once. So the reader's copy was a second writer of the same rule,
    // reached by polling, and two writers on document state is worse than one
    // wherever they happen to agree today. The comment unit had a third and
    // removed it for the same reason.
    //
    // Nothing is lost by the reader not knowing — but something had to make the
    // library look again, and nothing did: `markAnnotated` emits no `SyncEvent`
    // and `LibraryModel.load()` had no trigger for it, so in the split view a
    // document annotated beside the sidebar stayed under "Unread" for the rest
    // of the session. `onDocumentChanged` is that trigger and only that: it
    // says "the store has moved", never what it moved to. The review sheet is
    // handed a fresh `DocumentDetail` when it opens and needs no telling.
    // ─────────────────────────────────────────────────────────────────────────

    // MARK: - Support

    private static func clamp(_ pageIndex: Int, pageCount: Int) -> Int {
        guard pageCount > 0 else { return 0 }
        return min(max(pageIndex, 0), pageCount - 1)
    }
}
