//
//  InkPersistenceCoordinator.swift
//  Annotate · Ink
//
//  Autosave for ink, and the single source of truth for "what is the latest
//  drawing for page N of document D". Everything about this file exists to
//  satisfy two sentences: nothing blocks the touch path
//  (docs/01-design-principles.md § 10), and there is no save action and no
//  unsaved state to lose (docs/02-spec.md § S2).
//
//  ─────────────────────────────────────────────────────────────────────────────
//  WHY A DEBOUNCE CANNOT BE LOST HERE
//
//  Pending work is keyed by `InkPageBinding` — a document and a page index —
//  and lives in this actor. It is not keyed by, owned by, or reachable from any
//  `PKCanvasView`. So:
//
//  · Recycling a canvas onto a different page moves a view. The old page's
//    pending drawing and its timer are untouched and still fire.
//  · Closing a document, rotating, or entering split view destroys views. Same
//    answer.
//  · Backgrounding is the only case that needs cooperation, because the process
//    may be suspended before a timer fires. `flushAll()` handles it, and
//    `InkLifecycleObserver` calls it under a background-task assertion.
//  · A store write that throws puts the drawing back and retries with backoff
//    rather than dropping it.
//  · A page whose write is *in flight* is no longer pending, so the cache is
//    what answers for it — which is why the cache is updated before the write
//    rather than after. A canvas recycled back onto the page during that window
//    would otherwise be handed the ink as it was when the document opened, and
//    the next stroke would write that back over the top.
//
//  The only ink this design can lose is ink drawn in the last few milliseconds
//  before a crash, which is the same guarantee Notes gives.
//  ─────────────────────────────────────────────────────────────────────────────
//

import Foundation
import PencilKit
import Core

/// Debounced autosave, page-drawing cache, and recognition scheduling.
///
/// **Isolation.** An `actor`, deliberately not `@MainActor`. `record(_:)` is
/// `nonisolated` and synchronous so the canvas delegate can call it from the
/// main actor without awaiting anything; everything after that — archiving,
/// writing, recognising — happens off the main actor
/// (STYLE.md § 6, docs/04-flows.md § F3).
///
/// **On failure:** nothing here throws. A write that fails is retried with
/// backoff and then reported through `InkLog`; a read that fails yields nil,
/// which the canvas renders as an empty page rather than as an error. The one
/// thing it will not do is discard a drawing it has accepted.
public actor InkPersistenceCoordinator {

    /// How many times a failed write is retried before it is logged and left in
    /// the pending set for the next flush to pick up.
    public static let maximumWriteAttempts = 3

    /// How many times `flushAll()` will go round picking up changes that
    /// arrived while it was writing, before it accepts that it is chasing a
    /// hand that has not stopped moving.
    public static let maximumFlushRounds = 4

    private let store: any DocumentStoring
    private let recogniser: any HandwritingRecognising
    private let policy: InkDebouncePolicy
    private let recognitionLocale: Locale

    private let mailbox = Mailbox()

    private var pending: [InkPageBinding: PendingPage] = [:]
    private var timers: [InkPageBinding: Task<Void, Never>] = [:]
    private var recognitions: [InkPageBinding: Recognition] = [:]
    private var nextRecognitionToken = 0

    /// The latest bytes for a page — what has been written, or what is on its
    /// way to the store right now — for the document currently open. Bound to
    /// one document at a time: the reader shows one.
    ///
    /// **A page with no ink is a value, not a missing key.** The outer optional
    /// is "have we ever looked at this page", the inner one is "does it carry
    /// ink"; collapsing the two made every clean page — which is most pages —
    /// miss the cache and read the store on the path `preload(_:documentId:)`
    /// exists to make free. Write through `remember(_:for:)` rather than
    /// through the subscript, which treats a nil value as a removal.
    private var cache: [InkPageBinding: Data?] = [:]
    private var cachedDocumentId: UUID?

    /// - Parameters:
    ///   - store: the library. Ink is written through
    ///     `DocumentStoring.saveDrawing(_:pageIndex:documentId:)` and recognised
    ///     text through `saveRecognisedInk(_:pageIndex:documentId:)`.
    ///   - recogniser: defaults to the null one, which declines everything.
    ///     Pass `InkRecogniserFactory.make()` to get whatever the build supports.
    ///   - policy: timing. Defaults to 500ms / 2s / 1.5s.
    ///   - recognitionLocale: the language handwriting is read in. Defaults to
    ///     the device's, which is the best guess available — there is no
    ///     handwriting locale in `AppSettings`, only a transcription one.
    public init(
        store: any DocumentStoring,
        recogniser: any HandwritingRecognising = NullHandwritingRecogniser(),
        policy: InkDebouncePolicy = .standard,
        recognitionLocale: Locale = Locale.current
    ) {
        self.store = store
        self.recogniser = recogniser
        self.policy = policy
        self.recognitionLocale = recognitionLocale
    }

    // MARK: - The touch path

    /// Records a drawing change. **The only method on this type that the
    /// drawing path calls, and the only one that is not `async`.**
    ///
    /// `nonisolated` and synchronous on purpose: the canvas delegate fires on
    /// the main actor at the end of every stroke, and awaiting an actor there
    /// would put a hop — and, under load, a queue — between the user's hand and
    /// the next frame. This appends to a lock-protected mailbox, which is a few
    /// tens of nanoseconds, and returns. Archiving happens later and elsewhere.
    ///
    /// Ordering is FIFO, so the last change recorded for a page is always the
    /// one that gets written.
    public nonisolated func record(_ change: InkChange) {
        self.mailbox.append(change)
        Task { await self.absorbMailboxNow() }
    }

    // MARK: - Reading

    /// Seeds the cache from a document's snapshots, so a page scrolling into
    /// view can be given its ink without a store read.
    ///
    /// Call it when a document opens, with `DocumentDetail.pages`. Pages
    /// without ink are seeded too: "this page is empty" is an answer, and it is
    /// the answer most pages need.
    public func preload(_ pages: [PageSnapshot], documentId: UUID) {
        if self.cachedDocumentId != documentId {
            self.cache.removeAll(keepingCapacity: false)
            self.cachedDocumentId = documentId
        }
        for page in pages {
            let binding = InkPageBinding(documentId: documentId, pageIndex: page.pageIndex)
            self.remember(page.drawingData, for: binding)
        }
    }

    /// The latest bytes for a page: whatever is pending if anything is, else the
    /// cache, else the store.
    ///
    /// Pending-first is what makes recycling safe. A page that is scrolled away
    /// and straight back inside the debounce window has strokes that are not on
    /// disk yet; reading the store would show the reader their ink disappearing
    /// and would then let the next stroke overwrite it.
    ///
    /// - Returns: archived `PKDrawing` bytes, or nil when the page has no ink.
    ///
    /// A cache miss now costs one page's read rather than the document's — the
    /// whole-corpus fetch this used to do was the workaround for
    /// `DocumentStoring` having no per-page accessor, and it has one.
    public func drawingData(for binding: InkPageBinding) async -> Data? {
        self.absorbMailboxNow()
        if let page = self.pending[binding] {
            return InkPersistenceCoordinator.archive(page.drawing)
        }
        // `cached` is itself an optional: a page known to carry no ink answers
        // nil from here rather than falling through to the store.
        if self.cachedDocumentId == binding.documentId, let cached = self.cache[binding] {
            return cached
        }
        return await self.loadPage(binding)
    }

    // MARK: - Flushing

    /// Writes one page now, if it has anything unwritten. Called when a canvas
    /// is recycled off a page.
    ///
    /// Not required for correctness — the page's own timer would fire anyway —
    /// but it shortens the window in which the reader's most recent strokes
    /// exist only in memory.
    public func flush(_ binding: InkPageBinding) async {
        self.absorbMailboxNow()
        await self.commit(binding)
    }

    /// Writes every page that has anything unwritten.
    ///
    /// Call this on the way to the background, and before closing a document.
    /// It is the one thing standing between a 500ms debounce and a lost stroke.
    public func flushAll() async {
        // Writing is an await, and strokes can arrive during it, so loop until
        // nothing new has turned up. The first round retries pages whose last
        // write failed — this is the app's last chance before suspension, and
        // it is worth one more attempt. Later rounds leave them to their
        // backoff and pick up only what has just arrived.
        var rounds = 0
        var includeRetries = true
        while rounds < InkPersistenceCoordinator.maximumFlushRounds {
            self.absorbMailboxNow()
            let candidates: [InkPageBinding] = includeRetries
                ? Array(self.pending.keys)
                : self.pending.filter { $0.value.attempts == 0 }.map(\.key)
            guard !candidates.isEmpty else { return }
            for binding in candidates {
                await self.commit(binding)
            }
            includeRetries = false
            rounds += 1
        }
    }

    /// Flushes, then drops the cache and cancels outstanding recognition.
    /// Call when the reader closes a document.
    public func close() async {
        await self.flushAll()
        for recognition in self.recognitions.values {
            recognition.task.cancel()
        }
        self.recognitions.removeAll()
        self.cache.removeAll(keepingCapacity: false)
        self.cachedDocumentId = nil
    }

    /// How many pages are carrying unwritten changes. For tests and for the
    /// hand-test checklist; nothing in the UI should branch on it.
    public func pendingPageCount() -> Int {
        self.absorbMailboxNow()
        return self.pending.count
    }

    // MARK: - Mailbox

    private func absorbMailboxNow() {
        for change in self.mailbox.drain() {
            self.ingest(change)
        }
    }

    private func ingest(_ change: InkChange) {
        let binding = change.binding
        if var existing = self.pending[binding] {
            existing.drawing = change.drawing
            existing.lastChangeAt = max(existing.lastChangeAt, change.recordedAt)
            self.pending[binding] = existing
        } else {
            self.pending[binding] = PendingPage(
                drawing: change.drawing,
                firstChangeAt: change.recordedAt,
                lastChangeAt: change.recordedAt
            )
        }
        self.schedule(binding)
    }

    private func schedule(_ binding: InkPageBinding) {
        guard let page = self.pending[binding] else { return }
        self.timers[binding]?.cancel()
        let nanoseconds = self.policy.delayNanoseconds(
            from: Date(),
            firstChangeAt: page.firstChangeAt,
            lastChangeAt: page.lastChangeAt
        )
        self.timers[binding] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: nanoseconds)
            guard !Task.isCancelled else { return }
            await self?.commit(binding)
        }
    }

    // MARK: - Writing

    private func commit(_ binding: InkPageBinding) async {
        // Always write the newest thing we have, not the newest thing we had
        // when the timer was set.
        self.absorbMailboxNow()
        self.timers[binding]?.cancel()
        self.timers[binding] = nil
        guard var page = self.pending.removeValue(forKey: binding) else { return }

        let data = InkPersistenceCoordinator.archive(page.drawing)

        // The cache is updated **before** the write, not after it. Between the
        // removal above and the store returning there is nothing pending for
        // this page, so `drawingData(for:)` answers from the cache — and a
        // cache still holding the pre-commit bytes would hand a canvas being
        // recycled back onto this page the ink as it was when the document
        // opened, which the next stroke would then write over the top of. The
        // window is one store write, and the write is triggered by the very
        // recycle that reads it.
        //
        // Caching bytes that are still in flight is safe in the other
        // direction: if the write fails the page goes back into `pending`, and
        // pending is read first.
        self.remember(data, for: binding)

        do {
            try await self.store.saveDrawing(
                data,
                pageIndex: binding.pageIndex,
                documentId: binding.documentId
            )
        } catch {
            page.attempts += 1
            guard page.attempts < InkPersistenceCoordinator.maximumWriteAttempts else {
                InkLog.persistence.error("Giving up on writing ink for a page after repeated failures; it stays in memory until the next flush.")
                self.pending[binding] = page
                return
            }
            InkLog.persistence.error("Ink write failed; retrying with backoff.")
            self.pending[binding] = page
            self.scheduleRetry(binding, attempts: page.attempts)
            return
        }

        self.scheduleRecognition(binding, drawingData: data)
    }

    /// Records what a page's ink is now, for the document currently open.
    ///
    /// Nil means "this page has no ink", which is a fact worth caching; the
    /// bare subscript would delete the key and send the next reader to the
    /// store for it.
    private func remember(_ data: Data?, for binding: InkPageBinding) {
        guard self.cachedDocumentId == binding.documentId else { return }
        self.cache.updateValue(data, forKey: binding)
    }

    private func scheduleRetry(_ binding: InkPageBinding, attempts: Int) {
        let backoff = pow(2.0, Double(attempts))
        let nanoseconds = InkDebouncePolicy.nanoseconds(backoff)
        self.timers[binding]?.cancel()
        self.timers[binding] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: nanoseconds)
            guard !Task.isCancelled else { return }
            await self?.commit(binding)
        }
    }

    // MARK: - Recognition

    /// Kicks off handwriting recognition for a page that has just been written.
    ///
    /// `Task.detached` rather than `Task`: an unstructured task started inside
    /// an actor inherits that actor, and recognition running on this actor would
    /// serialise behind — and in front of — the next page's autosave. Detached,
    /// it runs on the cooperative pool and touches nothing here.
    private func scheduleRecognition(_ binding: InkPageBinding, drawingData: Data?) {
        self.recognitions[binding]?.task.cancel()

        let token = self.nextRecognitionToken
        self.nextRecognitionToken &+= 1
        let store = self.store
        let recogniser = self.recogniser
        let locale = self.recognitionLocale
        let settle = InkDebouncePolicy.nanoseconds(self.policy.recognitionDelay)

        let task = Task.detached(priority: .utility) { [weak self] in
            await InkPersistenceCoordinator.recognise(
                binding: binding,
                drawingData: drawingData,
                store: store,
                recogniser: recogniser,
                locale: locale,
                settleNanoseconds: settle
            )
            await self?.recognitionFinished(binding, token: token)
        }
        self.recognitions[binding] = Recognition(token: token, task: task)
    }

    /// The recognition itself, off this actor entirely.
    ///
    /// Static so the detached task above holds no reference to the coordinator
    /// while it runs; the only thing it comes back for is to drop its own
    /// handle.
    private static func recognise(
        binding: InkPageBinding,
        drawingData: Data?,
        store: any DocumentStoring,
        recogniser: any HandwritingRecognising,
        locale: Locale,
        settleNanoseconds: UInt64
    ) async {
        guard let drawingData, !drawingData.isEmpty else {
            try? await store.saveRecognisedInk(
                nil,
                pageIndex: binding.pageIndex,
                documentId: binding.documentId
            )
            return
        }

        try? await Task.sleep(nanoseconds: settleNanoseconds)
        guard !Task.isCancelled else { return }
        guard await recogniser.isAvailable(for: locale) else { return }
        guard let ink = await recogniser.recogniseText(drawingData: drawingData, locale: locale) else { return }
        guard !Task.isCancelled else { return }
        do {
            try await store.saveRecognisedInk(
                ink.text,
                pageIndex: binding.pageIndex,
                documentId: binding.documentId
            )
        } catch {
            // Recognition is an enhancement, never a dependency
            // (docs/04-flows.md § F3). The ink itself is already on disk.
            InkLog.recognition.debug("Recognised ink could not be stored; the ink itself is unaffected.")
        }
    }

    /// Drops a finished recognition's handle.
    ///
    /// Called by the task itself as it ends. Without it the actor keeps one
    /// completed `Task` per inked page for as long as the document is open —
    /// bounded, but pointless, and `close()` was the only thing that ever
    /// cleared it. The token is what makes this safe: a recognition that has
    /// already been superseded finds a different token and leaves the newer
    /// handle alone.
    private func recognitionFinished(_ binding: InkPageBinding, token: Int) {
        guard self.recognitions[binding]?.token == token else { return }
        self.recognitions.removeValue(forKey: binding)
    }

    // MARK: - Support

    /// Reads one page's ink from the store and caches it.
    ///
    /// One page, not the document: `DocumentStoring.drawingData(pageIndex:
    /// documentId:)` exists precisely so that scrolling onto an uncached page
    /// does not fetch the ink of every other page to draw one. A document
    /// opened through `preload(_:documentId:)` — which is the normal path,
    /// since the reader already holds `DocumentDetail.pages` — never gets here
    /// at all.
    ///
    /// - Returns: nil when the page has no ink and when the read failed. A
    ///   failed read renders the page empty until the next write rather than
    ///   failing the document (docs/04-flows.md § F3).
    private func loadPage(_ binding: InkPageBinding) async -> Data? {
        if self.cachedDocumentId != binding.documentId {
            self.cache.removeAll(keepingCapacity: false)
            self.cachedDocumentId = binding.documentId
        }
        do {
            let data = try await self.store.drawingData(
                pageIndex: binding.pageIndex,
                documentId: binding.documentId
            )
            // Cached even when it is nil: a page that has been read and found
            // empty must not be read again every time it scrolls into view.
            self.remember(data, for: binding)
            return data
        } catch {
            InkLog.persistence.error("Could not read a page's ink; it will render empty until the next write.")
            return nil
        }
    }

    /// An empty drawing is stored as nil, which is how `DocumentStoring`
    /// spells "this page has no ink" — erasing the last stroke has to clear the
    /// page, not save an empty archive that keeps `hasInk` true forever.
    private static func archive(_ drawing: PKDrawing) -> Data? {
        guard !drawing.strokes.isEmpty else { return nil }
        return drawing.dataRepresentation()
    }

    /// A handwriting recognition in flight, and the token that identifies it.
    private struct Recognition {
        let token: Int
        let task: Task<Void, Never>
    }

    /// A page's unwritten state.
    private struct PendingPage {
        var drawing: PKDrawing
        var firstChangeAt: Date
        var lastChangeAt: Date
        var attempts: Int = 0
    }

    /// The hand-off between the main actor and this one.
    ///
    /// A lock rather than an `AsyncStream` because `record(_:)` has to be
    /// synchronous and non-blocking: an uncontended `NSLock` is tens of
    /// nanoseconds, and FIFO order falls out of it for free, which is what lets
    /// the ingest path overwrite rather than reconcile.
    // SAFETY: every access to `items` is inside `lock`, the array never escapes
    // except as a copy returned by `drain()`, and the `InkChange` values it
    // holds are read-only once constructed. That is the whole of the shared
    // mutable state.
    private final class Mailbox: @unchecked Sendable {

        private let lock = NSLock()
        private var items: [InkChange] = []

        func append(_ change: InkChange) {
            self.lock.lock()
            self.items.append(change)
            self.lock.unlock()
        }

        func drain() -> [InkChange] {
            self.lock.lock()
            let drained = self.items
            self.items.removeAll(keepingCapacity: true)
            self.lock.unlock()
            return drained
        }
    }
}
