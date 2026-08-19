//
//  AppEnvironment.swift
//  AppUI · Support
//
//  The only file W0-B places outside Core. It is here because it names AppUI's
//  dependencies, and Core must not know that AppUI exists.
//
//  Every view reaches its dependencies through this one protocol. No view
//  constructs a store, a transcriber or a bundle builder, and no view takes six
//  initialiser parameters that three call sites have to keep in step.
//
//  ─── HOW IT IS PASSED ────────────────────────────────────────────────────────
//  Through `init`, not through the SwiftUI environment. The header here used to
//  show a `\.appEnvironment` EnvironmentKey; no unit declared one and all four
//  injected the environment explicitly instead, so the key is gone rather than
//  half-present. Explicit injection is also what makes every screen previewable
//  without a host: a view that reads a key can be handed the wrong one, and a
//  view with a parameter cannot be built at all without it.
//
//      @main struct PencilLoopApp: App {
//          @State private var root = RootModel()
//          var body: some Scene {
//              WindowGroup { RootView(model: root) }
//          }
//      }
//
//  and in a preview:
//
//      #Preview { LibraryView(environment: PreviewEnvironment()) { … } }
//
//  `LiveEnvironment` (AppUI/Support) is the real one, built once at launch.
//  `PreviewEnvironment` below conforms with inert stubs, so every screen can be
//  previewed on a Mac with no device, no folder and no microphone. The stubs
//  return empty values and do nothing; they never fail, never block and never
//  touch the filesystem.
//  ─────────────────────────────────────────────────────────────────────────────
//
//  NOTE ON `nonisolated`: the AppUI target is compiled with
//  `.defaultIsolation(MainActor.self)`, so every type declared here is main-actor
//  bound unless it says otherwise. The protocols in Core are nonisolated, so the
//  stubs' members are marked `nonisolated` explicitly to satisfy them. Real
//  implementations live in their own modules and need none of this.
//

import Foundation
import Core

/// Everything the UI is allowed to depend on.
///
/// Adding a property here is a change request to the lead: it means a screen
/// needs a capability no module currently exposes, which is a design decision,
/// not a plumbing one.
public protocol AppEnvironment: Sendable {

    /// The library. Reads return snapshots; writes take drafts. See DTOs.swift.
    var store: any DocumentStoring { get }

    /// Watching, scanning, ingesting and the outbox write.
    var sync: any SyncCoordinating { get }

    /// On-device dictation for the comment popover. Check `assetState()` before
    /// offering it, and fall back to scribble when it is unavailable — never a
    /// modal, never a blocker.
    var transcriber: any SpeechTranscribing { get }

    /// Ink to text, for search and for the review bundle. Returns nil freely;
    /// nothing in the UI may wait on it.
    var recogniser: any HandwritingRecognising { get }

    /// Builds the document's term list and repairs the transcript against it.
    ///
    /// Terms are derived on demand from `DocumentDetail.extractedText` and its
    /// title, not stored: they are cheap, they are only wanted while the
    /// comment popover is open, and a copy persisted at ingest would be stale
    /// the moment the document was re-sent. Pure and total — there is no
    /// failure mode (Protocols.swift § TranscriptCorrecting).
    var corrector: any TranscriptCorrecting { get }

    /// Turns a `ReviewDraft` into the bytes of a bundle. The review sheet builds
    /// the draft; this makes it sendable.
    var bundleBuilder: any ReviewBundleBuilding { get }

    /// Works out what the destination row says, before the user commits.
    var returnPathResolver: any ReturnPathResolving { get }

    /// Persisted user settings (docs/02-spec.md § S6).
    var settings: any SettingsStoring { get }

    /// Security-scoped access to the user's sync folder.
    ///
    /// Here because two screens need `prepareFolder(at:)` and there was no
    /// route to it: first run (docs/02-spec.md § S0) *is* the folder picker,
    /// and Settings § S6 changes it. Both took it as an extra initialiser
    /// parameter as a stopgap, which meant three views with two dependencies
    /// each and three call sites to keep in step.
    ///
    /// Everything else the folder is needed for — scanning, pinning, writing —
    /// belongs to `sync`, which holds its own access. A view should reach for
    /// this only to adopt a folder the user has just picked, and
    /// `SyncFolderChoice.adopt(_:folderAccess:settings:)` is the one place that
    /// happens.
    var folderAccess: any FolderAccessing { get }

    /// Point the app's sync loop at a folder the user has just chosen, and
    /// start it.
    ///
    /// The other half of `SyncFolderChoice.adopt(_:folderAccess:settings:)`:
    /// that persists the bookmark, this is what makes documents start arriving.
    /// Both first run (§ S0) and Settings (§ S6) call it, because a folder
    /// chosen in Settings that only takes effect after a relaunch is a folder
    /// the user will assume did not work.
    ///
    /// **On failure:** nothing to report. Attaching cannot fail — a folder that
    /// turns out to be unreachable surfaces as `SyncEvent.folderUnavailable` in
    /// the library's status line, which is where a folder problem belongs.
    /// Idempotent: adopting the same folder twice replaces the first
    /// coordinator rather than running two.
    func adoptFolder(_ folder: SyncFolder) async
}

/// An `AppEnvironment` whose every dependency does nothing.
///
/// For SwiftUI previews and for UI work that starts before the modules behind it
/// land. Seed it with sample rows to preview a populated library:
///
///     PreviewEnvironment(summaries: DocumentSummary.previewSamples)
///
/// Nothing here touches the disk, the network, the microphone or the pencil.
public struct PreviewEnvironment: AppEnvironment {

    public let store: any DocumentStoring
    public let sync: any SyncCoordinating
    public let transcriber: any SpeechTranscribing
    public let recogniser: any HandwritingRecognising
    public let corrector: any TranscriptCorrecting
    public let bundleBuilder: any ReviewBundleBuilding
    public let returnPathResolver: any ReturnPathResolving
    public let settings: any SettingsStoring
    public let folderAccess: any FolderAccessing

    /// - Parameters:
    ///   - summaries: rows the previewed library shows.
    ///   - detail: what the previewed reader opens, if anything.
    ///   - speechAssetState: lets a preview show the "downloading assets"
    ///     Settings row without a device.
    public init(
        summaries: [DocumentSummary] = [],
        detail: DocumentDetail? = nil,
        speechAssetState: SpeechAssetState = .ready,
        settings: AppSettings = .initial
    ) {
        self.store = PreviewDocumentStore(summaries: summaries, detail: detail)
        self.sync = PreviewSyncCoordinator()
        self.transcriber = PreviewSpeechTranscriber(state: speechAssetState)
        self.recogniser = PreviewHandwritingRecogniser()
        self.corrector = PreviewTranscriptCorrector()
        self.bundleBuilder = PreviewReviewBundleBuilder()
        self.returnPathResolver = PreviewReturnPathResolver()
        self.settings = PreviewSettingsStore(settings: settings)
        self.folderAccess = PreviewFolderAccess()
    }

    /// Nothing to attach: a preview's folder is imaginary and its sync
    /// coordinator never finds anything.
    public func adoptFolder(_ folder: SyncFolder) async {}
}

// MARK: - Inert stubs

/// A store that holds whatever it was given and accepts every write silently.
public actor PreviewDocumentStore: DocumentStoring {

    private var storedSummaries: [DocumentSummary]
    private var storedDetail: DocumentDetail?

    public init(summaries: [DocumentSummary] = [], detail: DocumentDetail? = nil) {
        self.storedSummaries = summaries
        self.storedDetail = detail
    }

    public func summaries(_ query: LibraryQuery) throws -> [DocumentSummary] {
        guard let text = query.searchText, !text.isEmpty else { return storedSummaries }
        return storedSummaries.filter { $0.title.localizedCaseInsensitiveContains(text) }
    }

    public func summary(id: UUID) throws -> DocumentSummary? {
        storedSummaries.first { $0.id == id }
    }

    public func detail(id: UUID) throws -> DocumentDetail? {
        // Previews hold at most one document, and a preview asking for a
        // different id still wants to see something rather than an empty screen.
        storedDetail
    }

    public func knownFolderNames() throws -> Set<String> {
        Set(storedSummaries.map(\.folderName))
    }

    public func documentId(forFolderName folderName: String) throws -> UUID? {
        storedSummaries.first { $0.folderName == folderName }?.id
    }

    @discardableResult
    public func upsert(_ document: IngestedDocument) throws -> DocumentSummary {
        let summary = DocumentSummary(
            id: document.id,
            title: document.title,
            originDisplayName: document.origin.kind.displayName,
            addedAt: document.addedAt,
            pageCount: document.pageCount,
            state: .unread,
            localState: .local,
            commentCount: 0,
            hasInk: false,
            folderName: document.folderName
        )
        storedSummaries.append(summary)
        return summary
    }

    public func recordIngestFailure(folderName: String, reason: String) throws {}

    public func setState(_ state: DocState, documentId: UUID) throws {}

    public func setLastReadPage(_ pageIndex: Int, documentId: UUID) throws {}

    public func setLocalState(_ state: DocumentLocalState, documentId: UUID) throws {}

    public func saveDrawing(_ drawingData: Data?, pageIndex: Int, documentId: UUID) throws {}

    public func saveRecognisedInk(_ text: String?, pageIndex: Int, documentId: UUID) throws {}

    public func pages(documentId: UUID) throws -> [PageSnapshot] {
        storedDetail?.pages ?? []
    }

    public func drawingData(pageIndex: Int, documentId: UUID) throws -> Data? {
        storedDetail?.pages.first { $0.pageIndex == pageIndex }?.drawingData
    }

    @discardableResult
    public func addComment(_ draft: CommentDraft, documentId: UUID) throws -> CommentSnapshot {
        CommentSnapshot(
            id: UUID(),
            createdAt: Date(timeIntervalSince1970: 0),
            text: draft.text,
            source: draft.source,
            anchor: draft.anchor,
            resolvedOnPage: draft.resolvedOnPage
        )
    }

    public func updateComment(id: UUID, text: String) throws {}

    public func deleteComment(id: UUID) throws {}

    /// Nothing was deleted, so there is nothing to restore. A preview exercises
    /// the "nothing to undo" branch, which is a state the UI must handle.
    @discardableResult
    public func undoLastCommentDeletion() throws -> CommentSnapshot? { nil }

    public func comments(documentId: UUID) throws -> [CommentSnapshot] {
        storedDetail?.comments ?? []
    }

    public func recordReviewSent(documentId: UUID, at date: Date, directoryName: String) throws {}

    public func recordReply(documentId: UUID, text: String, receivedAt: Date) throws {}

    /// A preview has never sent a review, so every field is nil — which is the
    /// state the review sheet spends most of its life in and the one worth
    /// previewing. Seed `detail` and drive the sent screen from
    /// `ReviewPreviewData` for the other one.
    public func reviewStatus(documentId: UUID) throws -> ReviewStatus? {
        ReviewStatus(documentId: documentId)
    }

    public func addReadingSeconds(_ seconds: TimeInterval, documentId: UUID) throws {}

    public func readingSeconds(documentId: UUID) throws -> TimeInterval { 0 }

    public func storageBytes() throws -> Int64 { 0 }

    public func purgeArchived() throws -> Int64 { 0 }
}

/// A sync coordinator that never finds anything and never writes anything.
public struct PreviewSyncCoordinator: SyncCoordinating {

    public init() {}

    public nonisolated func start() async {}

    public nonisolated func stop() async {}

    public nonisolated func refresh() async throws -> Int { 0 }

    public nonisolated func events() -> AsyncStream<SyncEvent> {
        AsyncStream { continuation in continuation.finish() }
    }

    public nonisolated func send(_ payload: OutboxPayload) async throws -> WrittenReview {
        WrittenReview(
            documentId: payload.documentId,
            directoryURL: URL(fileURLWithPath: "/dev/null"),
            directoryName: payload.directoryName,
            writtenAt: Date(timeIntervalSince1970: 0),
            fileCount: payload.files.count,
            byteCount: 0
        )
    }

    /// There are no replies in a preview, and "no reply yet" is the state the
    /// Sent screen spends most of its life in.
    @discardableResult
    public nonisolated func ingestReply(fromReviewDirectory reviewDirectoryName: String) async throws -> UUID {
        throw PencilLoopError.nothingToIngest(folderName: reviewDirectoryName)
    }
}

/// A transcriber that reports whatever state it was given and emits nothing.
public struct PreviewSpeechTranscriber: SpeechTranscribing {

    private let state: SpeechAssetState

    public init(state: SpeechAssetState = .ready) {
        self.state = state
    }

    public nonisolated func assetState() async -> SpeechAssetState { state }

    public nonisolated func prepareAssets() async {}

    public nonisolated func prewarm() async {}

    public nonisolated func transcribe(contextualTerms: [String]) -> AsyncThrowingStream<TranscriptionUpdate, Error> {
        AsyncThrowingStream { continuation in continuation.finish() }
    }

    public nonisolated func stop() async -> String { "" }

    /// Empty: the documented "this engine cannot say" answer, which is what
    /// makes the Settings picker fall back to the selected language alone. A
    /// preview that wants a full picker has no engine to ask.
    public nonisolated func supportedLocales() async -> [Locale] { [] }
}

/// A recogniser that always declines, which is a state the UI must handle
/// anyway.
public struct PreviewHandwritingRecogniser: HandwritingRecognising {

    public init() {}

    public nonisolated func recogniseText(drawingData: Data, locale: Locale) async -> RecognisedInk? { nil }

    public nonisolated func isAvailable(for locale: Locale) async -> Bool { false }
}

/// A corrector that finds no terms and corrects nothing — the "quiet document"
/// case, which is the one the popover must render without a term list.
public struct PreviewTranscriptCorrector: TranscriptCorrecting {

    public init() {}

    public nonisolated func terms(forDocumentText text: String, title: String) -> [String] { [] }

    public nonisolated func correct(_ transcript: String, against terms: [String]) -> String {
        transcript
    }
}

/// A builder that produces an empty bundle with the right shape.
public struct PreviewReviewBundleBuilder: ReviewBundleBuilding {

    public init() {}

    public nonisolated func build(_ draft: ReviewDraft) async throws -> OutboxPayload {
        OutboxPayload(
            directoryName: OutboxPayload.directoryName(forDocumentFolder: draft.folderName),
            documentId: draft.documentId,
            files: []
        )
    }

    public nonisolated func reviewMarkdown(_ draft: ReviewDraft) async throws -> String {
        "# Review — \(draft.documentTitle)\n"
    }
}

/// A resolver that applies the documented rules to whatever origin it is given,
/// so the destination row previews correctly without any I/O.
public struct PreviewReturnPathResolver: ReturnPathResolving {

    public init() {}

    public nonisolated func resolve(_ origin: Origin) -> ResolvedReturnPath {
        guard origin.kind.supportsReturnPath, let path = origin.returnPath, path.type != .none else {
            return .unresolved
        }
        return ResolvedReturnPath(
            type: path.type,
            displayName: origin.kind.displayName,
            threadTitle: origin.threadTitle,
            sessionId: origin.sessionId,
            triggerId: path.triggerId,
            sameThread: path.type.isSameThread && origin.sessionId != nil
        )
    }
}

/// Settings held in memory for the length of a preview.
public actor PreviewSettingsStore: SettingsStoring {

    public private(set) var settings: AppSettings

    public init(settings: AppSettings = .initial) {
        self.settings = settings
    }

    public func update(_ settings: AppSettings) throws {
        self.settings = settings
    }
}

// MARK: - Sample data

extension DocumentSummary {

    /// Three rows covering the three library sections, for previews.
    public static var previewSamples: [DocumentSummary] {
        [
            DocumentSummary(
                id: UUID(uuidString: "F7A1C0DE-0000-4000-8000-000000000001") ?? UUID(),
                title: "Auth refactor plan",
                originDisplayName: OriginKind.cowork.displayName,
                addedAt: Date(timeIntervalSince1970: 1_787_000_000),
                pageCount: 4,
                state: .reviewing,
                localState: .local,
                commentCount: 3,
                hasInk: true,
                folderName: "2026-08-18-auth-refactor-plan"
            ),
            DocumentSummary(
                id: UUID(uuidString: "F7A1C0DE-0000-4000-8000-000000000002") ?? UUID(),
                title: "Attention Is All You Need",
                originDisplayName: OriginKind.share.displayName,
                addedAt: Date(timeIntervalSince1970: 1_786_900_000),
                pageCount: 15,
                state: .unread,
                localState: .local,
                commentCount: 0,
                hasInk: false,
                folderName: "2026-08-17-attention-is-all-you-need"
            ),
            DocumentSummary(
                id: UUID(uuidString: "F7A1C0DE-0000-4000-8000-000000000003") ?? UUID(),
                title: "Q3 platform postmortem",
                originDisplayName: OriginKind.claudeCode.displayName,
                addedAt: Date(timeIntervalSince1970: 1_786_000_000),
                pageCount: 9,
                state: .read,
                localState: .downloading(progress: nil),
                commentCount: 7,
                hasInk: true,
                folderName: "2026-08-07-q3-platform-postmortem"
            )
        ]
    }
}
