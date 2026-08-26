//
//  HTTPSyncCoordinator.swift
//  Sync · HTTP
//
//  The relay's half of `SyncCoordinating`, deliberately written as a paraphrase
//  of `SyncCoordinator` so the two read as siblings rather than as rivals. The
//  shape is identical — poll, pin, ingest, store, emit; send or queue — and only
//  the two ends differ: a cursor request instead of a directory fingerprint, and
//  a declared upload instead of a coordinated rename.
//
//  ─── WHAT DOES NOT CHANGE ────────────────────────────────────────────────────
//  **Non-negotiable 2 is preserved literally, not approximately.** Every byte is
//  downloaded, verified against the size and hash the feed advertised, and
//  committed into `DocumentContainer.documentsRoot()` by the same
//  `PinnedDocumentWriter` the folder transport uses, before `DocumentIngesting`
//  is handed anything. There is no fetch-on-open path here and there must never
//  be one: the whole point of the app is that it works on a plane, and a server
//  makes fetching on demand tempting in a way a folder never did.
//
//  Nothing on the reading or annotating path touches this type. It is reached
//  from the library's pull-to-refresh, from the scene becoming active, and from
//  its own timer — and from nowhere else (CLAUDE.md non-negotiable 1).
//
//  ─── WHAT THE CURSOR BUYS, AND THE ONE RULE ABOUT IT ─────────────────────────
//  The folder path polls because a file provider materialises a directory entry
//  before the bytes behind it exist, so it has to diff and re-check. The relay
//  answers authoritatively — a document appears in the feed only once it is
//  complete — so the cursor *is* the diff and the server computes it.
//
//  The rule: **the cursor only advances after a page in which nothing failed.**
//  A duplicate costs an `isPinnedAndCurrent` check and nothing else; a miss
//  costs a document that silently never arrives, and there is no second chance
//  to notice.
//

import Foundation
import os
import Core

/// `SyncCoordinating` over a relay.
///
/// **On failure:** nothing here throws at the reader. A server that cannot be
/// reached emits `SyncEvent.folderUnavailable(reason:)` — one sentence in the
/// library's status line — and every document already pinned opens exactly as
/// fast as it did yesterday. A review that cannot be delivered goes to
/// `OutboxQueue` and comes back as `WrittenReview(isQueued: true)`, which is
/// what the review sheet already renders as "will send when online"
/// (docs/04-flows.md § F7).
public actor HTTPSyncCoordinator: SyncCoordinating {

    private let client: SyncServerClient
    private let store: any DocumentStoring
    private let ingester: any DocumentIngesting
    private let pinner: RemoteDocumentPinner
    private let cursors: SyncCursorStore
    private let queue: OutboxQueue
    private let staging: RelayStagingUploader
    private let pollInterval: TimeInterval

    /// Where a document's proposed group is filed, or nil when nothing is
    /// listening. Optional because a coordinator built for a test has no
    /// settings store and does not need one.
    private let groups: (any DocumentGrouping)?

    /// Voice comments waiting for a better transcript
    /// (notes/pencil-loop-cloud-dictation.md). Drained after a scan, on the
    /// poll this coordinator already runs — the upgrade is a background sync
    /// like any other, and giving it a timer of its own would be a second
    /// schedule to reason about.
    private let upgrades: TranscriptUpgradeQueue?

    private var isStarted = false
    private var activeScan: Task<Int, Error>?
    private var pollTask: Task<Void, Never>?
    private var listeners: [UUID: AsyncStream<SyncEvent>.Continuation] = [:]

    /// Replies already turned into events this run, so a document that stays in
    /// the feed does not announce the same reply on every poll.
    private var deliveredReplies: Set<String> = []

    /// A folder that failed to ingest, and the `seq` it failed at. Retried when
    /// the server offers a newer one, or when the user pulls to refresh — the
    /// same bargain `SyncCoordinator` strikes with `deferredFailures`, so a
    /// document that cannot be ingested does not burn the connection every
    /// fifteen seconds.
    private var deferredFailures: [String: Int64] = [:]

    /// - Parameters:
    ///   - queue: give this its own root, distinct from the folder
    ///     transport's. A review queued while on one transport must never flush
    ///     to the other — that would deliver it to a destination the user did
    ///     not choose.
    ///   - groups: where `meta.json`'s proposed group is filed. Nil ingests
    ///     documents without ever filing one.
    public init(
        client: SyncServerClient,
        store: any DocumentStoring,
        ingester: any DocumentIngesting,
        pinner: RemoteDocumentPinner? = nil,
        cursors: SyncCursorStore = SyncCursorStore(),
        queue: OutboxQueue = OutboxQueue(rootURL: HTTPSyncCoordinator.defaultQueueRootURL()),
        staging: RelayStagingUploader? = nil,
        groups: (any DocumentGrouping)? = nil,
        upgrades: TranscriptUpgradeQueue? = nil,
        pollInterval: TimeInterval = 15
    ) {
        self.client = client
        self.store = store
        self.ingester = ingester
        self.pinner = pinner ?? RemoteDocumentPinner(client: client)
        self.cursors = cursors
        self.queue = queue
        self.staging = staging ?? RelayStagingUploader(client: client)
        self.groups = groups
        self.upgrades = upgrades
        self.pollInterval = pollInterval
    }

    /// Where reviews wait when the relay is unreachable.
    ///
    /// Deliberately not `OutboxQueue.defaultRootURL()`. Sharing one queue would
    /// mean a review written while the app was on the folder transport quietly
    /// flushing to a server chosen afterwards. The cost of separate queues is
    /// that switching transports strands a queued bundle; the review sheet's
    /// copy / share / save fallback means nothing the user wrote is ever
    /// unrecoverable, so that is the cheaper mistake.
    public static func defaultQueueRootURL() -> URL {
        DocumentContainer.containerRoot()
            .appendingPathComponent("outbox-queue-server", isDirectory: true)
    }

    // MARK: - SyncCoordinating

    /// Begins polling and scans once. Idempotent — a second call pokes the
    /// timer rather than starting a second one.
    public func start() async {
        if isStarted == false {
            isStarted = true
            startPolling()
        }
        _ = try? await performScan()
    }

    public func stop() async {
        isStarted = false
        pollTask?.cancel()
        pollTask = nil
        activeScan?.cancel()
        activeScan = nil
    }

    /// Pull-to-refresh: look at everything again.
    ///
    /// Passes no cursor, which is the HTTP equivalent of the folder path's
    /// `forgetSeenFolders()`, and clears the deferred failures so a document
    /// that failed to ingest is retried now rather than on the server's next
    /// change. `isPinnedAndCurrent` makes re-listing cheap — everything already
    /// pinned is skipped without a byte being fetched.
    public func refresh() async throws -> Int {
        deferredFailures.removeAll()
        return try await performScan(fromStart: true)
    }

    public nonisolated func events() -> AsyncStream<SyncEvent> {
        AsyncStream { continuation in
            let identifier = UUID()
            Task { await self.addListener(identifier, continuation) }
            continuation.onTermination = { _ in
                Task { await self.removeListener(identifier) }
            }
        }
    }

    /// Uploads a review bundle, or queues it.
    ///
    /// Declare, then upload: the manifest is posted first and each file follows,
    /// so the bundle is invisible on the server until the last byte lands and a
    /// connection that dies half way leaves nothing readable. `manifest.json`
    /// is the parts list that makes that checkable, which is what it was
    /// specified for.
    public func send(_ payload: OutboxPayload) async throws -> WrittenReview {
        do {
            let written = try await upload(payload)
            queue.remove(payload.directoryName)
            emit(.reviewWritten(documentId: written.documentId, directoryURL: written.directoryURL))
            return written
        } catch let error as PencilLoopError {
            guard case let .folderUnavailable(reason) = error else { throw error }
            let queued = try queue.enqueue(payload)
            emit(.folderUnavailable(reason: reason))
            SyncLog.coordinator.notice("A review will be sent when the relay is reachable.")
            return WrittenReview(
                documentId: payload.documentId,
                directoryURL: queued,
                directoryName: payload.directoryName,
                writtenAt: Date(),
                fileCount: payload.files.count,
                byteCount: payload.files.reduce(0) { $0 + Int64($1.data.count) },
                isQueued: true
            )
        }
    }

    /// Turns a reply into a new document, with the origin inherited.
    ///
    /// - Parameter reviewDirectoryName: an opaque review handle. Over the
    ///   folder transport it is the directory name under `outbox/`; here it is
    ///   the review's id on the relay. Callers treat it as neither.
    /// - Throws: `.nothingToIngest` when there is no reply to open.
    @discardableResult
    public func ingestReply(fromReviewDirectory reviewDirectoryName: String) async throws -> UUID {
        let name = HTTPSyncCoordinator.documentFolderName(fromReviewDirectory: reviewDirectoryName)
        guard let markdown = try await client.reply(forReviewNamed: name),
              markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            throw PencilLoopError.nothingToIngest(folderName: name)
        }

        let title = HTTPSyncCoordinator.replyTitle(for: name)
        let body = markdown.hasPrefix("# ") ? markdown : "# \(title)\n\n\(markdown)"

        // Sent back through the relay rather than written locally, so that the
        // reply-as-document exists for every device on this account and not
        // only the one that pressed the button. It then arrives by the ordinary
        // route — there is one ingest path, not two.
        let request = ReplyDocumentRequest(content: body, title: title)
        _ = try await client.post(try ContractCoding.encoder().encode(request), to: "/v1/documents")

        let ingested = try await performScan(fromStart: true)
        SyncLog.coordinator.info("Opened a reply as a document; the scan ingested \(ingested).")

        guard let documentId = try await store.documentId(forFolderName: name) else {
            throw PencilLoopError.nothingToIngest(folderName: name)
        }
        return documentId
    }

    // MARK: - Scanning

    private func performScan() async throws -> Int {
        try await performScan(fromStart: false)
    }

    /// Coalesces concurrent scans, exactly as the folder path does: a poll that
    /// lands while a pull-to-refresh is running joins it rather than opening a
    /// second conversation with the server.
    private func performScan(fromStart: Bool) async throws -> Int {
        if let running = activeScan {
            return try await running.value
        }
        let task = Task { try await self.scanOnce(fromStart: fromStart) }
        activeScan = task
        defer { activeScan = nil }
        return try await task.value
    }

    private func scanOnce(fromStart: Bool) async throws -> Int {
        await flushQueue()

        // Voice comments waiting on a better transcript. Before the feed for
        // the same reason staging is: a comment dictated a moment ago should
        // improve in this pass rather than the next one. It never throws, so it
        // cannot stop documents arriving — an upgrade is the least important
        // thing this method does.
        await upgrades?.drain()

        // Anything the share extension left in the App Group, on its way up.
        // The folder coordinator does this at the same point in its own scan
        // (`SyncCoordinator.scanOnce`); without it, sharing into the app is a
        // silent no-op on this transport (`RelayStagingUploader`).
        //
        // Before the feed is read, so that something shared a moment ago comes
        // back down in this same pass rather than the next one.
        await staging.importAndUpload()

        let since = fromStart ? nil : cursors.cursor(forBaseURL: client.baseURL, epoch: nil)
        let page: SyncServerClient.ChangePage
        do {
            page = try await client.changes(since: since)
        } catch let error as PencilLoopError {
            if case let .folderUnavailable(reason) = error {
                emit(.folderUnavailable(reason: reason))
            }
            throw error
        }

        // An unfamiliar epoch means the relay rebuilt its index, so this
        // device's cursor names a sequence that no longer exists. Start again
        // rather than skip whatever the rebuild renumbered.
        let known = cursors.state(forBaseURL: client.baseURL)
        if let known, known.epoch != page.epoch {
            SyncLog.coordinator.notice("The relay was reindexed; re-listing from the start.")
            return try await rescanFromStart()
        }

        let arriving = page.documents.filter { $0.isDeleted == false }
        emit(.scanStarted(pending: arriving.count))

        var ingestedCount = 0
        var everythingLanded = true
        for document in page.documents {
            if document.isDeleted {
                continue
            }
            guard document.hasUsableFolderName else {
                // A name that is not a bundle name would become a directory in
                // the container. Report it rather than write it.
                emit(.ingestFailed(
                    folderName: document.folderName,
                    reason: "The relay offered a document under a name this iPad cannot use."
                ))
                everythingLanded = false
                continue
            }
            if let deferredAt = deferredFailures[document.folderName], deferredAt >= document.seq {
                continue
            }
            if pinner.isPinnedAndCurrent(document) {
                continue
            }
            if await ingest(document) {
                ingestedCount += 1
            } else {
                everythingLanded = false
            }
        }

        await announceReplies(page.replies)

        // Only on a clean page. A duplicate is free; a miss is a document that
        // never arrives and never says so.
        if everythingLanded {
            cursors.save(cursor: page.cursor, epoch: page.epoch, forBaseURL: client.baseURL)
        }

        emit(.scanFinished(ingestedCount: ingestedCount))

        if page.hasMore && everythingLanded {
            return ingestedCount + (try await scanOnce(fromStart: false))
        }
        return ingestedCount
    }

    private func rescanFromStart() async throws -> Int {
        cursors.clear()
        deferredFailures.removeAll()
        return try await scanOnce(fromStart: true)
    }

    /// Download, verify, pin, ingest, store — in that order, always.
    ///
    /// - Returns: whether the document landed. A false answer defers the folder
    ///   and holds the cursor back, so the next scan tries again.
    private func ingest(_ document: RemoteDocument) async -> Bool {
        do {
            let item = try await pinner.pin(document)
            let ingested = try await ingester.ingest(item)
            try await store.upsert(ingested)
            // Never throws: see the same call in SyncCoordinator. A group that
            // could not be filed must not cost the document that arrived.
            try? await groups?.adoptGroupName(ingested.groupName, forFolderName: ingested.folderName)
            emit(.ingested(documentId: ingested.id, title: ingested.title))
            return true
        } catch {
            let reason = (error as? PencilLoopError)?.message ?? error.localizedDescription
            deferredFailures[document.folderName] = document.seq
            try? await store.recordIngestFailure(
                folderName: document.folderName,
                reason: reason
            )
            emit(.ingestFailed(folderName: document.folderName, reason: reason))
            SyncLog.coordinator.error("\(document.folderName) did not ingest: \(reason)")
            return false
        }
    }

    // MARK: - Sending

    private func upload(_ payload: OutboxPayload) async throws -> WrittenReview {
        let folderName = HTTPSyncCoordinator.documentFolderName(
            fromReviewDirectory: payload.directoryName
        )
        guard let manifest = payload.files.first(where: { $0.relativePath == "manifest.json" }),
              let reviewMarkdown = payload.files.first(where: { $0.relativePath == "review.md" }) else {
            throw PencilLoopError.outboxWriteFailed(
                reason: "The bundle is missing review.md or manifest.json."
            )
        }

        // The declaration carries the manifest and nothing else. Every file it
        // lists is uploaded as the exact bytes this device hashed — a server
        // that re-encoded review.json from JSON produced different bytes for
        // the same object, and verification could never pass.
        let declaration: [String: Any] = [
            "manifest": try JSONSerialization.jsonObject(with: manifest.data)
        ]
        let body = try JSONSerialization.data(withJSONObject: declaration)
        _ = try await client.post(body, to: "/v1/documents/\(folderName)/review")

        _ = reviewMarkdown  // required by the bundle; uploaded below like the rest

        for file in payload.files where file.relativePath != "manifest.json" {
            _ = try await client.put(
                file.data,
                to: "/v1/reviews/\(folderName)/files/\(file.relativePath)",
                contentType: HTTPSyncCoordinator.contentType(for: file.relativePath)
            )
        }

        return WrittenReview(
            documentId: payload.documentId,
            directoryURL: SyncServerClient.url(
                base: client.baseURL,
                path: "/v1/reviews/\(folderName)",
                query: []
            ),
            directoryName: payload.directoryName,
            writtenAt: Date(),
            fileCount: payload.files.count,
            byteCount: payload.files.reduce(0) { $0 + Int64($1.data.count) },
            isQueued: false
        )
    }

    /// Replays whatever is waiting, oldest first, and stops at the first refusal.
    ///
    /// Safe to run on every poll because the relay treats a re-delivered bundle
    /// with an unchanged manifest as a retry: same revision, nothing rewritten.
    /// Without that guarantee this loop would post a duplicate review into
    /// somebody's conversation every fifteen seconds.
    private func flushQueue() async {
        let waiting = queue.queuedPayloads()
        guard waiting.isEmpty == false else { return }
        for payload in waiting {
            do {
                let written = try await upload(payload)
                queue.remove(payload.directoryName)
                await recordDelivery(of: written)
                emit(.reviewWritten(documentId: written.documentId, directoryURL: written.directoryURL))
            } catch {
                SyncLog.coordinator.notice("A queued review is still waiting to be sent.")
                return
            }
        }
    }

    /// Sent, in the directory a reply comes back in, and read.
    ///
    /// Failures are swallowed: the bundle is delivered either way, and a store
    /// that will not take the note is not a reason to leave it in the queue.
    private func recordDelivery(of written: WrittenReview) async {
        try? await store.recordReviewSent(
            documentId: written.documentId,
            at: written.writtenAt,
            directoryName: written.directoryName
        )
        try? await store.setState(.read, documentId: written.documentId)
    }

    // MARK: - Replies

    private func announceReplies(_ replies: [SyncServerClient.ChangePage.Reply]) async {
        for reply in replies {
            let key = "\(reply.folderName)@\(reply.seq)"
            guard deliveredReplies.contains(key) == false else { continue }
            // `try?` flattens the store's `UUID?` and the client's `String?`,
            // so each of these binds once, not twice.
            guard let documentId = try? await store.documentId(forFolderName: reply.folderName) else {
                continue
            }
            guard let markdown = try? await client.reply(forReviewNamed: reply.folderName) else {
                continue
            }

            deliveredReplies.insert(key)
            try? await store.recordReply(
                documentId: documentId,
                text: markdown,
                receivedAt: Date()
            )
            emit(.replyReceived(
                documentId: documentId,
                replyURL: SyncServerClient.url(
                    base: client.baseURL,
                    path: "/v1/reviews/\(reply.folderName)/reply",
                    query: []
                )
            ))
        }
    }

    // MARK: - Polling

    /// The same fifteen seconds and the same three triggers as the folder
    /// watcher, in a slice-and-check loop so `stop()` is felt immediately
    /// rather than at the end of the current sleep.
    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [pollInterval] in
            while await self.isPolling() {
                let slice = min(pollInterval, 1)
                var waited: TimeInterval = 0
                while waited < pollInterval, await self.isPolling() {
                    try? await Task.sleep(nanoseconds: UInt64(slice * 1_000_000_000))
                    waited += slice
                }
                guard await self.isPolling() else { return }
                _ = try? await self.performScan()
            }
        }
    }

    private func isPolling() -> Bool {
        isStarted && Task.isCancelled == false
    }

    // MARK: - Listeners

    private func addListener(_ identifier: UUID, _ continuation: AsyncStream<SyncEvent>.Continuation) {
        listeners[identifier] = continuation
    }

    private func removeListener(_ identifier: UUID) {
        listeners[identifier] = nil
    }

    private func emit(_ event: SyncEvent) {
        for continuation in listeners.values {
            continuation.yield(event)
        }
    }

    // MARK: - Naming

    /// `<slug>.review` → `<slug>`, and anything else unchanged.
    static func documentFolderName(fromReviewDirectory name: String) -> String {
        name.hasSuffix(".review") ? String(name.dropLast(".review".count)) : name
    }

    static func replyTitle(for folderName: String) -> String {
        let readable = folderName
            .split(separator: "-")
            .drop(while: { Int($0) != nil })
            .joined(separator: " ")
        return readable.isEmpty ? "Reply" : "Reply — \(readable)"
    }

    static func contentType(for relativePath: String) -> String {
        relativePath.hasSuffix(".png") ? "image/png" : "application/octet-stream"
    }

    /// The body of a reply being sent back as a document.
    ///
    /// A named type rather than a dictionary so the relay's field names are
    /// spelled in exactly one place. Nested, because one public type per file
    /// is the rule and a request body is not a second idea.
    struct ReplyDocumentRequest: Encodable {
        var content: String
        var title: String
    }
}
