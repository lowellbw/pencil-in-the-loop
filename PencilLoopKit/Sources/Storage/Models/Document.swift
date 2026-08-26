//
//  Document.swift
//  Storage · Models
//
//  The library row. Follows docs/03-architecture.md § Data model, adjusted where
//  the frozen contracts in Core/Contracts require it — the contracts are
//  authoritative and docs/03 predates them.
//
//  Deviations from docs/03, all deliberate:
//
//  • `origin` is stored as six flat columns rather than an `Origin` value.
//    `Origin` has a hand-written `init(from:)` that never throws and degrades to
//    `.manual`; handing that to SwiftData's Codable attribute machinery gets us a
//    blob that cannot be queried and a decoder we no longer control. Flat columns
//    are queryable, migratable and boring. `origin` is a computed accessor.
//  • Enum-valued columns store `rawValue` strings for the same reason: `DocState`
//    and friends have custom decoders, and a `#Predicate` can compare a String.
//  • `folderPath` from docs/03 is `relativePath` here, to match
//    `IngestedDocument.relativePath`.
//  • `readingSeconds` is new: the review sheet shows time spent
//    (docs/02-spec.md § S4) and `ReviewDraft.timeSpent` needs a source.
//  • `pinnedAt` is new: pinning is orthogonal to `DocState` and needed a column
//    of its own rather than a fourth state (docs/02-spec.md § S1).
//  • `refreshFailureReason` / `refreshFailedAt` are new: a failed re-ingest of a
//    document whose pinned bytes are intact is a failed *refresh*, not a lost
//    document, and it needs somewhere to live that is not `localState`. See
//    `DocumentStore.recordIngestFailure(folderName:reason:)`.
//
//  Internal, not public. `@Model` types never cross an actor boundary
//  (STYLE.md § 6, DTOs.swift header), and the cheapest way to guarantee that is
//  to make them unspellable outside this module.
//

import Foundation
import SwiftData
import Core

/// One document in the library, and everything persisted about it.
@Model
final class Document {

    // MARK: Identity

    /// Minted by Ingest, stable across re-ingests of the same folder.
    @Attribute(.unique) var id: UUID

    /// `meta.json`'s id verbatim when it was not a UUID. Nil otherwise.
    var externalId: String?

    /// `YYYY-MM-DD-<slug>` under `inbox/`. The identity a re-sent document is
    /// matched on, so it is unique too.
    @Attribute(.unique) var folderName: String

    /// Path relative to the sync root, e.g. `inbox/2026-08-18-auth-refactor-plan`.
    var relativePath: String

    var title: String

    // MARK: Pinned bytes

    /// Path of `document.pdf` relative to `StorageLocations.documentsRoot()`,
    /// or an absolute path when the document was pinned outside it. Empty for a
    /// row recorded by `recordIngestFailure`.
    var pdfPath: String

    /// Same encoding as `pdfPath`, for `source.md`. Nil for an imported PDF.
    var sourceMarkdownPath: String?

    /// `sourcemap.json`, encoded with `ContractCoding.encoder()`. Nil for an
    /// imported PDF. External because a fine-grained map for a long document is
    /// hundreds of kilobytes and no library fetch needs it.
    @Attribute(.externalStorage) var sourceMapData: Data?

    // MARK: Content

    var pageCount: Int

    /// Full document text, for search and for the speech term list.
    ///
    /// External storage is not an optimisation here, it is the difference
    /// between a library fetch that reads a thousand rows and one that reads a
    /// thousand rows plus a thousand novels.
    ///
    /// **Checked on the Mac, and it stands.** `.externalStorage` maps to Core
    /// Data's `allowsExternalBinaryDataStorage`, which is defined for binary
    /// attributes only, so the worry was that SwiftData would validate it the
    /// way Core Data historically has and throw out of `LibraryContainer.make()`
    /// at launch. On the iOS 26.5 SDK it does not: the container builds and all
    /// of `StorageTests` passes.
    ///
    /// The second half of the question is the one that could have failed
    /// quietly rather than loudly — whether a value big enough to really be
    /// spilled out of the row is still reachable from the `#Predicate` in
    /// `LibraryFetch`, or whether search stops working for exactly the long
    /// documents it matters most for. It is reachable;
    /// `testSearchReachesTextLongEnoughToBeStoredOutsideTheRow` holds half a
    /// megabyte of text and finds a phrase at the end of it.
    ///
    /// Keep both facts together if this is ever revisited. The remedy, if a
    /// later SDK does throw: delete the attribute — a plain `String` column is
    /// correct and search keeps working — and only if library-fetch memory then
    /// proves to be a problem, move to `Data` plus a computed accessor, which
    /// takes the column out of the predicate and turns the one-round-trip search
    /// docs/02-spec.md § S1 asks for into a two-stage in-memory filter. That is
    /// not a trade to make blind.
    @Attribute(.externalStorage) var extractedText: String

    /// `SourceFormat.rawValue`.
    var sourceFormatRaw: String

    // MARK: Origin (see the file header for why this is flat)

    /// `OriginKind.rawValue`.
    var originKindRaw: String
    var originSessionId: String?
    var originThreadTitle: String?
    /// `ReturnPathType.rawValue`. Nil when `meta.json` named no return path.
    var returnPathTypeRaw: String?
    var returnPathTriggerId: String?
    var returnPathDetail: String?

    // MARK: Lifecycle

    /// When the writing tool made it.
    var createdAt: Date

    /// When we ingested it. What the Library sorts by.
    var addedAt: Date

    /// `DocState.rawValue`.
    var stateRaw: String

    /// `DocumentLocalState` decomposed: an enum with associated values cannot be
    /// a stored attribute, so the three cases become a tag, a progress and a
    /// reason. `localState` recomposes them.
    var localStateRaw: String
    var localStateProgress: Double?
    var localStateReason: String?

    /// When the user pinned this document, or nil when it is not pinned
    /// (docs/02-spec.md § S1).
    ///
    /// **A date rather than a `Bool`, at no extra cost.** `pinnedAt == nil` is
    /// the flag, so nothing is given up, and the moment is there if the Pinned
    /// section ever wants its own order. It does not want one today: the
    /// section follows whatever the sort menu says, because a Sort control that
    /// visibly does not apply to the top section is worse than a pin order
    /// nobody asked for (`LibraryModel.pinned`).
    ///
    /// Deliberately not a `DocState` case. Pinning must not make a document
    /// forget whether it has been read (DTOs.swift § `DocumentSummary.isPinned`).
    var pinnedAt: Date?

    /// Restored on open (docs/02-spec.md § S2).
    var lastReadPage: Int

    /// Accumulated reading time in seconds, for the review sheet's "time spent"
    /// subtitle. Added to by `DocumentStore.addReadingSeconds(_:documentId:)`.
    var readingSeconds: Double

    // MARK: Refresh

    /// Why the most recent attempt to ingest this folder failed, or nil when
    /// the last attempt succeeded.
    ///
    /// Separate from `localState` on purpose. A failed *refresh* of a document
    /// whose pinned bytes are still on disk does not make the document
    /// unreadable — the pin either replaced the previous copy or rolled it back
    /// (`InboxItemPinner`) — so the row keeps `.local` and carries this note
    /// instead. Writing `.unavailable` there would dim a row the user could
    /// read offline yesterday, which docs/02-spec.md § Cross-cutting forbids.
    var refreshFailureReason: String?

    /// When `refreshFailureReason` was recorded. Nil when there is no failure.
    var refreshFailedAt: Date?

    // MARK: Review lifecycle

    var reviewSentAt: Date?
    /// `<folderName>.review`, the directory the bundle landed in.
    var reviewDirectoryName: String?
    /// The agent's `reply.md` (docs/04-flows.md § F6).
    var replyText: String?
    var replyReceivedAt: Date?

    // MARK: Denormalised counters

    /// Kept in step by `DocumentStore.refreshCounters(_:)`. Denormalised because
    /// the Library's cold-launch budget is one second for the whole screen
    /// (docs/03-architecture.md § Performance targets) and counting comments by
    /// faulting in every relationship on every row is how that budget goes.
    var commentCount: Int
    var inkedPageCount: Int

    // MARK: Relationships

    /// Only pages that carry something are stored; an untouched page has no row
    /// (see `DocumentStore.pages(documentId:)`, which synthesises the gaps).
    @Relationship(deleteRule: .cascade, inverse: \Page.document)
    var pages: [Page]

    /// Includes soft-deleted comments. Every read filters them out; the undo
    /// stack is what brings one back (docs/02-spec.md § Cross-cutting).
    @Relationship(deleteRule: .cascade, inverse: \Comment.document)
    var comments: [Comment]

    init(
        id: UUID,
        externalId: String? = nil,
        folderName: String,
        relativePath: String,
        title: String,
        pdfPath: String,
        sourceMarkdownPath: String? = nil,
        sourceMapData: Data? = nil,
        pageCount: Int,
        extractedText: String,
        sourceFormatRaw: String,
        originKindRaw: String,
        originSessionId: String? = nil,
        originThreadTitle: String? = nil,
        returnPathTypeRaw: String? = nil,
        returnPathTriggerId: String? = nil,
        returnPathDetail: String? = nil,
        createdAt: Date,
        addedAt: Date,
        stateRaw: String = DocState.unread.rawValue,
        localStateRaw: String = Document.localStateLocal,
        localStateProgress: Double? = nil,
        localStateReason: String? = nil,
        pinnedAt: Date? = nil,
        lastReadPage: Int = 0,
        readingSeconds: Double = 0,
        commentCount: Int = 0,
        inkedPageCount: Int = 0,
        refreshFailureReason: String? = nil,
        refreshFailedAt: Date? = nil
    ) {
        self.id = id
        self.externalId = externalId
        self.folderName = folderName
        self.relativePath = relativePath
        self.title = title
        self.pdfPath = pdfPath
        self.sourceMarkdownPath = sourceMarkdownPath
        self.sourceMapData = sourceMapData
        self.pageCount = pageCount
        self.extractedText = extractedText
        self.sourceFormatRaw = sourceFormatRaw
        self.originKindRaw = originKindRaw
        self.originSessionId = originSessionId
        self.originThreadTitle = originThreadTitle
        self.returnPathTypeRaw = returnPathTypeRaw
        self.returnPathTriggerId = returnPathTriggerId
        self.returnPathDetail = returnPathDetail
        self.createdAt = createdAt
        self.addedAt = addedAt
        self.stateRaw = stateRaw
        self.localStateRaw = localStateRaw
        self.localStateProgress = localStateProgress
        self.localStateReason = localStateReason
        self.pinnedAt = pinnedAt
        self.lastReadPage = lastReadPage
        self.readingSeconds = readingSeconds
        self.commentCount = commentCount
        self.inkedPageCount = inkedPageCount
        self.refreshFailureReason = refreshFailureReason
        self.refreshFailedAt = refreshFailedAt
        self.pages = []
        self.comments = []
    }

    // MARK: - Local-state tags

    static let localStateLocal = "local"
    static let localStateDownloading = "downloading"
    static let localStateUnavailable = "unavailable"
}

// MARK: - Computed vocabulary
//
// Computed properties are not persisted by SwiftData, so these are free: they
// turn the flat columns above back into the frozen Core types and take them
// apart again on the way in.

extension Document {

    /// `stateRaw` as the frozen enum. Unknown raw values read as `.unread`,
    /// matching `DocState`'s own decoder.
    var state: DocState {
        get { DocState(rawValue: stateRaw) ?? .unread }
        set { stateRaw = newValue.rawValue }
    }

    /// `sourceFormatRaw` as the frozen enum, `.unknown` for anything else.
    var sourceFormat: SourceFormat {
        get { SourceFormat(rawValue: sourceFormatRaw) ?? .unknown }
        set { sourceFormatRaw = newValue.rawValue }
    }

    /// The three local states, recomposed. Anything unrecognised reads as
    /// `.local`, because a row we cannot classify is still a row whose bytes we
    /// believe we have.
    var localState: DocumentLocalState {
        get {
            switch localStateRaw {
            case Document.localStateDownloading:
                return .downloading(progress: localStateProgress)
            case Document.localStateUnavailable:
                return .unavailable(reason: localStateReason ?? "")
            default:
                return .local
            }
        }
        set {
            switch newValue {
            case .local:
                localStateRaw = Document.localStateLocal
                localStateProgress = nil
                localStateReason = nil
            case let .downloading(progress):
                localStateRaw = Document.localStateDownloading
                localStateProgress = progress
                localStateReason = nil
            case let .unavailable(reason):
                localStateRaw = Document.localStateUnavailable
                localStateProgress = nil
                localStateReason = reason
            }
        }
    }

    /// The `origin` object from `meta.json`, rebuilt from its columns.
    var origin: Origin {
        get {
            var path: ReturnPath?
            if let typeRaw = returnPathTypeRaw {
                path = ReturnPath(
                    type: ReturnPathType(rawValue: typeRaw) ?? .none,
                    triggerId: returnPathTriggerId,
                    detail: returnPathDetail
                )
            }
            return Origin(
                kind: OriginKind(rawValue: originKindRaw) ?? .manual,
                sessionId: originSessionId,
                threadTitle: originThreadTitle,
                returnPath: path
            )
        }
        set {
            originKindRaw = newValue.kind.rawValue
            originSessionId = newValue.sessionId
            originThreadTitle = newValue.threadTitle
            returnPathTypeRaw = newValue.returnPath?.type.rawValue
            returnPathTriggerId = newValue.returnPath?.triggerId
            returnPathDetail = newValue.returnPath?.detail
        }
    }

    /// The pinned `document.pdf`, or nil when this row has no pinned bytes.
    ///
    /// A row recorded by `recordIngestFailure(folderName:reason:)` has an empty
    /// `pdfPath`: the folder was seen and could not be ingested, so there is a
    /// library row and no document behind it. Nil is the honest answer, and it
    /// is what stops a reader handing PDFKit the documents root itself.
    var pdfURL: URL? {
        StorageLocations.url(forStoredPath: pdfPath)
    }

    /// Whether the pinned `document.pdf` this row names is still on disk.
    ///
    /// The question `DocumentStore.recordIngestFailure(folderName:reason:)`
    /// turns on: a row whose bytes are here stays readable however badly the
    /// next refresh went, so the failure is recorded as a note rather than as
    /// `.unavailable`.
    var hasPinnedBytes: Bool {
        guard let url = pdfURL else { return false }
        return FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
    }

    /// The pinned `source.md`, when there was one.
    var sourceMarkdownURL: URL? {
        guard let path = sourceMarkdownPath, !path.isEmpty else { return nil }
        return StorageLocations.url(forStoredPath: path)
    }

    /// `sourcemap.json`, decoded.
    ///
    /// - Returns: nil when there is no map and also when the stored bytes will
    ///   not decode. A broken source map costs precision in anchor resolution;
    ///   it must never cost the document.
    var sourceMap: SourceMap? {
        guard let data = sourceMapData else { return nil }
        return try? ContractCoding.decoder().decode(SourceMap.self, from: data)
    }

    /// Comments the user can still see, in document order: page, then vertical
    /// position on the page, then creation time.
    var visibleComments: [Comment] {
        comments
            .filter { $0.deletedAt == nil }
            .sorted { lhs, rhs in
                if lhs.resolvedOnPage != rhs.resolvedOnPage {
                    return lhs.resolvedOnPage < rhs.resolvedOnPage
                }
                let lhsY = lhs.anchorRectY
                let rhsY = rhs.anchorRectY
                if lhsY != rhsY { return lhsY < rhsY }
                return lhs.createdAt < rhs.createdAt
            }
    }

    /// Stored page rows in page order. Pages with nothing on them have no row.
    var storedPages: [Page] {
        pages.sorted { $0.pageIndex < $1.pageIndex }
    }
}

// MARK: - Snapshots
//
// The only way anything about a Document leaves this module.

extension Document {

    /// One Library row.
    func summary() -> DocumentSummary {
        DocumentSummary(
            id: id,
            title: title,
            originDisplayName: origin.kind.displayName,
            addedAt: addedAt,
            pageCount: pageCount,
            state: state,
            localState: localState,
            commentCount: commentCount,
            hasInk: inkedPageCount > 0,
            folderName: folderName,
            pinnedAt: pinnedAt,
            refreshFailureReason: summaryRefreshFailureReason
        )
    }

    /// The refresh note a row carries, or nil when it has nothing to add.
    ///
    /// `recordIngestFailure(folderName:reason:)` records the reason on every
    /// failure and *additionally* goes `.unavailable` when there are no pinned
    /// bytes, so a dimmed row holds the same sentence twice. The row that has
    /// something new to say is the readable one: it opens, and it did not
    /// update (DTOs.swift § `DocumentSummary.refreshFailureReason`).
    private var summaryRefreshFailureReason: String? {
        if case .unavailable = localState { return nil }
        guard let reason = refreshFailureReason, reason.isEmpty == false else { return nil }
        return reason
    }

    /// Everything the reader needs, in one value.
    func detail() -> DocumentDetail {
        DocumentDetail(
            id: id,
            title: title,
            folderName: folderName,
            pdfURL: pdfURL,
            sourceMarkdownURL: sourceMarkdownURL,
            sourceMap: sourceMap,
            pageCount: pageCount,
            state: state,
            origin: origin,
            addedAt: addedAt,
            lastReadPage: lastReadPage,
            extractedText: extractedText,
            pages: pageSnapshots(),
            comments: visibleComments.map { $0.snapshot() }
        )
    }

    /// Every page 0..<`pageCount`, in order, whether or not it has a row.
    ///
    /// The reader asks for a page's ink by index and expects an answer for every
    /// index; storing a row per untouched page would mean tens of thousands of
    /// empty rows for a library that has never been drawn on.
    func pageSnapshots() -> [PageSnapshot] {
        var byIndex: [Int: Page] = [:]
        for page in pages {
            byIndex[page.pageIndex] = page
        }
        let highestStored = pages.map(\.pageIndex).max() ?? -1
        let upperBound = max(pageCount, highestStored + 1)
        guard upperBound > 0 else { return [] }
        return (0..<upperBound).map { index in
            byIndex[index]?.snapshot() ?? PageSnapshot(pageIndex: index)
        }
    }
}
