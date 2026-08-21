//
//  DocumentStore.swift
//  Storage · Store
//
//  The library, as everyone outside Storage sees it: the one implementation of
//  `DocumentStoring` (Core/Contracts/Protocols.swift).
//
//  ─── THE RULE THIS FILE EXISTS TO KEEP ───────────────────────────────────────
//  No `@Model` instance leaves this actor. `Document`, `Page` and `Comment` are
//  internal to the module and every member below returns a value type from
//  Core/Contracts/DTOs.swift. If a future member wants to hand back a model,
//  what it actually wants is another DTO, and that is a change request to the
//  lead (STYLE.md § 1 and § 6).
//  ─────────────────────────────────────────────────────────────────────────────
//
//  `@ModelActor` gives the actor its own `ModelContext` and a serial executor to
//  run it on, which is what makes "a ModelContext is not thread-safe" a
//  non-issue rather than a race to find later.
//

import Foundation
import SwiftData
import Core

/// The SwiftData-backed library.
///
/// **On failure:** throws `PencilLoopError.documentNotFound`,
/// `.commentNotFound` or `.storeWriteFailed`, exactly as `DocumentStoring`
/// documents. Reads of a missing document return nil; writes to one throw.
///
/// **Construction:** use `DocumentStore.live()` in the app,
/// `DocumentStore.inMemory()` in tests and previews, or
/// `DocumentStore.make(container:)` when the container already exists. One store
/// per container is enough — the actor serialises everything.
@ModelActor
public actor DocumentStore: DocumentStoring {

    /// Comments soft-deleted during this process, newest last.
    ///
    /// The stack is deliberately in memory: "deleting a comment is undoable for
    /// the session" (docs/02-spec.md § Cross-cutting), and a session ends when
    /// the process does. The rows themselves are marked with `deletedAt` rather
    /// than removed, so an undo restores the original id, timestamp and anchor
    /// rather than a copy of them.
    private var undoableDeletions: [UUID] = []

    // MARK: - Construction

    /// The app's store: the real container, at `StorageLocations.storeURL()`.
    ///
    /// - Throws: `PencilLoopError.storeWriteFailed` when the container will not
    ///   open. See `LibraryContainer` for why that is not recovered here.
    public nonisolated static func live() throws -> DocumentStore {
        let container = try LibraryContainer.make()
        return DocumentStore(modelContainer: container)
    }

    /// A store backed by an in-memory container. Nothing it writes survives the
    /// process. For `StorageTests` and for previews.
    public nonisolated static func inMemory() throws -> DocumentStore {
        let container = try LibraryContainer.inMemory()
        return DocumentStore(modelContainer: container)
    }

    /// A store over a container the caller already built.
    ///
    /// Exists because `@ModelActor` synthesises its initialiser at the module's
    /// default access level, which another module cannot reach.
    public nonisolated static func make(container: ModelContainer) -> DocumentStore {
        DocumentStore(modelContainer: container)
    }

    // MARK: - Library

    /// Rows for the sidebar.
    ///
    /// Search covers title, extracted document text and recognised handwriting
    /// in one fetch — see `LibraryFetch` for the predicate and its constraints.
    public func summaries(_ query: LibraryQuery) throws -> [DocumentSummary] {
        try fetch(LibraryFetch.descriptor(for: query)).map { $0.summary() }
    }

    /// One row, or nil when there is no such document.
    public func summary(id: UUID) throws -> DocumentSummary? {
        try documentRow(id: id)?.summary()
    }

    /// Everything the reader needs, or nil when there is no such document.
    ///
    /// One round trip by design: cold launch to a readable page has a
    /// one-second budget (docs/03-architecture.md § Performance targets).
    public func detail(id: UUID) throws -> DocumentDetail? {
        guard let row = try documentRow(id: id) else { return nil }
        var detail = row.detail()

        // `DocumentDetail.externalId` is what `review.json`'s `documentId`
        // must carry — the id the sending tool wrote into `meta.json` — and
        // the review sheet had no other route to it, so every review sent
        // carried our own UUID instead. Set here rather than inside
        // `Document.detail()` only because another agent owns that file this
        // wave; fold it in there next time it is open (Wave 3 report).
        detail.externalId = row.externalId
        return detail
    }

    /// Folder names already in the library, for the scanner's skip set.
    public func knownFolderNames() throws -> Set<String> {
        let rows = try fetch(FetchDescriptor<Document>())
        return Set(rows.map(\.folderName))
    }

    /// The document that came from a given inbox folder. Nil when unknown.
    public func documentId(forFolderName folderName: String) throws -> UUID? {
        try documentRow(folderName: folderName)?.id
    }

    // MARK: - Ingest

    /// Inserts a new document, or updates the row with the same `folderName`.
    ///
    /// Ink, comments, reading position, reading time and reading state all
    /// survive an update: the source was regenerated, the reader's marks were
    /// not. The existing row keeps its own `id` even when the incoming document
    /// carries a different one, because comments point at it — use
    /// `documentId(forFolderName:)` after a re-ingest rather than assuming the
    /// id you passed in.
    ///
    /// The `folderName` goes the other way. When the row is matched by id — the
    /// same document re-sent under a new `YYYY-MM-DD-` prefix — the row takes
    /// the **new** folder name, because that is the directory the document is
    /// in now and the one a reply will come back under.
    @discardableResult
    public func upsert(_ document: IngestedDocument) throws -> DocumentSummary {
        var existing = try documentRow(folderName: document.folderName)
        if existing == nil {
            existing = try documentRow(id: document.id)
        }

        if let row = existing {
            apply(document, to: row)
            refreshCounters(row)
            try commit()
            return row.summary()
        }

        let row = Document(
            id: document.id,
            externalId: document.externalId,
            folderName: document.folderName,
            relativePath: document.relativePath,
            title: document.title,
            pdfPath: StorageLocations.storedPath(for: document.pdfURL),
            sourceMarkdownPath: document.sourceMarkdownURL.map { StorageLocations.storedPath(for: $0) },
            sourceMapData: encoded(document.sourceMap),
            pageCount: document.pageCount,
            extractedText: document.extractedText,
            sourceFormatRaw: document.sourceFormat.rawValue,
            originKindRaw: document.origin.kind.rawValue,
            originSessionId: document.origin.sessionId,
            originThreadTitle: document.origin.threadTitle,
            returnPathTypeRaw: document.origin.returnPath?.type.rawValue,
            returnPathTriggerId: document.origin.returnPath?.triggerId,
            returnPathDetail: document.origin.returnPath?.detail,
            createdAt: document.createdAt,
            addedAt: document.addedAt
        )
        modelContext.insert(row)
        try commit()
        return row.summary()
    }

    /// Records that a folder could not be ingested.
    ///
    /// Three cases, and the difference between the last two is the whole point:
    ///
    /// - **The folder is unknown.** A placeholder row is inserted so the Library
    ///   can show an error row rather than nothing at all (docs/04-flows.md
    ///   § F1). It has no pinned bytes and `localState == .unavailable`, which
    ///   is what stops it being tappable (docs/02-spec.md § S1).
    /// - **The row exists and has no pinned bytes.** It was a placeholder
    ///   already; the reason is refreshed and it stays unavailable.
    /// - **The row exists and its pinned bytes are still on disk.** The reason
    ///   is recorded as a *refresh* failure and `localState` is left alone, so
    ///   the row stays readable. A pin that fails leaves the previous copy in
    ///   place (`InboxItemPinner.swap(staging:into:)`), so those bytes are
    ///   exactly the ones the user read yesterday, and "losing the folder costs
    ///   you new documents, never existing ones" (docs/02-spec.md
    ///   § Cross-cutting) has to hold for a provider hiccup too.
    ///
    /// A subsequent successful `upsert(_:)` clears the note.
    public func recordIngestFailure(folderName: String, reason: String) throws {
        if let existing = try documentRow(folderName: folderName) {
            existing.refreshFailureReason = reason
            existing.refreshFailedAt = Date()
            if existing.hasPinnedBytes == false {
                existing.localState = .unavailable(reason: reason)
            }
            try commit()
            return
        }
        let now = Date()
        let row = Document(
            id: UUID(),
            folderName: folderName,
            relativePath: SyncFolder.inboxDirectoryName + "/" + folderName,
            title: folderName,
            pdfPath: "",
            pageCount: 0,
            extractedText: "",
            sourceFormatRaw: SourceFormat.unknown.rawValue,
            originKindRaw: OriginKind.manual.rawValue,
            createdAt: now,
            addedAt: now,
            localStateRaw: Document.localStateUnavailable,
            localStateReason: reason,
            refreshFailureReason: reason,
            refreshFailedAt: now
        )
        modelContext.insert(row)
        try commit()
    }

    /// Renames a document (Protocols.swift § DocumentStoring.setTitle).
    ///
    /// `folderName` is untouched: it is the identity every stroke, comment and
    /// sent review is filed under, and renaming a note months later must not
    /// orphan any of them. So a note called "Note" that becomes "Cutover plan"
    /// still lives in `2026-08-21-note`, and that is correct rather than
    /// untidy — the folder name has a date in it for the same reason.
    ///
    /// An empty or whitespace title is ignored rather than rejected: the caller
    /// is a text field somebody has just cleared, and the recovery is to leave
    /// the name alone rather than to show an error.
    public func setTitle(_ title: String, documentId: UUID) throws {
        let row = try requireDocument(id: documentId)
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false, row.title != trimmed else { return }
        row.title = trimmed
        try commit()
    }

    /// Why the last attempt to ingest a folder failed, or nil when the last one
    /// succeeded or the folder is unknown.
    ///
    /// Internal to Storage for now: a row that is readable *and* carries a
    /// "couldn't refresh" note has nowhere to say so in `DocumentSummary`, and
    /// adding a field there is a `Core/Contracts` change request rather than a
    /// local edit (STYLE.md § 1). Until that lands the live surfacing is
    /// `SyncEvent.ingestFailed`, and this is what the tests read.
    func refreshFailure(forFolderName folderName: String) throws -> String? {
        try documentRow(folderName: folderName)?.refreshFailureReason
    }

    // MARK: - Reading state

    /// Moves a document between Library sections.
    public func setState(_ state: DocState, documentId: UUID) throws {
        let row = try requireDocument(id: documentId)
        guard row.state != state else { return }
        row.state = state
        try commit()
    }

    /// Pins a document to the top of the Library, or un-pins it
    /// (docs/02-spec.md § S1).
    ///
    /// Coalesced like `setState(_:documentId:)`: pinning something already
    /// pinned does not write, so it cannot move a row within the Pinned section
    /// by rewriting `pinnedAt`. Un-pinning clears the date rather than
    /// remembering it — a document that is not pinned has no pin time, and
    /// keeping a stale one would make the column lie to the sort.
    ///
    /// `state` is untouched on purpose. Pinning is orthogonal to it
    /// (DTOs.swift § `DocumentSummary.isPinned`).
    public func setPinned(_ pinned: Bool, documentId: UUID) throws {
        let row = try requireDocument(id: documentId)
        guard (row.pinnedAt != nil) != pinned else { return }
        row.pinnedAt = pinned ? Date() : nil
        try commit()
    }

    /// When a document was pinned, or nil when it is not pinned.
    ///
    /// Internal to Storage: `DocumentSummary.isPinned` is the whole of what the
    /// UI needs, and putting a date on the contract that no view reads would be
    /// a `Core/Contracts` change earning nothing (STYLE.md § 1). It is here so
    /// the tests can tell "still pinned" from "pinned again", which is the
    /// difference `setPinned(_:documentId:)`'s coalescing turns on and which
    /// `isPinned` cannot show.
    func pinnedAt(documentId: UUID) throws -> Date? {
        try documentRow(id: documentId)?.pinnedAt
    }

    /// Persisted on scroll, restored on open (docs/02-spec.md § S2).
    ///
    /// Coalesced: a page index that has not changed does not write, so the
    /// reader may call this as often as it likes. The value is clamped into the
    /// document's page range.
    public func setLastReadPage(_ pageIndex: Int, documentId: UUID) throws {
        let row = try requireDocument(id: documentId)
        let highest = max(0, row.pageCount - 1)
        let clamped = min(max(0, pageIndex), highest)
        guard row.lastReadPage != clamped else { return }
        row.lastReadPage = clamped
        try commit()
    }

    /// Sets whether the bytes are on this device.
    public func setLocalState(_ state: DocumentLocalState, documentId: UUID) throws {
        let row = try requireDocument(id: documentId)
        row.localState = state
        try commit()
    }

    // MARK: - Ink

    /// Saves archived `PKDrawing` bytes for one page.
    ///
    /// Called after the 500ms debounce, never on the touch path
    /// (docs/04-flows.md § F3). Passing nil — or empty data — clears the page's
    /// ink and its recognised text with it, because recognition of strokes that
    /// no longer exist would keep polluting search.
    ///
    /// **State transition:** the first drawing on an `.unread` document moves it
    /// to `.reviewing` (docs/04-flows.md § F2). Opening a document does not.
    ///
    /// - Note: Storage cannot tell an empty `PKDrawing` from a drawn one — it
    ///   does not import PencilKit — so Annotate must pass nil when
    ///   `drawing.strokes.isEmpty`, or the page will be counted as inked.
    public func saveDrawing(_ drawingData: Data?, pageIndex: Int, documentId: UUID) throws {
        let row = try requireDocument(id: documentId)

        guard let data = drawingData, data.isEmpty == false else {
            if let page = existingPage(at: pageIndex, in: row) {
                page.drawingData = nil
                page.hasInk = false
                page.recognisedInk = ""
                if page.isEmpty {
                    modelContext.delete(page)
                }
            }
            refreshCounters(row)
            try commit()
            return
        }

        let page = pageRow(at: pageIndex, in: row)
        page.drawingData = data
        page.hasInk = true
        markAnnotated(row)
        refreshCounters(row)
        try commit()
    }

    /// Stores `PKStrokeRecognizer` output for search and export. Nil clears it.
    ///
    /// Does not move the document to `.reviewing`: recognition is background
    /// work, not an annotation the user made (docs/04-flows.md § F3).
    public func saveRecognisedInk(_ text: String?, pageIndex: Int, documentId: UUID) throws {
        let row = try requireDocument(id: documentId)
        let value = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        guard value.isEmpty == false else {
            if let page = existingPage(at: pageIndex, in: row) {
                page.recognisedInk = ""
                if page.isEmpty {
                    modelContext.delete(page)
                }
            }
            try commit()
            return
        }

        let page = pageRow(at: pageIndex, in: row)
        page.recognisedInk = value
        try commit()
    }

    /// Every page's ink state, in page order.
    ///
    /// One entry per page of the document, including pages that have never been
    /// touched — those have no stored row and come back empty.
    public func pages(documentId: UUID) throws -> [PageSnapshot] {
        try requireDocument(id: documentId).pageSnapshots()
    }

    /// One page's archived `PKDrawing` bytes.
    ///
    /// - Returns: nil when the page has no ink, when the index is not one this
    ///   document has, and when the document itself is unknown. A read of
    ///   something missing is nil, never a throw (Protocols.swift §
    ///   DocumentStoring).
    ///
    /// The point of it is what it does *not* fetch: `pages(documentId:)` hands
    /// back every page's `drawingData`, which is the whole ink corpus of a
    /// 300-page document when the caller wanted one canvas.
    public func drawingData(pageIndex: Int, documentId: UUID) throws -> Data? {
        guard let row = try documentRow(id: documentId) else { return nil }
        return existingPage(at: pageIndex, in: row)?.drawingData
    }

    // MARK: - Comments

    /// Inserts a comment, minting its id and timestamp.
    ///
    /// **State transition:** the first comment on an `.unread` document moves it
    /// to `.reviewing` (docs/04-flows.md § F2).
    @discardableResult
    public func addComment(_ draft: CommentDraft, documentId: UUID) throws -> CommentSnapshot {
        let row = try requireDocument(id: documentId)
        let comment = Comment(draft: draft, id: UUID(), createdAt: Date(), document: nil)
        modelContext.insert(comment)
        row.comments.append(comment)
        markAnnotated(row)
        refreshCounters(row)
        try commit()
        return comment.snapshot()
    }

    /// Edits the text of an existing comment (review sheet, tap to edit).
    ///
    /// - Throws: `.commentNotFound` when the id is unknown or the comment has
    ///   been deleted. Editing something the user cannot see is always a bug at
    ///   the call site.
    public func updateComment(id: UUID, text: String) throws {
        let comment = try requireComment(id: id)
        guard comment.text != text else { return }
        comment.text = text
        try commit()
    }

    /// Deletes a comment.
    ///
    /// **Soft, and undoable for the session.** The row is marked with `deletedAt`
    /// and pushed onto an in-memory stack; `undoLastCommentDeletion()` puts it
    /// back with its original id, timestamp and anchor. Nothing the user does is
    /// destructive without undo (docs/02-spec.md § Cross-cutting), and a caller
    /// holding a snapshot cannot restore one faithfully — re-adding a
    /// `CommentDraft` mints a new id and a new timestamp, which breaks every
    /// marker and every reference to it.
    ///
    /// The rows are removed for good by `discardCommentUndoHistory()`, or by the
    /// process ending.
    ///
    public func deleteComment(id: UUID) throws {
        let comment = try requireComment(id: id)
        comment.deletedAt = Date()
        undoableDeletions.append(id)
        if let owner = comment.document {
            refreshCounters(owner)
        }
        try commit()
    }

    /// In document order: page, then vertical position within the page, then
    /// creation time. Deleted comments are excluded.
    public func comments(documentId: UUID) throws -> [CommentSnapshot] {
        try requireDocument(id: documentId).visibleComments.map { $0.snapshot() }
    }

    // MARK: - Comment undo

    /// How many deletions can still be undone in this session.
    public var undoableCommentDeletionCount: Int {
        undoableDeletions.count
    }

    /// Restores the most recently deleted comment.
    ///
    /// - Returns: the restored comment, or nil when nothing has been deleted in
    ///   this session. Never throws for an empty stack — "nothing to undo" is an
    ///   answer, not a failure.
    @discardableResult
    public func undoLastCommentDeletion() throws -> CommentSnapshot? {
        while let id = undoableDeletions.popLast() {
            guard let comment = try commentRow(id: id) else { continue }
            comment.deletedAt = nil
            if let owner = comment.document {
                refreshCounters(owner)
            }
            try commit()
            return comment.snapshot()
        }
        return nil
    }

    /// Permanently removes every soft-deleted comment and empties the undo
    /// stack.
    ///
    /// - Returns: how many rows were removed. Call it when a session ends or a
    ///   review has been sent; until then the rows are the undo.
    @discardableResult
    public func discardCommentUndoHistory() throws -> Int {
        // Filtered in memory rather than by predicate: `deletedAt != nil` over
        // an optional Date is exactly the shape of SwiftData predicate that has
        // historically translated badly, and this runs once a session over a few
        // hundred rows at most.
        let rows = try fetch(FetchDescriptor<Comment>()).filter { $0.deletedAt != nil }
        for row in rows {
            modelContext.delete(row)
        }
        undoableDeletions.removeAll()
        try commit()
        return rows.count
    }

    // MARK: - Reading time

    /// Adds to a document's accumulated reading time.
    ///
    /// Feeds the review sheet's "time spent" subtitle (docs/02-spec.md § S4) and
    /// `ReviewDraft.timeSpent`. Negative and non-finite values are ignored
    /// rather than corrupting the total.
    ///
    public func addReadingSeconds(_ seconds: TimeInterval, documentId: UUID) throws {
        guard seconds > 0, seconds.isFinite else { return }
        let row = try requireDocument(id: documentId)
        row.readingSeconds += seconds
        try commit()
    }

    /// Accumulated reading time in seconds. Zero for a document never opened.
    public func readingSeconds(documentId: UUID) throws -> TimeInterval {
        try requireDocument(id: documentId).readingSeconds
    }

    // MARK: - Review lifecycle

    /// Records that a review was sent and moves the document to `.read`
    /// (docs/04-flows.md § F5).
    public func recordReviewSent(documentId: UUID, at date: Date, directoryName: String) throws {
        let row = try requireDocument(id: documentId)
        row.reviewSentAt = date
        row.reviewDirectoryName = directoryName
        row.state = .read
        try commit()
    }

    /// Stores a reply an agent wrote (docs/04-flows.md § F6).
    public func recordReply(documentId: UUID, text: String, receivedAt: Date) throws {
        let row = try requireDocument(id: documentId)
        row.replyText = text
        row.replyReceivedAt = receivedAt
        try commit()
    }

    /// Where this document's review has got to (docs/04-flows.md §§ F5-F6).
    ///
    /// The read half of `recordReviewSent` and `recordReply`, which had none —
    /// so a reply that arrived after the review sheet closed was stored here
    /// and could never be shown. Every field is nil for a document that has
    /// never been reviewed, which is a status rather than an absence; nil is
    /// returned only when there is no such document.
    public func reviewStatus(documentId: UUID) throws -> ReviewStatus? {
        guard let row = try documentRow(id: documentId) else { return nil }
        return ReviewStatus(
            documentId: row.id,
            sentAt: row.reviewSentAt,
            directoryName: row.reviewDirectoryName,
            replyText: row.replyText,
            replyReceivedAt: row.replyReceivedAt
        )
    }

    // MARK: - Housekeeping

    /// Bytes on disk for the Settings storage row.
    ///
    /// Everything under the app's own container: the store file, SwiftData's
    /// external-storage directory, and the pinned document folders. The user's
    /// sync folder is not ours to measure.
    public func storageBytes() throws -> Int64 {
        StorageLocations.byteCount(at: StorageLocations.containerRoot())
    }

    /// Deletes documents in `.archived`, their pinned files included.
    ///
    /// The only operation in the app that removes a document's bytes, and the
    /// user has to ask for it (docs/02-spec.md § S6). Files are removed only
    /// from inside the app's documents root — never from the sync folder.
    ///
    /// - Returns: bytes freed. Zero is a normal answer.
    public func purgeArchived() throws -> Int64 {
        let archived = DocState.archived.rawValue
        let descriptor = FetchDescriptor<Document>(
            predicate: #Predicate<Document> { document in document.stateRaw == archived }
        )
        let rows = try fetch(descriptor)
        var freed: Int64 = 0
        for row in rows {
            freed += removePinnedFiles(for: row)
            modelContext.delete(row)
        }
        try commit()
        return freed
    }

    // MARK: - Private · fetching

    private func fetch<T: PersistentModel>(_ descriptor: FetchDescriptor<T>) throws -> [T] {
        do {
            return try modelContext.fetch(descriptor)
        } catch {
            throw PencilLoopError.storeWriteFailed(reason: error.localizedDescription)
        }
    }

    private func documentRow(id: UUID) throws -> Document? {
        var descriptor = FetchDescriptor<Document>(
            predicate: #Predicate<Document> { document in document.id == id }
        )
        descriptor.fetchLimit = 1
        return try fetch(descriptor).first
    }

    private func documentRow(folderName: String) throws -> Document? {
        var descriptor = FetchDescriptor<Document>(
            predicate: #Predicate<Document> { document in document.folderName == folderName }
        )
        descriptor.fetchLimit = 1
        return try fetch(descriptor).first
    }

    private func requireDocument(id: UUID) throws -> Document {
        guard let row = try documentRow(id: id) else {
            throw PencilLoopError.documentNotFound(id: id)
        }
        return row
    }

    private func commentRow(id: UUID) throws -> Comment? {
        var descriptor = FetchDescriptor<Comment>(
            predicate: #Predicate<Comment> { comment in comment.id == id }
        )
        descriptor.fetchLimit = 1
        return try fetch(descriptor).first
    }

    private func requireComment(id: UUID) throws -> Comment {
        guard let row = try commentRow(id: id), row.deletedAt == nil else {
            throw PencilLoopError.commentNotFound(id: id)
        }
        return row
    }

    // MARK: - Private · pages

    private func existingPage(at index: Int, in document: Document) -> Page? {
        document.pages.first { $0.pageIndex == index }
    }

    private func pageRow(at index: Int, in document: Document) -> Page {
        if let existing = existingPage(at: index, in: document) {
            return existing
        }
        let page = Page(pageIndex: index)
        modelContext.insert(page)
        document.pages.append(page)
        return page
    }

    // MARK: - Private · writing

    private func commit() throws {
        do {
            try modelContext.save()
        } catch {
            throw PencilLoopError.storeWriteFailed(reason: error.localizedDescription)
        }
    }

    /// `.unread → .reviewing` on the first annotation, never on open
    /// (docs/04-flows.md § F2).
    private func markAnnotated(_ document: Document) {
        guard document.state == .unread else { return }
        document.state = .reviewing
    }

    /// Recomputes the denormalised counters from the relationships. Cheap for
    /// one document; the alternative is counting on every Library fetch.
    private func refreshCounters(_ document: Document) {
        var visible = 0
        for comment in document.comments where comment.deletedAt == nil {
            visible += 1
        }
        var inked = 0
        for page in document.pages where page.hasInk {
            inked += 1
        }
        document.commentCount = visible
        document.inkedPageCount = inked
    }

    /// Copies everything an ingest owns onto an existing row, leaving everything
    /// the reader owns alone.
    private func apply(_ document: IngestedDocument, to row: Document) {
        row.externalId = document.externalId
        row.title = document.title
        // The folder name moves with the document. A row matched by `id` rather
        // than by `folderName` is the ordinary "same plan, sent again tomorrow"
        // case: the same `meta.json` id under a new `YYYY-MM-DD-` prefix. Leave
        // the old name here and the row claims a folder that no longer holds
        // it — `knownFolderNames()` never returns the new one, so the scanner
        // treats it as new for ever, and `documentId(forFolderName:)` cannot
        // match a `reply.md` written into `<new folder>.review` back to it
        // (SyncCoordinator.collectReplies).
        //
        // Safe against the `@Attribute(.unique)` on `folderName`: `upsert`
        // looks a row up by folder name first, so reaching this line with a
        // different name means no row holds it.
        row.folderName = document.folderName
        row.relativePath = document.relativePath
        row.pdfPath = StorageLocations.storedPath(for: document.pdfURL)
        row.sourceMarkdownPath = document.sourceMarkdownURL.map { StorageLocations.storedPath(for: $0) }
        row.sourceMapData = encoded(document.sourceMap)
        row.pageCount = document.pageCount
        row.extractedText = document.extractedText
        row.sourceFormat = document.sourceFormat
        row.origin = document.origin
        row.createdAt = document.createdAt
        row.addedAt = document.addedAt
        row.localState = .local
        // The bytes arrived, so whatever the last refresh complained about is
        // history (`recordIngestFailure(folderName:reason:)`).
        row.refreshFailureReason = nil
        row.refreshFailedAt = nil
        let highest = max(0, document.pageCount - 1)
        if row.lastReadPage > highest {
            row.lastReadPage = highest
        }
    }

    /// `sourcemap.json` bytes, or nil when there is no map or it will not encode.
    private func encoded(_ map: SourceMap?) -> Data? {
        guard let map else { return nil }
        return try? ContractCoding.encoder().encode(map)
    }

    /// Removes a document's pinned bytes. Never reaches outside the app's own
    /// documents root.
    private func removePinnedFiles(for document: Document) -> Int64 {
        let manager = FileManager.default
        var targets: [URL] = [StorageLocations.documentDirectory(folderName: document.folderName)]
        if let pdf = document.pdfURL {
            targets.append(pdf)
        }
        if let markdown = document.sourceMarkdownURL {
            targets.append(markdown)
        }

        var freed: Int64 = 0
        for target in targets {
            guard StorageLocations.isInsideDocumentsRoot(target) else { continue }
            guard manager.fileExists(atPath: target.path(percentEncoded: false)) else { continue }
            freed += StorageLocations.byteCount(at: target)
            try? manager.removeItem(at: target)
        }
        return freed
    }
}
