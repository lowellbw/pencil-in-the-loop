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
    /// and again whenever `assetState()` finds the assets missing — a language
    /// chosen since, or a model the system removed (docs/03-architecture.md § 4).
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
    ///
    /// **It listens.** A warmed engine has the microphone running and keeps
    /// the newest second of audio, which the recording that follows starts
    /// with — so a word spoken as the hold resolves is in the transcript
    /// rather than lost to setup. The system's recording indicator shows from
    /// here. What is kept is discarded, never transcribed, if no recording
    /// follows, and `releaseCapture()` is how a caller says none will.
    func prewarm() async

    /// Gives the microphone back after a `prewarm()` that did not become a
    /// recording — an arming press that lifted early, a squeeze that came to
    /// nothing.
    ///
    /// Does nothing while a recording is running, which is what makes it safe
    /// to call late: a release that arrives after the next recording has begun
    /// must not end it. Does nothing when there is nothing to give back. Never
    /// throws. Engines that warm nothing need not implement it.
    func releaseCapture() async

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

    /// Where to also write the audio of the next recording, or nil to keep
    /// none (notes/pencil-loop-cloud-dictation.md).
    ///
    /// The on-device transcript is a draft, and a better one can only be made
    /// later from the audio — so this is what makes an upgrade possible at all.
    /// Set it before `transcribe(contextualTerms:)`; it applies to the next
    /// recording and is cleared by `finishedClip()`.
    ///
    /// **Best-effort, in one direction only.** An engine that cannot write a
    /// clip still transcribes, and a clip that fails to write costs a later
    /// upgrade and never the recording in progress. Never throws.
    func setClipDestination(_ url: URL?) async

    /// The clip written for the recording that just finished, or nil.
    ///
    /// Call after `stop()`, so the last buffers are in the file. Nil means
    /// there is nothing to upgrade from: no destination was set, the write
    /// failed, or the press was too short to be a comment.
    func finishedClip() async -> URL?

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

extension SpeechTranscribing {

    /// The default for an engine with nothing to give back: previews and test
    /// doubles, which warm nothing. The real engines and every wrapper around
    /// them implement it, because a wrapper that let this default stand would
    /// silently leave a warmed microphone running.
    public func releaseCapture() async {}
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

    /// Asks for a spoken version of a document (docs/02-spec.md § S2).
    ///
    /// **Returns as soon as the request is made, not when audio exists.**
    /// Generating a narration takes minutes; the file arrives on a later scan
    /// like a document does. The reader is on a protected path and must never
    /// wait on this (CLAUDE.md non-negotiable 1).
    ///
    /// Idempotent: asking again while one is being made does nothing.
    ///
    /// - Parameter depth: how much of the document survives — `brief`,
    ///   `standard` or `deep`. All three cover every section.
    /// - Throws: `.folderUnavailable` when the relay cannot be reached, and
    ///   `.outboxWriteFailed` when it refuses. Either way there is still a
    ///   document to read.
    func requestNarration(forFolderName folderName: String, depth: String) async throws

    /// What the relay says about this document's narration.
    ///
    /// The device cannot answer this itself. A local "I asked for one" flag is
    /// gone the moment the app relaunches, and the reader would then be offered
    /// a narration that is already halfway made. The relay is the one that
    /// remembers, so this asks it.
    ///
    /// - Throws: `.folderUnavailable` when the relay cannot be reached. A
    ///   caller that cannot ask shows what it last knew, and never an error
    ///   that stops the document being read.
    func narrationStatus(forFolderName folderName: String) async throws -> NarrationStatus

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

    /// Renames a document.
    ///
    /// The title is a label; `folderName` is an identity and is **not**
    /// touched. A note created untitled keeps the folder it was born with
    /// however many times it is renamed, so every stroke, comment and review
    /// already filed against it still points at it.
    ///
    /// The caller is responsible for the copy of the title in `meta.json` —
    /// `NoteCreator.rename(to:forFolderNamed:)` — because re-ingesting a
    /// document reads the title from there, and adding a page to a notebook is
    /// a re-ingest. A rename recorded here alone comes back undone the next
    /// time somebody adds paper.
    ///
    /// Ignores a title that is empty or whitespace: a row with no name is one
    /// nobody can find again, and an untitled note already has a default.
    ///
    /// - Throws: `.documentNotFound` when the id is unknown.
    func setTitle(_ title: String, documentId: UUID) throws

    // Reading state

    func setState(_ state: DocState, documentId: UUID) throws

    /// Pins a document to the top of the Library, or un-pins it
    /// (docs/02-spec.md § S1).
    ///
    /// Idempotent: pinning a pinned document is a no-op and does not move it,
    /// so a double tap on the swipe action cannot silently reorder the list.
    ///
    /// **Not destructive and not a state change.** `DocumentSummary.isPinned`
    /// is orthogonal to `DocState` — see its doc comment — so this never moves
    /// a document between Unread, Reviewing and Read, and un-pinning returns it
    /// to whichever section it was already in.
    ///
    /// - Throws: `.documentNotFound` when the id is unknown.
    func setPinned(_ pinned: Bool, documentId: UUID) throws

    /// Puts the Pinned section in exactly this order, top first
    /// (docs/02-spec.md § S1).
    ///
    /// **Rewrites `pinnedAt` rather than storing a separate rank.** The pin
    /// moment was already there and already unique per document, so ordering by
    /// it costs no new column and therefore no schema migration; a reorder
    /// simply re-stamps the moments to match the order given. The cost is that
    /// "when was this pinned" stops being true after the first drag, which is a
    /// question nothing asks.
    ///
    /// Ids that are not pinned, or not known, are ignored rather than throwing:
    /// the list comes from a view that may be a moment out of date, and a
    /// document un-pinned on another screen must not fail the drag.
    ///
    /// - Throws: `.storeWriteFailed` when the write fails. Order is unchanged
    ///   in that case.
    func reorderPinned(_ documentIds: [UUID]) throws

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

/// Which group each document is filed under (docs/02-spec.md § S1).
///
/// **A second face on the settings store, not a second store.** Every method
/// here is a read-modify-write of the one blob `SettingsStoring` owns, so a
/// separate actor over the same key would silently lose a write whenever a
/// group assignment raced a change made in Settings. The conformer is
/// `AppSettingsStore`, which already serialises exactly this way, and the
/// protocol is narrow so that Sync can be handed the capability without being
/// handed the whole of the user's configuration to write one string.
///
/// It lives here rather than on `DocumentStoring` because the library store does
/// not hold groups and should not claim to — see `AppSettings.DocumentGroups`
/// for why they are kept outside it.
///
/// **On failure:** the three mutating members throw
/// `PencilLoopError.storeWriteFailed` when the settings will not encode, and
/// leave the in-memory value untouched. `groups()` never throws — settings that
/// cannot be read answer `.empty`, which is indistinguishable from a device
/// where nothing has been filed, and that is the correct recovery.
public protocol DocumentGrouping: Actor {

    /// Every assignment the app holds.
    ///
    /// Empty on a fresh install and after an unreadable settings blob — never
    /// nil, never an error.
    func groups() -> AppSettings.DocumentGroups

    /// Files a document under `name`, or clears its group when `name` is nil.
    ///
    /// The on-device action, so it always wins: this is what the row's Group
    /// menu calls, and it may move a document a sender filed. A name matching a
    /// group already in use joins that group under the spelling already on
    /// screen. Idempotent.
    func setGroupName(_ name: String?, forFolderName folderName: String) throws

    /// Files a document under `name` **only when it has no group already**, and
    /// does nothing at all when `name` is nil.
    ///
    /// What a sender's `meta.json` gets (docs/05-file-contracts.md). It may
    /// propose a group for a document arriving for the first time; it may never
    /// move one the user has filed by hand, and it can never un-group anything.
    /// Without that distinction every re-send would drag a document back into
    /// the sender's group.
    func adoptGroupName(_ name: String?, forFolderName folderName: String) throws

    /// Renames a group, moving every document filed under it in one write.
    ///
    /// Renaming onto a name already in use **merges** the two, which is the only
    /// coherent answer when a group is identified by its name. Renaming a name
    /// nothing is filed under is a no-op rather than an error.
    ///
    /// - Throws: `.storeWriteFailed` when the new name is empty or unusable.
    func renameGroup(_ name: String, to newName: String) throws

    /// Draws the group sections in exactly this order, first to last
    /// (docs/02-spec.md § S1).
    ///
    /// Groups the reader has never placed keep coming after the placed ones,
    /// alphabetically, so a group made tomorrow appears somewhere predictable
    /// rather than at a position nobody chose. A name that is not in use is
    /// still recorded: emptying a group and filling it again should put it back
    /// where it was put.
    ///
    /// - Throws: `.storeWriteFailed` when the settings will not encode. The
    ///   order is unchanged in that case.
    func reorderGroups(_ names: [String]) throws

    /// Drops assignments for documents the library no longer holds.
    ///
    /// Pass `DocumentStoring.knownFolderNames()`, which includes archived
    /// documents: archiving must not lose a group, and purging must. Call it
    /// after a purge and nowhere else — in particular never against the rows the
    /// Library has fetched, because those are filtered by the search text and
    /// pruning against them would un-group everything that did not match.
    func pruneGroups(keeping folderNames: Set<String>) throws

    /// Remembers how the Library is sectioned (docs/02-spec.md § S1).
    ///
    /// Here rather than on `SettingsStoring` because it is one blob and one
    /// writer: the Library sets this while Settings may be writing something
    /// else, and two actors over the same key lose one of the two.
    ///
    /// Idempotent — setting the value it already has does not write.
    ///
    /// - Throws: `.storeWriteFailed` when the settings will not encode. The
    ///   mode on screen is unaffected; only the memory of it is.
    func setLibraryGrouping(_ grouping: LibraryGrouping) throws
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
/// Produces bytes, not files. The relay upload does the writing; keeping them
/// apart is what makes the builder testable without a network, and it is why
/// `review.md` can be diffed against the golden fixture at
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
