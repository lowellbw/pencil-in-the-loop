//
//  SyncCoordinator.swift
//  Sync
//
//  The whole sync loop, as AppUI sees it: watch, scan, pin, ingest, store,
//  write. One face for what is really six collaborators, so a view does not
//  have to orchestrate them.
//
//  ─── WHERE A SCAN COMES FROM ─────────────────────────────────────────────────
//  · foreground        — `start()`, which is idempotent and always scans;
//  · the timer         — `PollingFolderWatcher`, every 15s while started;
//  · pull-to-refresh   — `refresh()`, which throws so the gesture can show why;
//  · a presenter nudge — folded into the timer, never acted on directly.
//
//  Concurrent scans coalesce onto one task, so a poll landing on top of a
//  pull-to-refresh does the work once and both callers get the same answer.
//
//  ─── WHAT NEVER HAPPENS HERE ─────────────────────────────────────────────────
//  Nothing on the reading or annotating path awaits anything in this file. The
//  library is served from Storage, and documents are served from the pinned
//  copies in the app container. If the folder is unreachable, every document
//  already ingested opens exactly as fast as it did yesterday — losing the
//  folder costs you new documents only (docs/02-spec.md § Cross-cutting).
//

import Foundation
import Core

/// `SyncCoordinating`, over the scanner, the pinner, the ingester, the store,
/// the writer, the queue and the watcher.
///
/// **On failure:** `refresh()` and `send(_:)` throw `PencilLoopError`; both are
/// user-initiated and both have somewhere to show it. Background work never
/// throws into the UI — it reports through `events()` and carries on. A
/// document that will not ingest becomes a `.ingestFailed` event and an error
/// row, never a disappearance.
public actor SyncCoordinator: SyncCoordinating {

    private let folder: SyncFolder
    private let store: any DocumentStoring
    private let ingester: any DocumentIngesting
    private let scanner: any InboxScanning
    private let writer: any OutboxWriting
    private let watcher: any FolderWatching
    private let replyScanner: ReplyScanner
    private let pinner: InboxItemPinner
    private let stagingImporter: AppGroupStagingImporter
    private let queue: OutboxQueue
    private let importsAppGroupStaging: Bool

    /// Concrete rather than `any FolderAccessing` on purpose. The protocol now
    /// carries an async `withAccess` overload, which covers everything that
    /// suspends inside one call — but this actor opens the scope in one method
    /// and closes it in another, across the scan, the pin, the ingest and the
    /// reply sweep, and that needs the `beginAccess`/`endAccess` pair this type
    /// keeps outside the protocol. Anything narrower should use `withAccess`.
    private let access: SyncFolderAccess

    /// Where a document's proposed group is filed, or nil when nothing is
    /// listening. Optional because a coordinator built for a test has no
    /// settings store and does not need one.
    private let groups: (any DocumentGrouping)?

    private var isStarted = false
    private var activeScan: Task<Int, Error>?
    private var watchTask: Task<Void, Never>?
    private var listeners: [UUID: AsyncStream<SyncEvent>.Continuation] = [:]
    private var deliveredReplies: Set<String> = []

    /// Folder name to the modification date at which its ingest last failed.
    ///
    /// A folder in here is left alone by background scans until it changes on
    /// disk or the user pulls to refresh, which is what `refresh()` clears. It
    /// is the *only* thing that defers a retry: the scanner is told about
    /// folders that succeeded, never about folders that failed, so a failure
    /// that is not deferred here comes back on the very next scan.
    private var deferredFailures: [String: Date] = [:]

    /// - Parameters:
    ///   - folder: the sync root, already prepared by `FolderAccessing`.
    ///   - store: the library.
    ///   - ingester: the single ingest path (docs/04-flows.md § F1).
    ///   - scanner: finds candidate directories under `inbox/`.
    ///   - writer: the atomic outbox write.
    ///   - watcher: change notification. Polling by default.
    ///   - replyScanner: finds `reply.md` in `outbox/`.
    ///   - pinner: download-and-pin into the app container.
    ///   - stagingImporter: the share extension's App Group hand-off.
    ///   - queue: where a review waits when the folder is unreachable.
    ///   - access: security-scoped access to `folder`.
    ///   - groups: where `meta.json`'s proposed group is filed. Nil ingests
    ///     documents without ever filing one.
    ///   - importsAppGroupStaging: off in tests that have no App Group.
    public init(
        folder: SyncFolder,
        store: any DocumentStoring,
        ingester: any DocumentIngesting,
        scanner: any InboxScanning = InboxScanner(),
        writer: any OutboxWriting = OutboxWriter(),
        watcher: any FolderWatching = PollingFolderWatcher(),
        replyScanner: ReplyScanner = ReplyScanner(),
        pinner: InboxItemPinner = InboxItemPinner(),
        stagingImporter: AppGroupStagingImporter = AppGroupStagingImporter(),
        queue: OutboxQueue = OutboxQueue(),
        access: SyncFolderAccess = SyncFolderAccess(),
        groups: (any DocumentGrouping)? = nil,
        importsAppGroupStaging: Bool = true
    ) {
        self.folder = folder
        self.store = store
        self.ingester = ingester
        self.scanner = scanner
        self.writer = writer
        self.watcher = watcher
        self.replyScanner = replyScanner
        self.pinner = pinner
        self.stagingImporter = stagingImporter
        self.queue = queue
        self.groups = groups
        self.access = access
        self.importsAppGroupStaging = importsAppGroupStaging
    }

    // MARK: - SyncCoordinating

    /// Begins watching and performs an initial scan. Idempotent.
    ///
    /// This is also the foreground hook: call it every time the app becomes
    /// active. A second call does not start a second watcher — it pokes the one
    /// that is running and scans.
    public func start() async {
        if isStarted == false {
            isStarted = true
            startWatching()
        } else {
            await pokeWatcher()
        }
        _ = try? await performScan()
    }

    /// Stops watching. The library stays fully usable afterwards.
    ///
    /// A scan in flight is cancelled too, and stops between documents rather
    /// than part-way through one: whatever it had already ingested stays
    /// ingested, and everything it had not reached is left unhandled, so the
    /// next `start()` picks it up.
    public func stop() async {
        watchTask?.cancel()
        watchTask = nil
        activeScan?.cancel()
        await watcher.stop()
        isStarted = false
    }

    /// A full re-scan, as pull-to-refresh triggers.
    ///
    /// **Genuinely full.** The scanner's memory of what it has handled is
    /// dropped first, and so is every folder deferred after a failed ingest, so
    /// this looks at every directory in `inbox/` again. That is what the gesture
    /// means, and it is the retry that `InboxItemPinner`'s "it will be retried
    /// on the next refresh" promises the user. Folders that are already pinned
    /// and current cost one sidecar read each and are not re-ingested.
    ///
    /// - Returns: how many documents were newly ingested. Zero is a normal,
    ///   successful answer.
    /// - Throws: `.folderUnavailable` when the root cannot be read. Everything
    ///   else is reported per document through `events()`.
    public func refresh() async throws -> Int {
        await forgetScanMemory()
        return try await performScan()
    }

    /// The event stream for the UI. Multiple consumers each get their own
    /// stream; a consumer that stops listening costs nothing.
    ///
    /// Events emitted before a consumer registers are not replayed. That is
    /// deliberate and safe: every event means "look again", and the library is
    /// read from Storage rather than from this stream.
    public nonisolated func events() -> AsyncStream<SyncEvent> {
        let identifier = UUID()
        let (stream, continuation) = AsyncStream<SyncEvent>.makeStream()
        continuation.onTermination = { [weak self] _ in
            guard let self else { return }
            Task { await self.removeListener(identifier) }
        }
        Task { await self.addListener(identifier, continuation) }
        return stream
    }

    /// Writes a bundle to `outbox/`, queueing it when the folder is
    /// unreachable.
    ///
    /// - Returns: where it landed. When the folder was unreachable that is the
    ///   **queue** directory in the app container, not `outbox/` — the Sent
    ///   screen says "will send when online" and waits for the
    ///   `.reviewWritten` event, which is emitted when the bundle really
    ///   reaches the folder (docs/04-flows.md § F7).
    /// - Throws: `.outboxWriteFailed` when it could not even be queued.
    public func send(_ payload: OutboxPayload) async throws -> WrittenReview {
        let started = access.beginAccess(to: folder)
        defer { access.endAccess(to: folder, wasStarted: started) }

        do {
            let written = try await writer.write(payload, to: folder)
            queue.remove(payload.directoryName)
            emit(.reviewWritten(documentId: written.documentId, directoryURL: written.directoryURL))
            return written
        } catch let error as PencilLoopError {
            guard case let .folderUnavailable(reason) = error else { throw error }
            let queued = try queue.enqueue(payload)
            emit(.folderUnavailable(reason: reason))
            SyncLog.coordinator.notice("\(payload.directoryName) will be sent when the folder is reachable.")
            return WrittenReview(
                documentId: payload.documentId,
                directoryURL: queued,
                directoryName: payload.directoryName,
                writtenAt: Date(),
                fileCount: payload.files.count,
                byteCount: payload.files.reduce(0) { $0 + Int64($1.data.count) },
                // This is the queue, not `outbox/`. Saying so here is what lets
                // the Sent screen show "will send when online" without racing
                // `events()` for the answer (DTOs.swift, `WrittenReview`).
                isQueued: true
            )
        }
    }

    // MARK: - The reply loop (docs/04-flows.md § F6)

    /// Turns a reply into a new document, with the origin inherited.
    ///
    /// The "Open as document" action on the Sent screen. The new document is
    /// written into `inbox/` like any other — there is one ingest path, not two
    /// — so it is annotatable, and a review of it goes back to the same
    /// conversation the original came from.
    ///
    /// - Parameter reviewDirectoryName: `<slug>.review`.
    /// - Returns: the new document's id.
    /// - Throws: `.nothingToIngest` when there is no reply to open, or whatever
    ///   ingest threw.
    @discardableResult
    public func ingestReply(fromReviewDirectory reviewDirectoryName: String) async throws -> UUID {
        let started = access.beginAccess(to: folder)
        defer { access.endAccess(to: folder, wasStarted: started) }

        let existingText = try await writer.readReply(inReviewDirectory: reviewDirectoryName, in: folder)
        guard let text = existingText, text.isEmpty == false else {
            throw PencilLoopError.nothingToIngest(folderName: reviewDirectoryName)
        }

        let sourceFolderName = ReplyScanner.documentFolderName(forReviewDirectory: reviewDirectoryName)
        let sourceDirectory = folder.inboxURL.appendingPathComponent(sourceFolderName, isDirectory: true)
        let sourceMetadata = MetadataFile.read(inDirectory: sourceDirectory)

        let baseTitle = sourceMetadata.title ?? MetadataFile.fallbackTitle(forDirectoryNamed: sourceFolderName)
        let title = "Reply — \(baseTitle)"
        let now = Date()
        let folderName = Slug.disambiguated(
            Slug.folderName(date: now, title: title),
            existing: InboxScanner.folderNames(in: folder)
        )

        let metadata = DocumentMetadata(
            id: UUID().uuidString,
            title: title,
            createdAt: now,
            origin: MetadataFile.inheritedOrigin(from: sourceMetadata),
            sourceFormat: .markdown
        )
        let metadataData = try MetadataFile.encode(metadata)
        try writeInboxDirectory(named: folderName, files: [
            (DocumentFileNames.sourceMarkdown, Data(text.utf8)),
            (DocumentFileNames.metadata, metadataData)
        ])

        let directory = folder.inboxURL.appendingPathComponent(folderName, isDirectory: true)
        guard let item = try await scanner.item(at: directory) else {
            throw PencilLoopError.nothingToIngest(folderName: folderName)
        }
        let pinned = try await pinner.pin(item)
        let document = try await ingester.ingest(pinned)
        let summary = try await store.upsert(document)
        await adoptGroup(for: document)
        emit(.ingested(documentId: summary.id, title: summary.title))
        return summary.id
    }

    /// Files a newly ingested document under the group its `meta.json` proposed.
    ///
    /// **Never throws, deliberately.** A group is a convenience about where a
    /// row is drawn; a document that could not be filed is still a document that
    /// arrived, and failing the ingest over it would trade something the user
    /// needs for something they merely like. `adoptGroupName` also leaves alone
    /// anything the user has already filed by hand, so a re-scan of an unchanged
    /// inbox cannot move a document back.
    private func adoptGroup(for document: IngestedDocument) async {
        try? await groups?.adoptGroupName(document.groupName, forFolderName: document.folderName)
    }

    // MARK: - Scanning

    /// Coalesces concurrent scans onto one task. A poll that lands during a
    /// pull-to-refresh waits for it rather than running a second one.
    private func performScan() async throws -> Int {
        if let activeScan {
            return try await activeScan.value
        }
        let task = Task<Int, Error> { try await self.scanOnce() }
        activeScan = task
        let outcome = await task.result
        activeScan = nil
        return try outcome.get()
    }

    private func scanOnce() async throws -> Int {
        let started = access.beginAccess(to: folder)
        defer { access.endAccess(to: folder, wasStarted: started) }

        guard access.isReachableWithinOpenScope(folder) else {
            let reason = "The sync folder could not be opened. Documents already downloaded are unaffected."
            emit(.folderUnavailable(reason: reason))
            throw PencilLoopError.folderUnavailable(reason: reason)
        }
        try? access.ensureDirectories(in: folder)

        // Hidden `.tmp` siblings left in the user's inbox by a process that died
        // between staging and rename. Nothing else removes them — every scan
        // here skips hidden entries — and they are in somebody else's folder.
        StagingSweeper.sweep(in: folder.inboxURL)

        if importsAppGroupStaging {
            stagingImporter.importAll(into: folder)
        }
        await flushQueue()

        let known = (try? await store.knownFolderNames()) ?? []
        let scan = try await scanner.scan(folder, knownFolderNames: known)
        emit(.scanStarted(pending: scan.items.count))

        // A subdirectory the scanner could not read becomes an error row, not a
        // silence. The scan carries on regardless (Protocols.swift §
        // InboxScanning).
        for skipped in scan.skipped {
            SyncLog.coordinator.error("Skipped \(skipped.folderName): \(skipped.reason)")
            try? await store.recordIngestFailure(folderName: skipped.folderName, reason: skipped.reason)
            emit(.ingestFailed(folderName: skipped.folderName, reason: skipped.reason))
        }

        var ingestedCount = 0
        for item in scan.items {
            // `stop()` cancels this task. The scan gives up between documents,
            // never part-way through one.
            if Task.isCancelled { break }

            if known.contains(item.folderName), pinner.isPinnedAndCurrent(item) {
                // Nothing to do for this revision, which is exactly what the
                // scanner needs to know so it can stop reporting it.
                await markHandled(item)
                continue
            }
            if let failedAt = deferredFailures[item.folderName], failedAt >= item.modifiedAt {
                // This revision has already failed once. It comes back when the
                // folder changes on disk or when the user pulls to refresh,
                // rather than being re-downloaded every fifteen seconds.
                continue
            }
            if await ingest(item) {
                ingestedCount += 1
                await markHandled(item)
            } else if Task.isCancelled == false {
                deferredFailures[item.folderName] = item.modifiedAt
            }
        }
        emit(.scanFinished(ingestedCount: ingestedCount))

        await collectReplies()
        return ingestedCount
    }

    /// One directory, all the way to a library row.
    ///
    /// Every failure lands on the same path: recorded against the folder name
    /// so the library can show it, and reported as `.ingestFailed`. The folder
    /// is never deleted and never silently skipped, and a document that was
    /// already readable stays readable — recording the failure does not take a
    /// document's pinned bytes away
    /// (`DocumentStoring.recordIngestFailure(folderName:reason:)`).
    private func ingest(_ item: InboxItem) async -> Bool {
        do {
            let pinned = try await pinner.pin(item)
            let document = try await ingester.ingest(pinned)
            let summary = try await store.upsert(document)
            await adoptGroup(for: document)
            emit(.ingested(documentId: summary.id, title: summary.title))
            return true
        } catch {
            if Task.isCancelled {
                // The scan was stopped, which says nothing about the document.
                // Recording a failure here would put an error against a folder
                // that was merely interrupted.
                SyncLog.coordinator.notice("Ingest of \(item.folderName) stopped with the scan.")
                return false
            }
            // If the pin got as far as writing a copy, the library does not
            // reflect it, so the copy must not be trusted as current — or the
            // `isPinnedAndCurrent` shortcut above would skip this folder on
            // every later scan and it would never reach the library at all.
            // Only the sidecar goes; the bytes stay, so anything already
            // readable stays readable.
            pinner.invalidateSnapshot(forFolderNamed: item.folderName)

            let reason = SyncCoordinator.message(for: error)
            SyncLog.coordinator.error("Ingest failed for \(item.folderName): \(reason)")
            try? await store.recordIngestFailure(folderName: item.folderName, reason: reason)
            emit(.ingestFailed(folderName: item.folderName, reason: reason))
            return false
        }
    }

    /// Sends anything that was queued while the folder was away. Stops at the
    /// first failure — if the folder is still unreachable, the rest will not
    /// fare better, and they stay queued.
    ///
    /// **This is where a queued review becomes a sent one.** A bundle that went
    /// to the local queue is sent-pending: the review sheet leaves the document
    /// in `.reviewing` with no `sentAt`, because nothing has reached `outbox/`
    /// for an agent to answer yet (docs/04-flows.md § F7). The moment the write
    /// below succeeds, it has — and this actor is the only thing that always
    /// knows, because the sheet the user sent from has usually been closed for
    /// hours by then. Recording it here is what makes the reply loop reachable:
    /// `recordReply` alone stores the text, and without the directory name
    /// "Open reply as document" has nothing to ask
    /// `ingestReply(fromReviewDirectory:)` for.
    ///
    /// Recorded *before* the event goes out, so a sheet that is still open
    /// reads a store that already agrees with it rather than writing a second,
    /// competing delivery of its own (ReviewSheetModel § `apply(_:)`).
    private func flushQueue() async {
        let waiting = queue.queuedPayloads()
        guard waiting.isEmpty == false else { return }
        for payload in waiting {
            do {
                let written = try await writer.write(payload, to: folder)
                queue.remove(payload.directoryName)
                await recordDelivery(of: written)
                emit(.reviewWritten(documentId: written.documentId, directoryURL: written.directoryURL))
            } catch {
                SyncLog.coordinator.notice("\(payload.directoryName) is still waiting to be sent.")
                return
            }
        }
    }

    /// Records a flushed bundle against its document: sent, in the directory a
    /// reply will come back in, and read.
    ///
    /// Both writes, because both are what the review sheet does on the
    /// equivalent path (`ReviewSheetModel.recordSent`) and a document that is
    /// recorded as sent while still sitting under "Reviewing" is the two of
    /// them disagreeing in front of the user.
    ///
    /// Failures are swallowed on purpose: the bundle is in `outbox/` either
    /// way, this is background work, and a store that will not take the note is
    /// not a reason to leave a delivered review in the queue. A document the
    /// library has never heard of throws `.documentNotFound` here and is
    /// exactly that case.
    private func recordDelivery(of written: WrittenReview) async {
        try? await store.recordReviewSent(
            documentId: written.documentId,
            at: written.writtenAt,
            directoryName: written.directoryName
        )
        try? await store.setState(.read, documentId: written.documentId)
    }

    // MARK: - Replies

    private func collectRepliesWithAccess() async {
        let started = access.beginAccess(to: folder)
        defer { access.endAccess(to: folder, wasStarted: started) }
        await collectReplies()
    }

    /// The caller must already hold access.
    private func collectReplies() async {
        for reply in replyScanner.scan(folder) {
            let key = "\(reply.reviewDirectoryName)@\(reply.modifiedAt.timeIntervalSince1970)"
            if deliveredReplies.contains(key) { continue }
            deliveredReplies.insert(key)

            let found = try? await store.documentId(forFolderName: reply.documentFolderName)
            guard let documentId = found ?? nil else {
                SyncLog.coordinator.notice("A reply arrived for \(reply.documentFolderName), which is not in the library.")
                continue
            }
            let read = try? await writer.readReply(inReviewDirectory: reply.reviewDirectoryName, in: folder)
            guard let text = read ?? nil else { continue }

            try? await store.recordReply(documentId: documentId, text: text, receivedAt: reply.modifiedAt)
            emit(.replyReceived(documentId: documentId, replyURL: reply.replyURL))
        }
    }

    // MARK: - Watching

    private func startWatching() {
        watchTask?.cancel()
        let stream = watcher.events(for: folder)
        watchTask = Task { [weak self] in
            for await event in stream {
                guard let self else { return }
                await self.handle(event)
            }
        }
    }

    private func handle(_ event: FolderEvent) async {
        switch event {
        case .inboxChanged:
            _ = try? await performScan()
        case let .inboxRemoved(folderName):
            // The document stays in the library. Losing the folder costs you
            // new documents, never existing ones (docs/02-spec.md).
            SyncLog.coordinator.notice("\(folderName) is no longer in the inbox; the document stays in the library.")
        case .replyAppeared:
            await collectRepliesWithAccess()
        case let .folderUnavailable(reason):
            emit(.folderUnavailable(reason: reason))
        case .folderRestored:
            await forgetScanMemory()
            _ = try? await performScan()
        }
    }

    private func pokeWatcher() async {
        guard let polling = watcher as? PollingFolderWatcher else { return }
        await polling.pokeNow()
    }

    /// After the folder has been away, anything could have changed while we
    /// were not looking, so the scanner's memory of what it has handled is
    /// thrown out and every folder is examined again. `refresh()` does the same
    /// on the user's behalf.
    private func forgetScanMemory() async {
        deferredFailures.removeAll()
        guard let concrete = scanner as? InboxScanner else { return }
        await concrete.forgetSeenFolders()
    }

    /// Tells the scanner that a folder needs no further attention until it
    /// changes on disk.
    ///
    /// Called only after an ingest succeeded, or for a folder found already
    /// pinned and current. A folder that failed is deliberately left unmarked,
    /// so the next scan reports it again — the retry the user is promised.
    ///
    /// A scanner this coordinator did not build has no such memory to update,
    /// and rescanning a handled folder costs one sidecar read.
    private func markHandled(_ item: InboxItem) async {
        guard let concrete = scanner as? InboxScanner else { return }
        await concrete.markHandled(item)
    }

    // MARK: - Events

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

    // MARK: - Internals

    /// Writes a new directory into `inbox/` the way every other writer of this
    /// folder does: a hidden sibling, then a coordinated rename
    /// (integrations/README.md § Conventions).
    private func writeInboxDirectory(named folderName: String, files: [(String, Data)]) throws {
        let manager = FileManager.default
        let staging = folder.inboxURL.appendingPathComponent(
            SyncFileNames.stagingName(for: folderName, token: UUID().uuidString),
            isDirectory: true
        )
        let destination = folder.inboxURL.appendingPathComponent(folderName, isDirectory: true)
        do {
            try manager.createDirectory(at: staging, withIntermediateDirectories: true)
            for (name, data) in files {
                try data.write(to: staging.appendingPathComponent(name, isDirectory: false), options: [.atomic])
            }
            try CoordinatedFileAccess.move(from: staging, to: destination) { movableSource, replaceableDestination in
                if manager.fileExists(atPath: replaceableDestination.path) {
                    _ = try manager.replaceItemAt(replaceableDestination, withItemAt: movableSource)
                    return
                }
                try manager.moveItem(at: movableSource, to: replaceableDestination)
            }
        } catch {
            try? manager.removeItem(at: staging)
            throw PencilLoopError.folderUnavailable(
                reason: "\(folderName) could not be written to the inbox. \(error.localizedDescription)"
            )
        }
    }

    /// A sentence for the library's error row.
    static func message(for error: Error) -> String {
        if let known = error as? PencilLoopError { return known.message }
        return error.localizedDescription
    }
}
