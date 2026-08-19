//
//  DTOs.swift
//  Core · Contracts
//
//  The transfer objects. One file by design — these types exist as a set, they
//  are read as a set, and one-per-file would turn a single readable inventory
//  into twenty stubs. Listed in tooling/lint/style_allowlist.txt.
//
//  ─────────────────────────────────────────────────────────────────────────────
//  THE RULE THAT MAKES THIS FILE NECESSARY
//
//  SwiftData `@Model` classes never cross an actor boundary. `Document`, `Page`
//  and `Comment` are reference types bound to the `ModelContext` that created
//  them; handing one to another actor is a data race that Swift 6 will refuse to
//  compile, and if you defeat it with `@unchecked Sendable` you get faults under
//  concurrent access instead.
//
//  So: `@Model` types live inside Storage and never leave it. Everything that
//  crosses a boundary is a value type from this file. The store's job is to read
//  models and hand back snapshots; the UI's job is to send drafts back. Nothing
//  else passes.
//  ─────────────────────────────────────────────────────────────────────────────
//

import Foundation

// MARK: - Library

/// Everything one row in the Library sidebar needs, and nothing more.
///
/// The subtitle in docs/02-spec.md § S1 — "Cowork · 8 min ago · 4 pages" — is
/// assembled by the view from `originDisplayName`, `addedAt` and `pageCount`.
/// The store does not format dates: relative dates change while a view is on
/// screen, and formatting is a locale decision the UI layer owns.
public struct DocumentSummary: Sendable, Hashable, Identifiable {

    public var id: UUID
    public var title: String

    /// First subtitle part: `OriginKind.displayName`, pre-resolved so the row
    /// does not need the whole `Origin`.
    public var originDisplayName: String

    /// Second subtitle part, rendered relative by the view.
    public var addedAt: Date

    /// Third subtitle part.
    public var pageCount: Int

    public var state: DocState

    /// Drives the trailing dot. See `DocumentLocalState` — a document that is
    /// not `.local` is dimmed and not tappable (docs/02-spec.md § S1).
    public var localState: DocumentLocalState

    /// Convenience over `localState`, because most call sites only care whether
    /// the row opens.
    public var isLocal: Bool { localState == .local }

    /// Shown as a count next to the row and in the reader toolbar.
    public var commentCount: Int

    /// True when any page carries ink. Used for the "n inked pages" line and to
    /// decide whether the ink toggles in the review sheet are meaningful.
    public var hasInk: Bool

    /// `YYYY-MM-DD-<slug>`, the directory name under `inbox/`. The stable
    /// handle for matching a reply back to its document.
    public var folderName: String

    /// Why the last attempt to refresh this document failed, when it failed and
    /// the document is still readable. Nil when the last attempt succeeded.
    ///
    /// **Not an error state, and deliberately not `localState`.** `.unavailable`
    /// means there are no bytes to open and the row is dimmed; this means the
    /// bytes are exactly the ones the user read yesterday and the row opens as
    /// it always did — what it cannot promise is that it is *current*. A
    /// document that quietly stopped updating used to be indistinguishable from
    /// one that is fine, because the only surfacing was a transient
    /// `SyncEvent.ingestFailed` that was gone by the next scan.
    ///
    /// Nil when `localState` is already `.unavailable`: the store records both
    /// for such a row, and the two carry the same sentence, so a row would
    /// otherwise say the same thing twice in two different voices.
    public var refreshFailureReason: String?

    public init(
        id: UUID,
        title: String,
        originDisplayName: String,
        addedAt: Date,
        pageCount: Int,
        state: DocState,
        localState: DocumentLocalState,
        commentCount: Int,
        hasInk: Bool,
        folderName: String,
        refreshFailureReason: String? = nil
    ) {
        self.id = id
        self.title = title
        self.originDisplayName = originDisplayName
        self.addedAt = addedAt
        self.pageCount = pageCount
        self.state = state
        self.localState = localState
        self.commentCount = commentCount
        self.hasInk = hasInk
        self.folderName = folderName
        self.refreshFailureReason = refreshFailureReason
    }
}

/// Whether the bytes are on this device.
///
/// "Always local" is a hard requirement, not a cache policy (docs/02-spec.md §
/// Cross-cutting). `.downloading` is a transient state during ingest only;
/// `.unavailable` means ingest failed and the row shows an error rather than
/// vanishing.
public enum DocumentLocalState: Sendable, Hashable {
    /// Materialised in the app container. The only state in which a row opens.
    case local
    /// Being copied in. `progress` is 0…1, or nil when indeterminate.
    case downloading(progress: Double?)
    /// Could not be materialised. `reason` is shown on the error row verbatim.
    case unavailable(reason: String)
}

/// How the Library list is filtered and ordered.
public struct LibraryQuery: Sendable, Hashable {

    /// Matches title, extracted document text, and recognised handwriting
    /// (docs/02-spec.md § S1). Nil or empty means no text filter.
    public var searchText: String?

    /// Which sections to include. Empty means every state except `.archived`.
    public var states: Set<DocState>

    public var sort: LibrarySort

    /// Plain ascending order: `true` is oldest-first for `.dateAdded` and A–Z
    /// for `.title`; `false` is newest-first and Z–A.
    ///
    /// The default is `false`, which is newest-first — the library's normal
    /// order — and therefore Z–A when the sort is switched to `.title`. A title
    /// list wants `ascending: true`.
    public var ascending: Bool

    public init(
        searchText: String? = nil,
        states: Set<DocState> = [],
        sort: LibrarySort = .dateAdded,
        ascending: Bool = false
    ) {
        self.searchText = searchText
        self.states = states
        self.sort = sort
        self.ascending = ascending
    }

    /// Everything readable, newest first.
    public static let all = LibraryQuery()
}

public enum LibrarySort: String, Sendable, Codable, CaseIterable, Hashable {
    case dateAdded
    case title
}

// MARK: - Reader

/// Everything the reader needs to open a document, in one round trip.
///
/// Deliberately one call rather than five: cold launch to a readable page has a
/// one-second budget (docs/03-architecture.md § Performance targets) and five
/// actor hops is where that budget goes.
public struct DocumentDetail: Sendable, Hashable, Identifiable {

    public var id: UUID
    public var title: String
    public var folderName: String

    /// The raw `meta.json` id, kept verbatim for tools that wrote a non-UUID.
    ///
    /// Carried through to `ReviewDraft.externalDocumentId` and out to
    /// `review.json`'s `documentId`, which exists precisely to be the id the
    /// sending tool used. `IngestedDocument.externalId` and the stored row both
    /// had it and the reader's view of a document did not, so every review sent
    /// carried our UUID instead — the one thing that field must not be.
    ///
    /// Nil when `meta.json` carried no id, or carried one that was already a
    /// UUID and therefore became `id`.
    public var externalId: String?

    /// The pinned copy inside the app container. Never a file-provider URL —
    /// see CLAUDE.md non-negotiable 2.
    ///
    /// **Nil when this row has no document behind it**: a folder that was seen
    /// and could not be ingested is recorded by
    /// `DocumentStoring.recordIngestFailure(folderName:reason:)` and has a
    /// library row, an error to show, and no bytes. Callers open the reader
    /// only when this is non-nil; `DocumentSummary.isLocal` is the cheaper
    /// check for a list row (docs/02-spec.md § S1).
    public var pdfURL: URL?

    /// The original markdown, when there was one.
    public var sourceMarkdownURL: URL?

    /// Loaded from `sourcemap.json`, nil for an imported PDF.
    public var sourceMap: SourceMap?

    public var pageCount: Int
    public var state: DocState
    public var origin: Origin
    public var addedAt: Date

    /// Restored on open (docs/02-spec.md § S2). Zero for a document never read.
    public var lastReadPage: Int

    /// Full document text, for search highlighting and for the speech term list
    /// (docs/03-architecture.md § 4, jargon handling).
    public var extractedText: String

    public var pages: [PageSnapshot]
    public var comments: [CommentSnapshot]

    public init(
        id: UUID,
        title: String,
        folderName: String,
        externalId: String? = nil,
        pdfURL: URL?,
        sourceMarkdownURL: URL? = nil,
        sourceMap: SourceMap? = nil,
        pageCount: Int,
        state: DocState,
        origin: Origin,
        addedAt: Date,
        lastReadPage: Int,
        extractedText: String,
        pages: [PageSnapshot],
        comments: [CommentSnapshot]
    ) {
        self.id = id
        self.title = title
        self.folderName = folderName
        self.externalId = externalId
        self.pdfURL = pdfURL
        self.sourceMarkdownURL = sourceMarkdownURL
        self.sourceMap = sourceMap
        self.pageCount = pageCount
        self.state = state
        self.origin = origin
        self.addedAt = addedAt
        self.lastReadPage = lastReadPage
        self.extractedText = extractedText
        self.pages = pages
        self.comments = comments
    }
}

/// Where a document's review has got to, as the store knows it.
///
/// The read half of the review lifecycle: `recordReviewSent`, then
/// `recordReply`, then this (Protocols.swift § DocumentStoring). Every field is
/// optional because every one of them describes something that may not have
/// happened yet, and "not yet" is the normal state.
///
/// It is what makes a reply survive the sheet being closed. The `SyncEvent`
/// stream only reaches a screen that is on screen, and an agent replies in
/// minutes; without a stored read, the reply loop worked only for a user who
/// sat and waited.
public struct ReviewStatus: Sendable, Hashable {

    public var documentId: UUID

    /// When the user pressed Send. Nil when no review has been sent.
    public var sentAt: Date?

    /// `<folderName>.review` under `outbox/`, the handle
    /// `SyncCoordinating.ingestReply(fromReviewDirectory:)` takes. Nil when no
    /// review has been sent.
    public var directoryName: String?

    /// The agent's `reply.md`, verbatim (docs/04-flows.md § F6). Nil when no
    /// reply has arrived — which is most of the time, and is not a failure.
    public var replyText: String?

    /// When the reply was seen in the folder. Nil while `replyText` is.
    public var replyReceivedAt: Date?

    public init(
        documentId: UUID,
        sentAt: Date? = nil,
        directoryName: String? = nil,
        replyText: String? = nil,
        replyReceivedAt: Date? = nil
    ) {
        self.documentId = documentId
        self.sentAt = sentAt
        self.directoryName = directoryName
        self.replyText = replyText
        self.replyReceivedAt = replyReceivedAt
    }

    /// True once a review has been sent for this document.
    public var hasBeenSent: Bool { sentAt != nil }

    /// True once an agent has written back.
    public var hasReply: Bool {
        guard let replyText else { return false }
        return replyText.isEmpty == false
    }
}

/// One page's ink, detached from its `@Model`.
public struct PageSnapshot: Sendable, Hashable {

    /// Zero-based.
    public var pageIndex: Int

    /// Archived `PKDrawing`, exactly the bytes `PKDrawing.dataRepresentation()`
    /// produced. Core never interprets these — it does not import PencilKit.
    public var drawingData: Data?

    /// `PKStrokeRecognizer` output, for search and for the review bundle. Nil
    /// when recognition has not run, is unavailable, or found nothing. Never a
    /// reason to hold up anything (docs/04-flows.md § F3).
    public var recognisedInk: String?

    public var hasInk: Bool

    public init(pageIndex: Int, drawingData: Data? = nil, recognisedInk: String? = nil, hasInk: Bool = false) {
        self.pageIndex = pageIndex
        self.drawingData = drawingData
        self.recognisedInk = recognisedInk
        self.hasInk = hasInk
    }
}

// MARK: - Comments

/// A stored comment, detached from its `@Model`.
public struct CommentSnapshot: Sendable, Hashable, Identifiable, Codable {

    public var id: UUID
    public var createdAt: Date

    /// The text as it will be sent. Post-corrected against the document term
    /// list already — correction happens once, at save (docs/04-flows.md § F4).
    public var text: String

    public var source: CommentSource
    public var anchor: Anchor

    /// The page the marker is drawn on. Normally `anchor.pageIndex`; they differ
    /// only when a comment was re-resolved onto a different page after the
    /// document was regenerated.
    public var resolvedOnPage: Int

    public init(
        id: UUID,
        createdAt: Date,
        text: String,
        source: CommentSource,
        anchor: Anchor,
        resolvedOnPage: Int
    ) {
        self.id = id
        self.createdAt = createdAt
        self.text = text
        self.source = source
        self.anchor = anchor
        self.resolvedOnPage = resolvedOnPage
    }
}

/// A comment on its way into the store. No id and no timestamp: the store mints
/// both, so that two callers cannot disagree about them.
public struct CommentDraft: Sendable, Hashable {

    public var text: String
    public var source: CommentSource
    public var anchor: Anchor
    public var resolvedOnPage: Int

    public init(text: String, source: CommentSource, anchor: Anchor, resolvedOnPage: Int) {
        self.text = text
        self.source = source
        self.anchor = anchor
        self.resolvedOnPage = resolvedOnPage
    }
}

/// Which step of the four-step ladder resolved an anchor, and what it found.
///
/// Carried into `review.md` as nothing at all when exact, and as an "approximate"
/// note when it is a rect fallback. The distinction matters to whoever reads the
/// review: an exact match can be edited blind, a rect fallback cannot.
public enum AnchorResolution: Sendable, Hashable {

    /// Step 1: `prefix + quoted + suffix` matched exactly. `range` covers the
    /// quoted part only, not the context.
    case exact(range: SourceRange)

    /// Step 2: `quoted` alone matched exactly, context did not.
    case quoteOnly(range: SourceRange)

    /// Step 3: whitespace-normalised fuzzy match. `similarity` is 0…1, where 1
    /// is identical; the resolver only returns this above
    /// `1 - AnchorResolver.fuzzyTolerance`.
    case fuzzy(range: SourceRange, similarity: Double)

    /// Step 4: no text match survived. Position is the page and rect only, and
    /// every consumer must describe it as approximate.
    case rectFallback(pageIndex: Int, rect: NormalisedRect)

    /// The resolved range, when there is one.
    public var range: SourceRange? {
        switch self {
        case let .exact(range): return range
        case let .quoteOnly(range): return range
        case let .fuzzy(range, _): return range
        case .rectFallback: return nil
        }
    }

    /// True for everything except the rect fallback.
    public var isTextMatch: Bool { range != nil }

    /// One-word label for logs and for the review sheet's diagnostics.
    public var label: String {
        switch self {
        case .exact: return "exact"
        case .quoteOnly: return "quote"
        case .fuzzy: return "fuzzy"
        case .rectFallback: return "approximate"
        }
    }
}

// MARK: - Ingest

/// What Ingest hands Storage. Everything already materialised, nothing lazy.
///
/// By the time this value exists the bytes are in the app container and the
/// document is readable offline. Storage inserts a row; it does not fetch, copy
/// or verify anything.
public struct IngestedDocument: Sendable, Hashable {

    /// Minted by Ingest: `meta.json`'s id when it parses as a UUID, otherwise
    /// fresh. Stable across re-ingests of the same folder.
    public var id: UUID

    /// The raw `meta.json` id, kept verbatim for tools that wrote a non-UUID.
    public var externalId: String?

    /// PDF metadata title, markdown H1, or filename — in that order.
    public var title: String

    /// `YYYY-MM-DD-<slug>` under `inbox/`.
    public var folderName: String

    /// Path relative to the sync root, e.g. `inbox/2026-08-18-auth-refactor-plan`.
    /// Relative because the sync root moves when the user re-picks the folder.
    public var relativePath: String

    /// The pinned local copy.
    public var pdfURL: URL

    public var sourceMarkdownURL: URL?
    public var sourceMap: SourceMap?

    public var origin: Origin
    public var sourceFormat: SourceFormat
    public var pageCount: Int

    /// Full text for the search index.
    public var extractedText: String

    /// When the writing tool made it, from `meta.json`; falls back to the
    /// folder's modification date.
    public var createdAt: Date

    /// When we ingested it. This is what the Library sorts by.
    public var addedAt: Date

    public init(
        id: UUID,
        externalId: String? = nil,
        title: String,
        folderName: String,
        relativePath: String,
        pdfURL: URL,
        sourceMarkdownURL: URL? = nil,
        sourceMap: SourceMap? = nil,
        origin: Origin,
        sourceFormat: SourceFormat,
        pageCount: Int,
        extractedText: String,
        createdAt: Date,
        addedAt: Date
    ) {
        self.id = id
        self.externalId = externalId
        self.title = title
        self.folderName = folderName
        self.relativePath = relativePath
        self.pdfURL = pdfURL
        self.sourceMarkdownURL = sourceMarkdownURL
        self.sourceMap = sourceMap
        self.origin = origin
        self.sourceFormat = sourceFormat
        self.pageCount = pageCount
        self.extractedText = extractedText
        self.createdAt = createdAt
        self.addedAt = addedAt
    }
}

/// The output of rendering markdown to PDF.
public struct RenderedPDF: Sendable, Hashable {

    /// The complete PDF. Written to `document.pdf` by the caller — the renderer
    /// does no file IO, which is what makes it testable.
    public var pdfData: Data

    public var pageCount: Int

    /// Built during the same pass. Never a second pass: retrofitting a source
    /// map means laying out twice and getting slightly different answers.
    public var sourceMap: SourceMap

    /// Plain text of the rendered document, in reading order, for search.
    public var extractedText: String

    public init(pdfData: Data, pageCount: Int, sourceMap: SourceMap, extractedText: String) {
        self.pdfData = pdfData
        self.pageCount = pageCount
        self.sourceMap = sourceMap
        self.extractedText = extractedText
    }
}

/// Page size, margins and type metrics for markdown rendering, in points.
///
/// Deliberately values rather than constants in the renderer: the ink cropper
/// and the source map both need to know the page geometry, and three copies of
/// "A4 with 56pt margins" is three chances to disagree.
public struct PageGeometry: Sendable, Hashable, Codable {

    public var pageWidth: Double
    public var pageHeight: Double
    public var marginTop: Double
    public var marginLeft: Double
    public var marginBottom: Double

    /// Wider than the others on purpose. The right margin is where handwriting
    /// goes (docs/03-architecture.md § 1) — an annotation-friendly page is not a
    /// dense one.
    public var marginRight: Double

    /// Body text size. 11pt per docs/03-architecture.md.
    public var bodyPointSize: Double

    /// Extra leading between lines, as a multiple of the font's own line height.
    /// Generous by design.
    public var lineSpacingMultiple: Double

    /// Widest code line the text column fits without wrapping. The authoring
    /// guidance sent to Claude keeps code under this
    /// (docs/06-integrations.md).
    public var maxCodeColumnCharacters: Int

    public init(
        pageWidth: Double,
        pageHeight: Double,
        marginTop: Double,
        marginLeft: Double,
        marginBottom: Double,
        marginRight: Double,
        bodyPointSize: Double,
        lineSpacingMultiple: Double,
        maxCodeColumnCharacters: Int
    ) {
        self.pageWidth = pageWidth
        self.pageHeight = pageHeight
        self.marginTop = marginTop
        self.marginLeft = marginLeft
        self.marginBottom = marginBottom
        self.marginRight = marginRight
        self.bodyPointSize = bodyPointSize
        self.lineSpacingMultiple = lineSpacingMultiple
        self.maxCodeColumnCharacters = maxCodeColumnCharacters
    }

    /// A4 portrait, 56pt margins, 140pt right margin for marginalia, 11pt body.
    /// The only geometry v1 ships.
    public static let annotationFriendly = PageGeometry(
        pageWidth: 595.276,
        pageHeight: 841.89,
        marginTop: 56,
        marginLeft: 56,
        marginBottom: 56,
        marginRight: 140,
        bodyPointSize: 11,
        lineSpacingMultiple: 1.35,
        maxCodeColumnCharacters: 76
    )

    /// A4 portrait with even 56pt margins, for paper the reader writes on
    /// rather than annotates (docs/11-backlog.md § B1).
    ///
    /// The difference from `annotationFriendly` is the right margin. That one
    /// keeps 140pt clear because handwriting goes *beside* somebody else's
    /// text; on a blank page the handwriting is the text, so the ruling runs
    /// the full width and the gutter would only waste a third of the page.
    public static let notebook = PageGeometry(
        pageWidth: 595.276,
        pageHeight: 841.89,
        marginTop: 56,
        marginLeft: 56,
        marginBottom: 56,
        marginRight: 56,
        bodyPointSize: 11,
        lineSpacingMultiple: 1.35,
        maxCodeColumnCharacters: 76
    )

    /// The laid-out text column, in points.
    public var textColumnWidth: Double { pageWidth - marginLeft - marginRight }

    /// The laid-out text column height, in points.
    public var textColumnHeight: Double { pageHeight - marginTop - marginBottom }
}

// MARK: - Speech and handwriting

/// One update from the transcriber.
///
/// `SpeechAnalyzer` streams two things at once and both matter: a volatile
/// hypothesis that changes as you keep speaking, and text that has been
/// finalised and will not change again. Rendering only the finalised text makes
/// the popover look frozen; rendering only the volatile text makes it flicker.
/// Show `finalisedText + volatileText`, styling the volatile part dimmer.
public struct TranscriptionUpdate: Sendable, Hashable {

    /// The unstable tail. Replaced wholesale by the next update.
    public var volatileText: String

    /// Everything settled so far, cumulative from the start of this recording.
    public var finalisedText: String

    public init(volatileText: String, finalisedText: String) {
        self.volatileText = volatileText
        self.finalisedText = finalisedText
    }

    /// What to display: settled text plus the current hypothesis.
    public var displayText: String {
        volatileText.isEmpty ? finalisedText : finalisedText + volatileText
    }
}

/// Whether on-device speech can run right now.
///
/// Language assets download once through the system asset catalog. This is the
/// one place the app is allowed to be honest about needing the network, and it
/// surfaces as a single Settings row, never as a blocker in the comment
/// popover (docs/03-architecture.md § 4).
public enum SpeechAssetState: Sendable, Hashable {
    /// Assets installed. Transcription works offline.
    case ready
    /// Downloading. `progress` is 0…1, nil when indeterminate.
    case downloading(progress: Double?)
    /// Cannot transcribe: no assets, no permission, or the locale is
    /// unsupported. `reason` is user-facing text for the Settings row. The
    /// comment popover must still open — the user scribbles instead.
    case unavailable(reason: String)
}

/// `PKStrokeRecognizer` output for one page of ink.
public struct RecognisedInk: Sendable, Hashable, Codable {

    /// Recognised text, lines joined with newlines in reading order.
    public var text: String

    /// 0…1 when the recogniser reports one, else nil. Advisory: low confidence
    /// is a reason to dim the text in the review sheet, never a reason to drop
    /// it.
    public var confidence: Double?

    public init(text: String, confidence: Double? = nil) {
        self.text = text
        self.confidence = confidence
    }
}

// MARK: - Sync

/// The user-chosen sync root and the two folders inside it.
///
/// Reaching any of these URLs requires the security scope to be open — always
/// go through `FolderAccessing.withAccess(to:perform:)`, never touch `rootURL`
/// directly.
public struct SyncFolder: Sendable, Hashable {

    /// The folder the user picked in `fileImporter`.
    public var rootURL: URL

    /// `rootURL/inbox`. Created on first run if absent.
    public var inboxURL: URL

    /// `rootURL/outbox`. Created on first run if absent.
    public var outboxURL: URL

    /// The security-scoped bookmark to persist. Re-resolve it on every launch;
    /// a stale bookmark is normal and recoverable, a missing one means asking
    /// the user again.
    public var bookmark: Data?

    /// Last path component of `rootURL`, for the Settings row.
    public var displayName: String

    public init(rootURL: URL, inboxURL: URL, outboxURL: URL, bookmark: Data? = nil, displayName: String) {
        self.rootURL = rootURL
        self.inboxURL = inboxURL
        self.outboxURL = outboxURL
        self.bookmark = bookmark
        self.displayName = displayName
    }

    /// Derives the standard layout from a root. The only place `inbox`/`outbox`
    /// are spelled.
    public init(rootURL: URL, bookmark: Data? = nil) {
        self.init(
            rootURL: rootURL,
            inboxURL: rootURL.appendingPathComponent(SyncFolder.inboxDirectoryName, isDirectory: true),
            outboxURL: rootURL.appendingPathComponent(SyncFolder.outboxDirectoryName, isDirectory: true),
            bookmark: bookmark,
            displayName: rootURL.lastPathComponent
        )
    }

    public static let inboxDirectoryName = "inbox"
    public static let outboxDirectoryName = "outbox"
}

/// One candidate directory under `inbox/`, as found on disk.
///
/// A scan result, not a document: it says what files exist, not what they
/// contain. Ingest decides whether it is usable.
public struct InboxItem: Sendable, Hashable, Identifiable {

    /// `YYYY-MM-DD-<slug>`. Unique within `inbox/`, and the identity used to
    /// decide whether this is new or a re-scan of something already ingested.
    public var folderName: String

    public var directoryURL: URL

    /// `document.pdf`, when present. Its absence means Ingest must render
    /// `source.md` (docs/04-flows.md § F1).
    public var pdfURL: URL?

    public var sourceMarkdownURL: URL?
    public var sourceMapURL: URL?
    public var metaURL: URL?

    /// Newest modification date across the directory's files. Used to notice a
    /// folder that was rewritten in place.
    public var modifiedAt: Date

    /// Total bytes on disk, for the download-and-pin progress display.
    public var byteCount: Int64

    public var id: String { folderName }

    public init(
        folderName: String,
        directoryURL: URL,
        pdfURL: URL? = nil,
        sourceMarkdownURL: URL? = nil,
        sourceMapURL: URL? = nil,
        metaURL: URL? = nil,
        modifiedAt: Date,
        byteCount: Int64 = 0
    ) {
        self.folderName = folderName
        self.directoryURL = directoryURL
        self.pdfURL = pdfURL
        self.sourceMarkdownURL = sourceMarkdownURL
        self.sourceMapURL = sourceMapURL
        self.metaURL = metaURL
        self.modifiedAt = modifiedAt
        self.byteCount = byteCount
    }

    /// True when there is something to ingest at all.
    public var isIngestible: Bool { pdfURL != nil || sourceMarkdownURL != nil }
}

/// Something changed in the watched folder.
///
/// What one scan of `inbox/` found, and what it could not read.
///
/// `InboxScanning.scan(_:knownFolderNames:)` used to return a bare
/// `[InboxItem]`, which left it no way to say that a subdirectory had been
/// skipped — so the contract's promise that a bad folder is reported through
/// `SyncEvent.ingestFailed` could not be kept by the one type that knew. A
/// document that quietly never appears is the failure this project can least
/// afford.
public struct InboxScanResult: Sendable, Hashable {

    /// One subdirectory the scan could not turn into an item, and why.
    ///
    /// A directory holding nothing ingestible — no `document.pdf` and no
    /// `source.md` — is **not** a skip. That is a directory somebody is still
    /// writing, and it is simply not there yet. A skip is a directory that
    /// could not be read at all.
    public struct Skipped: Sendable, Hashable {

        /// The subdirectory's name, which is the folder name a library error
        /// row is keyed by.
        public var folderName: String

        /// A sentence a person can read, for the error row.
        public var reason: String

        public init(folderName: String, reason: String) {
            self.folderName = folderName
            self.reason = reason
        }
    }

    /// Items in folder-name order, which is chronological given the date
    /// prefix.
    public var items: [InboxItem]

    /// Subdirectories that could not be read. Usually empty.
    public var skipped: [Skipped]

    public init(items: [InboxItem] = [], skipped: [Skipped] = []) {
        self.items = items
        self.skipped = skipped
    }

    /// Nothing found and nothing skipped.
    public static let empty = InboxScanResult()
}

/// Emitted by `FolderWatching`, consumed by Sync. Deliberately coarse: a
/// watcher's job is to say "look again", not to diff.
public enum FolderEvent: Sendable, Hashable {
    /// A directory under `inbox/` appeared or was rewritten.
    case inboxChanged(directoryURL: URL)
    /// A directory under `inbox/` went away. The document stays in the library
    /// — losing the folder costs you new documents, never existing ones
    /// (docs/02-spec.md § Cross-cutting).
    case inboxRemoved(folderName: String)
    /// `outbox/<slug>.review/reply.md` appeared (docs/04-flows.md § F6).
    case replyAppeared(reviewFolderName: String, replyURL: URL)
    /// The sync root became unreachable — ejected volume, revoked bookmark,
    /// provider signed out. Reading and annotating carry on regardless.
    case folderUnavailable(reason: String)
    /// The root came back.
    case folderRestored
}

/// What Sync tells the UI.
public enum SyncEvent: Sendable, Hashable {
    /// A scan started. `pending` is how many folders will be examined.
    case scanStarted(pending: Int)
    /// One document finished ingesting and is in the library.
    case ingested(documentId: UUID, title: String)
    /// One folder could not be ingested. Surfaced as an error row, never as a
    /// disappearance.
    case ingestFailed(folderName: String, reason: String)
    /// A scan finished. `ingestedCount` may be zero.
    case scanFinished(ingestedCount: Int)
    /// A review bundle reached `outbox/`.
    case reviewWritten(documentId: UUID, directoryURL: URL)
    /// A reply arrived for a review we sent.
    case replyReceived(documentId: UUID, replyURL: URL)
    /// Pass-through of a folder-level problem.
    case folderUnavailable(reason: String)
}

// MARK: - Export

/// Everything the review sheet has collected, ready to become a bundle.
///
/// One parameter to `ReviewBundleBuilding.build(_:)` on purpose: a builder that
/// takes seven arguments is a builder two agents will call differently.
public struct ReviewDraft: Sendable, Hashable {

    public var documentId: UUID

    /// `meta.json`'s id, for `review.json`'s `documentId` field. Falls back to
    /// `documentId.uuidString` when there was no external id.
    public var externalDocumentId: String

    public var documentTitle: String

    /// `YYYY-MM-DD-<slug>` of the source document. The bundle directory is this
    /// plus `.review`.
    public var folderName: String

    /// The pinned PDF, needed to render page content beneath the ink.
    public var pdfURL: URL

    /// The markdown, when there was one — used to re-resolve anchors before
    /// writing, so the ranges in `review.json` are checked, not assumed.
    public var sourceMarkdownURL: URL?

    public var sourceMap: SourceMap?

    /// When the user pressed Send.
    public var reviewedAt: Date

    /// Reading time, for the review sheet subtitle. Nil when not tracked.
    public var timeSpent: TimeInterval?

    /// The closing instruction field. Empty is fine and the section is then
    /// omitted from `review.md`.
    public var closingInstruction: String

    /// In document order — page, then vertical position. The builder numbers
    /// them 1…n in this order and that numbering is what `review.md` shows.
    public var comments: [CommentSnapshot]

    /// Every page, inked or not. The builder filters: only inked pages produce
    /// images (docs/05-file-contracts.md § Ink images).
    public var pages: [PageSnapshot]

    public var include: ReviewIncludeOptions

    public var origin: Origin

    /// What the resolver decided, so `review.md`'s header can name it.
    public var returnPath: ResolvedReturnPath

    public init(
        documentId: UUID,
        externalDocumentId: String,
        documentTitle: String,
        folderName: String,
        pdfURL: URL,
        sourceMarkdownURL: URL? = nil,
        sourceMap: SourceMap? = nil,
        reviewedAt: Date,
        timeSpent: TimeInterval? = nil,
        closingInstruction: String,
        comments: [CommentSnapshot],
        pages: [PageSnapshot],
        include: ReviewIncludeOptions,
        origin: Origin,
        returnPath: ResolvedReturnPath
    ) {
        self.documentId = documentId
        self.externalDocumentId = externalDocumentId
        self.documentTitle = documentTitle
        self.folderName = folderName
        self.pdfURL = pdfURL
        self.sourceMarkdownURL = sourceMarkdownURL
        self.sourceMap = sourceMap
        self.reviewedAt = reviewedAt
        self.timeSpent = timeSpent
        self.closingInstruction = closingInstruction
        self.comments = comments
        self.pages = pages
        self.include = include
        self.origin = origin
        self.returnPath = returnPath
    }

    /// Pages carrying ink, in page order. What the ink cropper is handed.
    public var inkedPages: [PageSnapshot] {
        pages.filter { $0.hasInk && $0.drawingData != nil }.sorted { $0.pageIndex < $1.pageIndex }
    }
}

/// One cropped page of ink, ready to be written.
public struct InkImage: Sendable, Hashable {

    public var pageIndex: Int

    /// Bundle-relative path, always `ink/page-NN.png` with a **one-based**,
    /// zero-padded page number: `pageIndex` 0 is `ink/page-01.png`. Build it
    /// with `InkImage.fileName(forPageIndex:)`, never by hand.
    public var relativePath: String

    public var pngData: Data

    /// Recognised handwriting for this page, copied through into
    /// `review.json`'s `inkPages[].recognisedText`.
    public var recognisedText: String?

    public init(pageIndex: Int, relativePath: String, pngData: Data, recognisedText: String? = nil) {
        self.pageIndex = pageIndex
        self.relativePath = relativePath
        self.pngData = pngData
        self.recognisedText = recognisedText
    }

    /// `ink/page-01.png` for `pageIndex` 0. Pads to two digits, then grows.
    public static func fileName(forPageIndex pageIndex: Int) -> String {
        let oneBased = pageIndex + 1
        let padded = oneBased < 10 ? "0\(oneBased)" : "\(oneBased)"
        return "\(inkDirectoryName)/page-\(padded).png"
    }

    public static let inkDirectoryName = "ink"

    /// Padding added around the union of the stroke bounds, per side, as a
    /// fraction of the union's size (docs/05-file-contracts.md § Ink images).
    public static let paddingFraction = 0.15

    /// Long-edge cap in pixels for the exported PNG.
    public static let maxLongEdgePixels = 2048
}

/// A bundle rendered to bytes, not yet on disk.
///
/// The split matters: the builder knows the format, the writer knows atomicity.
/// Neither needs the other's knowledge, and the builder stays testable without
/// a filesystem.
public struct OutboxPayload: Sendable, Hashable {

    /// Directory name under `outbox/`, always `<document folder name>.review`.
    public var directoryName: String

    public var documentId: UUID

    /// Every file, in write order. Paths are bundle-relative and may contain a
    /// subdirectory (`ink/page-01.png`); the writer creates intermediates.
    public var files: [BundleFile]

    public init(directoryName: String, documentId: UUID, files: [BundleFile]) {
        self.directoryName = directoryName
        self.documentId = documentId
        self.files = files
    }

    /// `<folderName>.review`. The only place this suffix is spelled.
    public static func directoryName(forDocumentFolder folderName: String) -> String {
        folderName + reviewDirectorySuffix
    }

    public static let reviewDirectorySuffix = ".review"
}

/// One file inside a bundle.
public struct BundleFile: Sendable, Hashable {

    /// Bundle-relative, forward slashes, no leading slash. e.g. `review.md`,
    /// `ink/page-01.png`.
    public var relativePath: String

    public var data: Data

    public init(relativePath: String, data: Data) {
        self.relativePath = relativePath
        self.data = data
    }
}

/// Where a bundle landed.
public struct WrittenReview: Sendable, Hashable {

    public var documentId: UUID

    /// The final directory, after the atomic rename.
    public var directoryURL: URL

    public var directoryName: String
    public var writtenAt: Date
    public var fileCount: Int

    /// Total bytes written, for the Sent screen's progress line.
    public var byteCount: Int64

    /// True when the folder was unreachable and the bundle went to the local
    /// queue instead of `outbox/` (docs/04-flows.md § F7).
    ///
    /// `directoryURL` then points inside the app container, not at the sync
    /// folder, and the Sent screen says "will send when online" rather than
    /// "sent". The two outcomes used to be indistinguishable in this value, so
    /// the UI raced `SyncCoordinating.events()` to work out which had happened
    /// — a race whose losing side is a screen claiming a review was delivered
    /// when it is sitting in a queue. The event stream still reports the
    /// *later* write when the folder comes back; this reports what happened
    /// just now.
    public var isQueued: Bool

    public init(
        documentId: UUID,
        directoryURL: URL,
        directoryName: String,
        writtenAt: Date,
        fileCount: Int,
        byteCount: Int64,
        isQueued: Bool = false
    ) {
        self.documentId = documentId
        self.directoryURL = directoryURL
        self.directoryName = directoryName
        self.writtenAt = writtenAt
        self.fileCount = fileCount
        self.byteCount = byteCount
        self.isQueued = isQueued
    }
}

/// What the destination row shows, and what the sender acts on.
///
/// The user sees this before committing — it is the only place they learn
/// whether context is preserved (docs/02-spec.md § S4). Resolving to `.none` is
/// a normal outcome with a good fallback, not a failure.
public struct ResolvedReturnPath: Sendable, Hashable {

    public var type: ReturnPathType

    /// Origin name for the destination row, e.g. "Cowork".
    public var displayName: String

    /// The conversation's title, when known.
    public var threadTitle: String?

    /// The session to deliver into, when known.
    public var sessionId: String?

    /// The scheduled task to fire, for `.poke` and `.checkin`.
    public var triggerId: String?

    /// Drives the SAME THREAD / NEW THREAD badge. Not merely
    /// `type.isSameThread`: a `.resume` path with no session id cannot preserve
    /// context, so the resolver sets this false even though the type says
    /// otherwise. Trust this field, not the type.
    public var sameThread: Bool

    public init(
        type: ReturnPathType,
        displayName: String,
        threadTitle: String? = nil,
        sessionId: String? = nil,
        triggerId: String? = nil,
        sameThread: Bool
    ) {
        self.type = type
        self.displayName = displayName
        self.threadTitle = threadTitle
        self.sessionId = sessionId
        self.triggerId = triggerId
        self.sameThread = sameThread
    }

    /// The "no thread" resolution. The Sent screen offers copy / share / save.
    public static let unresolved = ResolvedReturnPath(
        type: .none,
        displayName: "No return path",
        sameThread: false
    )

    /// Badge text, exactly as shown.
    public var badgeText: String { sameThread ? "SAME THREAD" : "NEW THREAD" }
}
