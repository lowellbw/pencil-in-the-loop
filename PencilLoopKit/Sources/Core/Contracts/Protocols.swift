//
//  Protocols.swift
//  Core · Contracts
//
//  Every seam between two modules. One file on purpose: this is the list a new
//  agent reads to find out what it is allowed to call, and splitting it across
//  eight files makes that list something you have to assemble rather than read.
//  Listed in tooling/lint/style_allowlist.txt.
//
//  ─────────────────────────────────────────────────────────────────────────────
//  RULES FOR EVERY PROTOCOL BELOW
//
//  1. The doc comment states what happens **when it fails or is unavailable**.
//     That is a contract term. "Returns nil when recognition is unavailable" is
//     the difference between a feature degrading and an app that will not open a
//     document because a recogniser was busy.
//  2. `Sendable` unless the type must hold mutable state, in which case `Actor`.
//     Nothing here is `@MainActor`; AppUI is the only main-actor module and it
//     awaits into these.
//  3. Arguments and returns are types from Core/Contracts only. No PDFKit, no
//     PencilKit, no SwiftData, no SwiftUI — those live behind the implementing
//     module's wall.
//  4. Adding a member is a change request to the lead. A Wave 1 unit that finds
//     a signature insufficient says so; it does not edit this file, because six
//     agents editing one contract concurrently is how the contract stops being
//     one.
//  ─────────────────────────────────────────────────────────────────────────────
//

import Foundation

// MARK: - Ingest

/// Parses markdown into our own IR.
///
/// The only implementation wraps `swift-markdown` and lives in
/// Sources/Ingest/Adapters/SwiftMarkdownAdapter.swift, the single file in the
/// repo permitted to `import Markdown`.
///
/// **On failure:** throws `PencilLoopError.markdownParseFailed`. Callers must
/// not let that lose the document — fall back to rendering the raw text as a
/// single preformatted block. A document that cannot be parsed still has to
/// appear in the library (docs/04-flows.md § F1).
public protocol MarkdownParsing: Sendable {

    /// - Parameter markdown: the full contents of `source.md`.
    /// - Returns: a document whose every node's `sourceRange` indexes UTF-8
    ///   byte offsets into that exact string.
    func parse(_ markdown: String) throws -> MarkdownDocument
}

/// Lays out a parsed document as a PDF and records where everything landed.
///
/// **On failure:** throws `PencilLoopError.renderFailed`. There is no partial
/// result — a half-rendered PDF is worse than none, because it would be pinned
/// and treated as complete.
///
/// **Determinism is a requirement, not a nicety.** The same document and
/// geometry must produce the same pagination on every run, or a comment
/// anchored today lands on the wrong page after a re-render.
public protocol MarkdownPDFRendering: Sendable {

    /// Renders and builds the source map in a single layout pass.
    ///
    /// - Parameters:
    ///   - document: the parsed IR. `document.source` is what the returned
    ///     source map's ranges index.
    ///   - geometry: page size, margins and type metrics. Pass
    ///     `PageGeometry.annotationFriendly` unless you have a reason.
    /// - Returns: the PDF bytes, the page count, the source map, and the plain
    ///   text for the search index.
    func render(_ document: MarkdownDocument, geometry: PageGeometry) throws -> RenderedPDF
}

/// Turns one directory under `inbox/` into a library row.
///
/// The single ingest path (docs/04-flows.md § F1). Cowork, Claude Code, the
/// share extension and a manual drop all arrive here; there are not four paths,
/// there is one.
///
/// **On failure:** throws `PencilLoopError.nothingToIngest`,
/// `.unreadableDocument` or `.materialisationFailed`. The caller records the
/// failure and shows an error row. It must never delete the folder, and must
/// never silently skip it — a document that vanishes is worse than one that
/// shows a problem.
///
/// **Guarantee on success:** every URL in the returned `IngestedDocument` is a
/// file inside the app container that is fully downloaded and pinned. Not a
/// file-provider placeholder (CLAUDE.md non-negotiable 2).
public protocol DocumentIngesting: Sendable {

    /// - Parameter item: a scanned inbox directory.
    /// - Returns: a fully materialised document ready to be stored.
    func ingest(_ item: InboxItem) async throws -> IngestedDocument

    /// Re-reads `meta.json` alone, for a folder that was rewritten in place
    /// without its document changing.
    ///
    /// **On failure:** returns `DocumentMetadata.empty`. Never throws — a
    /// malformed `meta.json` must not block anything.
    func metadata(at url: URL) async -> DocumentMetadata
}

// MARK: - Annotation

/// Turns strokes into text.
///
/// **When it fails or is unavailable — this one matters.** Returns nil. It does
/// not throw, and nothing in the app waits on it. `PKStrokeRecognizer` ships in
/// iPadOS 27, is Latin-only in the Simulator, and can decline a page for
/// reasons the user will never care about. Ink is always captured and always
/// exported as an image regardless (docs/04-flows.md § F3); recognition is an
/// enhancement that improves search and adds a line to the review bundle.
///
/// **Never on the main actor.** Recognition has a 500ms per-page budget and must
/// not touch the drawing path.
public protocol HandwritingRecognising: Sendable {

    /// - Parameters:
    ///   - drawingData: archived `PKDrawing` bytes for one page.
    ///   - locale: the recogniser's language.
    /// - Returns: recognised text, or nil when the recogniser is unavailable,
    ///   declined the input, or found nothing worth returning.
    func recogniseText(drawingData: Data, locale: Locale) async -> RecognisedInk?

    /// Whether recognition can run at all right now, for the given locale.
    ///
    /// Cheap enough to call before starting a batch. Callers should treat
    /// `false` as "skip recognition", never as an error to report.
    func isAvailable(for locale: Locale) async -> Bool
}

/// On-device speech, behind a protocol so either engine can be swapped in
/// (docs/03-architecture.md § 4: `SpeechAnalyzer` first, `SFSpeechRecognizer`
/// with `requiresOnDeviceRecognition = true` as the fallback path).
///
/// **When it fails or is unavailable:** `assetState()` reports it and the UI
/// shows one Settings row. The comment popover still opens — the user taps
/// "✎ scribble instead" and the flow completes with `source = .handwriting`.
/// Dictation being unavailable is never a dead end and never a modal.
///
/// **Lifecycle.** One recording at a time. `transcribe(contextualTerms:)` starts
/// capture and returns immediately; the stream yields until `stop()` is called
/// or the task is cancelled. Cancelling the stream's task must stop capture and
/// release the audio session. Calling `transcribe` while one is running
/// finishes the previous stream with `PencilLoopError.speechUnavailable`.
public protocol SpeechTranscribing: Sendable {

    /// Whether language assets are installed. Cheap; safe to poll from a view.
    func assetState() async -> SpeechAssetState

    /// Triggers the one-time asset download, in the background, on first run
    /// (docs/03-architecture.md § 4).
    ///
    /// Idempotent, non-throwing, and returns as soon as the request is queued —
    /// not when the download completes. Poll `assetState()` for progress.
    func prepareAssets() async

    /// Opens the audio session and starts the engine, before the gesture that
    /// will use it has resolved.
    ///
    /// The first token is budgeted at 400ms from press (docs/03-architecture.md
    /// § Performance targets) and starting a speech session costs most of that,
    /// so the caller warms the engine on touch-down and calls
    /// `transcribe(contextualTerms:)` when the long press fires
    /// (`GestureTiming.longPressDuration` later).
    ///
    /// **Idempotent, non-throwing, best-effort.** Calling it twice is a no-op,
    /// calling it while a recording is running is a no-op, and an engine that
    /// cannot warm up says nothing — the failure surfaces from `transcribe`,
    /// where there is a UI to show it. A caller must never wait on this or
    /// branch on it; it is an optimisation, and dictation works without it.
    func prewarm() async

    /// Starts recording and streams updates.
    ///
    /// - Parameter contextualTerms: document jargon — identifiers, capitalised
    ///   nouns, code spans, title words. Engines that accept vocabulary biasing
    ///   use it directly; engines that do not ignore it, and the caller
    ///   post-corrects with `TranscriptCorrecting` instead. Pass the terms
    ///   either way.
    /// - Returns: a stream of updates. It finishes normally on `stop()`, and
    ///   throws `PencilLoopError.speechUnavailable` or `.permissionDenied` if
    ///   capture cannot start. First token is budgeted at 400ms from press.
    func transcribe(contextualTerms: [String]) -> AsyncThrowingStream<TranscriptionUpdate, Error>

    /// Ends the current recording and returns the final text.
    ///
    /// Safe to call when nothing is running, in which case it returns "".
    /// Callers use this return value rather than the last streamed update —
    /// the engine may finalise a trailing word after the last yield.
    func stop() async -> String

    /// Every language this engine can transcribe, downloaded or not.
    ///
    /// The Settings language picker is the only caller (docs/02-spec.md § S6).
    /// Without it that picker is a hardcoded list of BCP-47 identifiers that
    /// says nothing about the device it is running on — it offers languages the
    /// engine cannot do and hides ones it can.
    ///
    /// **On failure or unavailability:** returns an empty array. Never throws.
    /// An empty answer means "this engine cannot say", and the caller falls
    /// back to showing the currently selected language alone rather than an
    /// error: a picker with one row is a worse Settings screen, not a broken
    /// app. Whether the assets for a given language are *installed* is a
    /// separate question, and `assetState()` is the one that answers it.
    func supportedLocales() async -> [Locale]
}

/// Document-specific vocabulary and transcript repair.
///
/// `SpeechAnalyzer` has no vocabulary-biasing API, so jargon is fixed after the
/// fact (docs/03-architecture.md § 4). Cheap, effective, and engine-independent.
///
/// **On failure:** there is no failure mode. Both members are pure and total; a
/// term list that finds nothing returns an empty array, and correction that
/// matches nothing returns its input unchanged.
public protocol TranscriptCorrecting: Sendable {

    /// Builds the term list from a document: identifiers, capitalised nouns,
    /// code spans, title words.
    ///
    /// - Returns: terms in descending order of usefulness, de-duplicated. Cap
    ///   the result at around 100 — that is what the fallback engine accepts as
    ///   `contextualStrings`.
    func terms(forDocumentText text: String, title: String) -> [String]

    /// Fuzzy-corrects transcript tokens against the term list.
    ///
    /// Conservative by design: correcting a word the user did say is worse than
    /// missing one they did not.
    func correct(_ transcript: String, against terms: [String]) -> String
}

// MARK: - Sync

/// Security-scoped access to the user's chosen folder.
///
/// Every filesystem operation on the sync folder goes through
/// `withAccess(to:perform:)`. Reaching a URL outside an open scope fails with a
/// permissions error that looks, from the outside, exactly like a missing file
/// — which is a bug that takes an afternoon to find, twice.
///
/// **When it fails or is unavailable:** throws
/// `PencilLoopError.folderUnavailable`, `.accessDenied` or `.bookmarkStale`.
/// Every one of those is recoverable and none of them may make an already
/// ingested document unreadable: documents live in the app container, and
/// losing the folder costs you new documents only (docs/02-spec.md §
/// Cross-cutting).
public protocol FolderAccessing: Sendable {

    /// Takes the URL from `fileImporter`, creates `inbox/` and `outbox/` if
    /// absent, and mints a security-scoped bookmark.
    ///
    /// - Throws: `.accessDenied` when the scope will not open,
    ///   `.folderUnavailable` when the directories cannot be created.
    func prepareFolder(at url: URL) throws -> SyncFolder

    /// Resolves a persisted bookmark.
    ///
    /// - Throws: `.bookmarkStale` when the bookmark resolved but has gone
    ///   stale. A throwing call returns no folder, so the caller cannot mint a
    ///   replacement "from the returned folder" — it calls
    ///   `refreshedFolder(bookmark:)`, which resolves the stale bookmark
    ///   anyway, mints a fresh one and hands back both. Persist the new
    ///   bookmark then.
    ///   `.folderUnavailable` when it cannot be resolved at all.
    func resolveFolder(bookmark: Data) throws -> SyncFolder

    /// Re-resolves a stale bookmark and mints a replacement.
    ///
    /// The recovery half of `resolveFolder(bookmark:)`. Resolving a stale
    /// bookmark still yields a usable URL; what it does not yield is a bookmark
    /// that will resolve next launch, and that is what this mints.
    ///
    /// - Returns: the folder, with `bookmark` set to the fresh one — or to the
    ///   one passed in when minting failed, which is survivable for this launch
    ///   and means the user is asked for the folder again on the next one.
    /// - Throws: `.folderUnavailable` when the bookmark will not resolve even
    ///   in stale form.
    func refreshedFolder(bookmark: Data) throws -> SyncFolder

    /// Runs `body` with the security scope open, closing it afterwards even if
    /// `body` throws.
    ///
    /// - Note: not re-entrant across processes. The share extension opens its
    ///   own scope on the App Group container.
    func withAccess<T: Sendable>(to folder: SyncFolder, perform body: @Sendable (SyncFolder) throws -> T) throws -> T

    /// The same, for work that suspends.
    ///
    /// Scanning, pinning and writing all `await` in the middle, and a
    /// synchronous closure cannot hold the scope across a suspension — which is
    /// why Sync kept a concrete `beginAccess`/`endAccess` pair and could not be
    /// held as `any FolderAccessing`. Prefer this overload for anything that
    /// touches the folder.
    ///
    /// - Note: same re-entrancy rule as the synchronous overload, and it
    ///   matters more here: the scope stays open for the whole of `body`, so do
    ///   not open a second one inside it.
    func withAccess<T: Sendable>(to folder: SyncFolder, perform body: @Sendable (SyncFolder) async throws -> T) async throws -> T

    /// Whether the root is reachable right now. Never throws; a false answer is
    /// information, not an error.
    func isReachable(_ folder: SyncFolder) -> Bool
}

/// Finds candidate documents under `inbox/`.
///
/// **On failure:** throws `PencilLoopError.folderUnavailable` when the folder
/// itself cannot be read. A single unreadable subdirectory is skipped and
/// returned in `InboxScanResult.skipped`, never propagated — one bad folder
/// must not stop the scan. The coordinator turns each skip into a
/// `SyncEvent.ingestFailed` and an error row; a scanner that returned a bare
/// array had no way to say a folder had been skipped at all, so nobody ever
/// learned about it.
///
/// Scanning is cheap and idempotent. Pull-to-refresh calls it, the watcher calls
/// it, and first launch calls it.
public protocol InboxScanning: Sendable {

    /// - Parameters:
    ///   - folder: the sync root. The caller must already hold access.
    ///   - knownFolderNames: names already in the library. Implementations use
    ///     this to skip work, and must still return an item for a known folder
    ///     whose contents changed since `modifiedAt`.
    /// - Returns: the items in folder-name order, which is chronological given
    ///   the date prefix, and every subdirectory that was skipped with the
    ///   reason it was skipped.
    func scan(_ folder: SyncFolder, knownFolderNames: Set<String>) async throws -> InboxScanResult

    /// Examines one directory, for the watcher's targeted case.
    ///
    /// - Returns: nil when the directory holds nothing ingestible.
    func item(at directoryURL: URL) async throws -> InboxItem?
}

/// Writes a review bundle into `outbox/`, atomically.
///
/// **Atomicity is the contract.** Assemble into a sibling `.tmp` directory, then
/// rename into place (docs/04-flows.md § F5). A watcher on the other side must
/// never see a half-written bundle, and it will be watching.
///
/// **On failure:** throws `PencilLoopError.outboxWriteFailed`, having removed
/// the temporary directory. Nothing partial is left behind. When the folder is
/// simply unreachable — offline provider, ejected volume — throws
/// `.folderUnavailable`, and the caller queues the payload and tells the user
/// "will send when online" rather than reporting a failure (docs/04-flows.md
/// § F7).
public protocol OutboxWriting: Sendable {

    /// - Parameters:
    ///   - payload: the bundle as bytes. The writer does not build, format or
    ///     re-order anything.
    ///   - folder: the sync root. The caller must already hold access.
    /// - Returns: where it landed.
    func write(_ payload: OutboxPayload, to folder: SyncFolder) async throws -> WrittenReview

    /// Reads `outbox/<directoryName>/reply.md`, if an agent has written one
    /// (docs/04-flows.md § F6).
    ///
    /// - Returns: nil when there is no reply yet. Never throws for a missing
    ///   file; absence is the normal case.
    func readReply(inReviewDirectory directoryName: String, in folder: SyncFolder) async throws -> String?
}

/// Watches the sync folder for changes.
///
/// **When it fails or is unavailable:** emits `FolderEvent.folderUnavailable`
/// and keeps the stream open. A watcher that ends its stream on the first
/// hiccup turns a temporarily ejected volume into an app restart. Recovery
/// emits `.folderRestored`.
///
/// **Not a source of truth.** Events mean "look again", and every consumer must
/// tolerate duplicates, misses and out-of-order delivery by re-scanning. On
/// iPadOS, file coordination does not reliably see every change a provider makes
/// in the background, which is why pull-to-refresh exists (docs/02-spec.md § S1).
public protocol FolderWatching: Sendable {

    /// Starts watching and returns the event stream.
    ///
    /// Cancelling the consuming task stops the watcher and releases the
    /// `NSFilePresenter`. Calling this twice replaces the first stream, which is
    /// then finished.
    func events(for folder: SyncFolder) -> AsyncStream<FolderEvent>

    /// Stops watching. Idempotent.
    func stop() async
}

/// The whole sync loop, as AppUI sees it: watch, scan, ingest, store, write.
///
/// One face for what is really four collaborators, so a view does not have to
/// orchestrate them.
///
/// **On failure:** `refresh()` and `send(_:)` throw `PencilLoopError`; both are
/// user-initiated and both have somewhere to show it. Background work never
/// throws into the UI — it reports through `events()` and carries on.
public protocol SyncCoordinating: Sendable {

    /// Begins watching and performs an initial scan. Idempotent.
    func start() async

    /// Stops watching. The library stays fully usable afterwards.
    func stop() async

    /// A full re-scan, as pull-to-refresh triggers.
    ///
    /// - Returns: how many documents were newly ingested. Zero is a normal,
    ///   successful answer.
    func refresh() async throws -> Int

    /// The event stream for the UI. Multiple consumers each get their own
    /// stream; a consumer that stops listening costs nothing.
    func events() -> AsyncStream<SyncEvent>

    /// Writes a bundle to `outbox/`, queueing it when the folder is unreachable.
    ///
    /// - Returns: where it landed, or throws when it could not even be queued.
    func send(_ payload: OutboxPayload) async throws -> WrittenReview

    /// Turns an agent's `reply.md` into a new document, with the origin
    /// inherited — the "Open as document" action on the Sent screen
    /// (docs/04-flows.md § F6).
    ///
    /// The reply is written into `inbox/` like anything else, because there is
    /// one ingest path and not two. The new document is annotatable, and a
    /// review of it goes back to the conversation the original came from.
    ///
    /// - Parameter reviewDirectoryName: `<slug>.review`.
    /// - Returns: the new document's id.
    /// - Throws: `.nothingToIngest` when there is no reply to open yet, or
    ///   whatever ingest threw. User-initiated, so the caller has somewhere to
    ///   show it.
    @discardableResult
    func ingestReply(fromReviewDirectory reviewDirectoryName: String) async throws -> UUID
}

// MARK: - Storage

/// The library, as everyone outside Storage sees it.
///
/// **This protocol lives in Core, not Storage, and that is load-bearing.** Sync
/// depends on Core alone, so the share extension can link Sync without dragging
/// SwiftData into an extension process (see Package.swift § Sync). Move this
/// declaration into Storage and that structural guarantee goes away silently.
///
/// **`Actor`, not `Sendable`.** The implementation owns a `ModelContext`, which
/// is not thread-safe, so the store serialises access by being an actor. Every
/// member is therefore `await`ed from outside.
///
/// **`@Model` types never appear here.** Every argument and return is a value
/// type from DTOs.swift. See that file's header for why.
///
/// **On failure:** throws `PencilLoopError.documentNotFound`,
/// `.commentNotFound` or `.storeWriteFailed`. Reads of a missing document return
/// nil rather than throwing; writes to a missing document throw, because the
/// caller has just done something impossible.
public protocol DocumentStoring: Actor {

    // Library

    /// Rows for the sidebar.
    func summaries(_ query: LibraryQuery) throws -> [DocumentSummary]

    /// One row, or nil when there is no such document.
    func summary(id: UUID) throws -> DocumentSummary?

    /// Everything the reader needs, or nil when there is no such document.
    func detail(id: UUID) throws -> DocumentDetail?

    /// Folder names already in the library, for the scanner's skip set.
    func knownFolderNames() throws -> Set<String>

    /// The document that came from a given inbox folder, for matching replies
    /// and re-ingests. Nil when unknown.
    func documentId(forFolderName folderName: String) throws -> UUID?

    // Ingest

    /// Inserts a new document, or updates the existing row with the same
    /// `folderName` — a re-sent document must not become a duplicate.
    ///
    /// Ink and comments on an existing document survive an update: the source
    /// was regenerated, the reader's marks were not.
    @discardableResult
    func upsert(_ document: IngestedDocument) throws -> DocumentSummary

    /// Records that a folder could not be ingested, so the library can show an
    /// error row instead of nothing.
    func recordIngestFailure(folderName: String, reason: String) throws

    // Reading state

    func setState(_ state: DocState, documentId: UUID) throws

    /// Persisted on scroll, restored on open. Frequent — implementations should
    /// coalesce.
    func setLastReadPage(_ pageIndex: Int, documentId: UUID) throws

    func setLocalState(_ state: DocumentLocalState, documentId: UUID) throws

    // Ink

    /// Saves archived `PKDrawing` bytes for one page. Called after the 500ms
    /// debounce, never on the touch path (docs/04-flows.md § F3).
    ///
    /// Passing nil clears the page's ink.
    func saveDrawing(_ drawingData: Data?, pageIndex: Int, documentId: UUID) throws

    /// Stores `PKStrokeRecognizer` output for search and export. Nil clears it.
    func saveRecognisedInk(_ text: String?, pageIndex: Int, documentId: UUID) throws

    /// Every page's ink state, in page order.
    func pages(documentId: UUID) throws -> [PageSnapshot]

    /// One page's archived `PKDrawing` bytes.
    ///
    /// - Returns: nil when the page has no ink, and nil for a page index the
    ///   document does not have. Reads of a missing document return nil rather
    ///   than throwing, like every other read here.
    ///
    /// Exists because `pages(documentId:)` returns every page's `drawingData`:
    /// drawing one page of a 300-page document meant fetching the whole ink
    /// corpus to render one canvas. Performance, not correctness — a caller
    /// that already holds the snapshots should keep using them.
    func drawingData(pageIndex: Int, documentId: UUID) throws -> Data?

    // Comments

    /// Inserts a comment, minting its id and timestamp.
    @discardableResult
    func addComment(_ draft: CommentDraft, documentId: UUID) throws -> CommentSnapshot

    /// Edits the text of an existing comment (review sheet, tap to edit).
    func updateComment(id: UUID, text: String) throws

    /// Deletes a comment, undoably for the session.
    ///
    /// **Soft.** The row is marked deleted and pushed onto the store's undo
    /// stack; it stops appearing in `comments(documentId:)` and stops counting
    /// towards `DocumentSummary.commentCount` immediately.
    /// `undoLastCommentDeletion()` puts it back exactly as it was.
    ///
    /// The undo cannot be done by the caller holding the snapshot and re-adding
    /// it: `addComment(_:documentId:)` mints a new id and a new timestamp, so
    /// the restored comment is a different comment — every marker drawn against
    /// the old id, and every reference to it in a sent review, points at
    /// nothing. "Nothing is destructive without undo" (docs/02-spec.md
    /// § Cross-cutting) needs the store to do it.
    ///
    /// - Throws: `.commentNotFound` when the id is unknown.
    func deleteComment(id: UUID) throws

    /// Restores the most recently deleted comment, with its original id,
    /// timestamp and anchor.
    ///
    /// - Returns: the restored comment, or nil when nothing has been deleted in
    ///   this session. An empty undo stack is an answer, not a failure — a UI
    ///   may call this on a shake or a button without checking first.
    @discardableResult
    func undoLastCommentDeletion() throws -> CommentSnapshot?

    /// In document order: page, then vertical position within the page.
    func comments(documentId: UUID) throws -> [CommentSnapshot]

    // Review lifecycle

    /// Records that a review was sent, for the Sent screen and to move the
    /// document to `.read`.
    func recordReviewSent(documentId: UUID, at date: Date, directoryName: String) throws

    /// Stores a reply an agent wrote (docs/04-flows.md § F6).
    func recordReply(documentId: UUID, text: String, receivedAt: Date) throws

    /// What has happened to this document's review: when it was sent, where the
    /// bundle went, and whether a reply has come back.
    ///
    /// The read half of `recordReviewSent(documentId:at:directoryName:)` and
    /// `recordReply(documentId:text:receivedAt:)`, which had none. Without it
    /// the reply loop docs/08-open-questions.md § Q3 kept in v1 is only half
    /// reachable: the Sent screen could see a `SyncEvent.replyReceived` while it
    /// happened to be open, and a reply that arrived after the sheet closed —
    /// which is nearly all of them, since an agent takes minutes — could never
    /// be shown at all. The store already had the text; nothing could ask for
    /// it.
    ///
    /// Deliberately a separate call rather than four more fields on
    /// `DocumentDetail`: the reader opens a document far more often than
    /// anybody looks at a sent review, and this is the review sheet's question,
    /// not the reader's.
    ///
    /// - Returns: the status, or nil when there is no such document. A document
    ///   that has never been reviewed returns a `ReviewStatus` with everything
    ///   nil rather than nil itself, so a caller can tell "never sent" from
    ///   "no such document".
    func reviewStatus(documentId: UUID) throws -> ReviewStatus?

    // Reading time

    /// Adds to a document's accumulated reading time.
    ///
    /// Feeds `ReviewDraft.timeSpent` and the review sheet's subtitle
    /// (docs/02-spec.md § S4). The reader accumulates while a document is open
    /// and hands over whole intervals; nothing here is a timer.
    ///
    /// Negative, zero and non-finite values are ignored rather than corrupting
    /// the total. Frequent — implementations should coalesce, like
    /// `setLastReadPage(_:documentId:)`.
    ///
    /// - Throws: `.documentNotFound` when the id is unknown.
    func addReadingSeconds(_ seconds: TimeInterval, documentId: UUID) throws

    /// Accumulated reading time in seconds.
    ///
    /// - Returns: zero for a document that has never been opened.
    /// - Throws: `.documentNotFound` when the id is unknown.
    func readingSeconds(documentId: UUID) throws -> TimeInterval

    // Housekeeping

    /// Bytes on disk for the Settings storage row.
    func storageBytes() throws -> Int64

    /// Deletes documents in `.archived`, their pinned files included. The only
    /// operation in the app that removes a document's bytes, and the user has to
    /// ask for it (docs/02-spec.md § S6).
    func purgeArchived() throws -> Int64
}

/// Persisted user settings.
///
/// **`Actor`** for the same reason as the store: it wraps a single mutable
/// value that several actors read.
///
/// **On failure:** `update(_:)` throws `PencilLoopError.storeWriteFailed`.
/// Reads never throw — settings that cannot be loaded fall back to
/// `AppSettings.initial`, which lands the user on the folder picker, which is
/// the correct recovery.
public protocol SettingsStoring: Actor {

    /// The current settings. Cheap; safe to read per view update.
    var settings: AppSettings { get }

    /// Replaces the settings and persists them.
    func update(_ settings: AppSettings) throws
}

// MARK: - Export

/// Decides how a review gets back to its conversation.
///
/// Pure and synchronous: it reads `meta.json`'s origin and picks the best
/// available path (docs/04-flows.md § F5). It does not check whether the path
/// will actually work — nothing on device can — so the review sheet shows the
/// user what was chosen and lets them decide (docs/02-spec.md § S4).
///
/// **When it fails or is unavailable:** returns `ResolvedReturnPath.unresolved`.
/// Never throws, never returns nil. "No return path" is a supported outcome with
/// a good fallback — copy, share sheet, save to folder — and must never be
/// presented as an error (docs/06-integrations.md § The universal fallback).
public protocol ReturnPathResolving: Sendable {

    /// - Parameter origin: from `meta.json`. Pass `Origin.manual` when there was
    ///   no metadata at all.
    /// - Returns: the chosen path, always. Check `sameThread`, not `type`, when
    ///   deciding what badge to draw.
    func resolve(_ origin: Origin) -> ResolvedReturnPath
}

/// Builds the review bundle: `review.md`, `review.json`, `manifest.json` and the
/// cropped ink PNGs.
///
/// Produces bytes, not files. `OutboxWriting` does the atomic write; keeping
/// them apart is what makes the builder testable without a sync folder, and it
/// is why `review.md` can be diffed against the golden fixture at
/// contracts/fixtures/review.md.
///
/// **On failure:** throws `PencilLoopError.bundleBuildFailed`. An ink page that
/// will not render is skipped with its comment text kept, rather than failing
/// the whole bundle — losing a review because one PNG would not encode is not
/// an acceptable trade.
///
/// Budget: under 2 seconds for a 50-page document with 20 comments
/// (docs/03-architecture.md § Performance targets).
public protocol ReviewBundleBuilding: Sendable {

    /// - Parameter draft: everything the review sheet collected.
    /// - Returns: the bundle as bytes, ready to write.
    func build(_ draft: ReviewDraft) async throws -> OutboxPayload

    /// Just the prose payload, for "Copy review" on the Sent screen and for the
    /// share-sheet fallback (docs/06-integrations.md).
    ///
    /// Byte-identical to the `review.md` inside the payload for the same draft.
    func reviewMarkdown(_ draft: ReviewDraft) async throws -> String
}

/// Crops one page of ink to an image with the page content beneath it.
///
/// Union of the stroke bounding boxes, plus `InkImage.paddingFraction` on each
/// side, long edge capped at `InkImage.maxLongEdgePixels`, page content rendered
/// underneath — an arrow with nothing to point at is useless
/// (docs/05-file-contracts.md § Ink images).
///
/// **On failure:** throws `PencilLoopError.bundleBuildFailed`. The builder
/// catches it, skips that page and carries on.
public protocol InkCropping: Sendable {

    /// - Parameters:
    ///   - pdfURL: the pinned document, for rendering page content beneath.
    ///   - pageIndex: zero-based.
    ///   - drawingData: archived `PKDrawing` bytes for that page.
    ///   - recognisedText: copied into the result, not computed here.
    /// - Returns: the PNG and its bundle-relative path.
    func cropInk(
        pdfURL: URL,
        pageIndex: Int,
        drawingData: Data,
        recognisedText: String?
    ) async throws -> InkImage
}
