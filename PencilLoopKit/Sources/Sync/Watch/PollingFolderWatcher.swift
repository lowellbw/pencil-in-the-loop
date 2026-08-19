//
//  PollingFolderWatcher.swift
//  Sync · Watch
//
//  ─── POLLING IS PRIMARY. THE PRESENTER IS AN ACCELERANT. ─────────────────────
//  docs/04-flows.md § F1 draws the arrival path as "NSFilePresenter fires". It
//  is drawn that way because that is how it works on a local filesystem. The
//  sync folder is not one: it is a file-provider folder (docs/08 § q2), and a
//  provider creates a directory entry before the bytes exist, delivers files in
//  transfer order rather than write order, and can stay silent for an item that
//  was evicted and later re-downloaded.
//
//  So the loop below asks the only question that survives all of that — *what
//  is in the folder now, and is it different from last time?* — and asks it on
//  a timer. The presenter shortens the wait when the system happens to tell us
//  something; it never decides anything. `docs/02-spec.md` § S1 already
//  anticipates this ("file coordination does not reliably see every change a
//  provider makes in the background, which is why pull-to-refresh exists"), and
//  the Mac-side watcher reached the same conclusion from the other end
//  (integrations/mac-watcher/README.md § Why polling, not FSEvents).
//
//  Three ways a scan happens, in order of how much the user notices:
//
//    · foreground — `SyncCoordinating.start()`, which scans immediately;
//    · the timer — every `pollInterval` (15s) while the watcher is running;
//    · pull-to-refresh — `SyncCoordinating.refresh()`, always a full re-scan.
//
//  Emitting a duplicate event is free; missing one is not. When in doubt this
//  file emits.
//  ─────────────────────────────────────────────────────────────────────────────
//

import Foundation
import Core

/// `FolderWatching` by polling, with an `NSFilePresenter` that only ever says
/// "now, please".
///
/// **When it fails or is unavailable:** emits `FolderEvent.folderUnavailable`
/// and keeps the stream open, then emits `.folderRestored` when the root comes
/// back. The stream ends only when the consumer stops consuming or `stop()` is
/// called — a watcher that ends its stream on the first hiccup turns a
/// temporarily ejected volume into an app restart.
///
/// **Not a source of truth.** Events mean "look again". Every consumer must
/// tolerate duplicates, misses and out-of-order delivery by re-scanning.
public actor PollingFolderWatcher: FolderWatching {

    /// What one directory looked like at one moment.
    public struct Fingerprint: Sendable, Hashable {

        /// One entry — an inbox directory, or a `reply.md`.
        public struct Entry: Sendable, Hashable {

            /// The directory or file this describes.
            public var url: URL

            /// Newest modification date beneath it.
            public var modifiedAt: Date

            /// Total bytes beneath it. Part of the fingerprint because a
            /// provider can deliver bytes without moving the modification date.
            public var byteCount: Int64

            public init(url: URL, modifiedAt: Date, byteCount: Int64) {
                self.url = url
                self.modifiedAt = modifiedAt
                self.byteCount = byteCount
            }
        }

        /// Keyed by directory or bundle name.
        public var entries: [String: Entry]

        public init(entries: [String: Entry] = [:]) {
            self.entries = entries
        }

        /// Nothing seen yet. The first poll compares against this, which is why
        /// a freshly started watcher reports everything already in the folder.
        public static let empty = Fingerprint()
    }

    /// One complete look at the folder.
    public struct Sample: Sendable, Hashable {

        /// False when the root could not be read at all.
        public var isReachable: Bool

        /// `inbox/`, one entry per directory.
        public var inbox: Fingerprint

        /// `outbox/`, one entry per `reply.md`.
        public var replies: Fingerprint

        public init(isReachable: Bool, inbox: Fingerprint = .empty, replies: Fingerprint = .empty) {
            self.isReachable = isReachable
            self.inbox = inbox
            self.replies = replies
        }

        /// What a poll returns when the root is gone.
        public static let unreachable = Sample(isReachable: false)
    }

    /// Fifteen seconds, matching the Mac-side watcher's default so the two ends
    /// of the folder have the same worst-case latency
    /// (integrations/mac-watcher/README.md § Config).
    public static let defaultPollInterval: TimeInterval = 15

    /// How long the loop sleeps between checks of the poke flag. Small enough
    /// that a presenter callback feels immediate, large enough to be free.
    static let wakeSliceSeconds: TimeInterval = 1

    /// How often the folder is examined while the watcher is running.
    public let pollInterval: TimeInterval

    private let access: any FolderAccessing

    private var continuation: AsyncStream<FolderEvent>.Continuation?
    private var pollTask: Task<Void, Never>?
    private var presenter: InboxFilePresenter?
    private var previous: Sample = .unreachable
    private var hasSampled = false
    private var pokeRequested = false

    /// - Parameters:
    ///   - pollInterval: seconds between scans. Tests pass something small; the
    ///     app uses the default.
    ///   - access: how the security scope is opened around each scan.
    public init(
        pollInterval: TimeInterval = PollingFolderWatcher.defaultPollInterval,
        access: any FolderAccessing = SyncFolderAccess()
    ) {
        self.pollInterval = pollInterval
        self.access = access
    }

    // MARK: - FolderWatching

    /// Starts watching and returns the event stream.
    ///
    /// Cancelling the consuming task stops the watcher and releases the
    /// `NSFilePresenter`. Calling this twice replaces the first stream, which
    /// is then finished.
    public nonisolated func events(for folder: SyncFolder) -> AsyncStream<FolderEvent> {
        let (stream, continuation) = AsyncStream<FolderEvent>.makeStream()
        continuation.onTermination = { [weak self] _ in
            guard let self else { return }
            Task { await self.stop() }
        }
        Task { await self.begin(folder: folder, continuation: continuation) }
        return stream
    }

    /// Stops watching. Idempotent.
    public func stop() async {
        pollTask?.cancel()
        pollTask = nil
        presenter?.unregister()
        presenter = nil
        continuation?.finish()
        continuation = nil
        hasSampled = false
        previous = .unreachable
    }

    // MARK: - Poking

    /// Runs the next scan immediately rather than at the end of the interval.
    ///
    /// The presenter calls this, and so does the coordinator when the app comes
    /// to the foreground. Safe to call as often as you like: the loop coalesces
    /// pokes into one scan.
    public func pokeNow() {
        pokeRequested = true
    }

    // MARK: - The loop

    private func begin(folder: SyncFolder, continuation newContinuation: AsyncStream<FolderEvent>.Continuation) {
        // "Calling this twice replaces the first stream, which is then
        // finished."
        pollTask?.cancel()
        presenter?.unregister()
        continuation?.finish()

        continuation = newContinuation
        hasSampled = false
        previous = .unreachable

        let presenter = InboxFilePresenter(url: folder.rootURL) { [weak self] in
            guard let self else { return }
            Task { await self.pokeNow() }
        }
        presenter.register()
        self.presenter = presenter

        pollTask = Task { [weak self] in
            guard let self else { return }
            while Task.isCancelled == false {
                await self.pollOnce(folder: folder)
                await self.waitForNextPoll()
            }
        }
        SyncLog.watch.info("Watching \(folder.displayName) — polling every \(self.pollInterval)s.")
    }

    /// One look at the folder, and whatever events it implies.
    func pollOnce(folder: SyncFolder) async {
        // `FolderAccessing` declares `withAccess` twice, differing only in
        // whether the closure is async, and a synchronous closure literal
        // converts freely to the async parameter type — so a bare call from
        // this `async` method is an overload the compiler could resolve either
        // way. Naming the closure's type as `async` leaves exactly one
        // candidate: an async function value cannot convert to a synchronous
        // parameter, so this is the async overload and nothing else.
        let read: @Sendable (SyncFolder) async -> Sample = { scoped in
            PollingFolderWatcher.sample(of: scoped)
        }

        let sample: Sample
        do {
            sample = try await access.withAccess(to: folder, perform: read)
        } catch {
            sample = .unreachable
        }

        guard sample.isReachable else {
            if previous.isReachable || hasSampled == false {
                hasSampled = true
                previous = .unreachable
                emit(.folderUnavailable(
                    reason: "The folder could not be read. Documents already downloaded are unaffected."
                ))
            }
            return
        }

        if hasSampled, previous.isReachable == false {
            emit(.folderRestored)
        }

        for event in PollingFolderWatcher.inboxChanges(from: previous.inbox, to: sample.inbox) {
            emit(event)
        }
        for event in PollingFolderWatcher.replyChanges(from: previous.replies, to: sample.replies) {
            emit(event)
        }

        previous = sample
        hasSampled = true
    }

    /// Sleeps until the next poll, waking early when somebody pokes.
    private func waitForNextPoll() async {
        let slice = max(0.01, min(PollingFolderWatcher.wakeSliceSeconds, pollInterval))
        let slices = max(1, Int((pollInterval / slice).rounded()))
        let sliceNanoseconds = UInt64(slice * 1_000_000_000)
        for _ in 0..<slices {
            if Task.isCancelled { return }
            if pokeRequested {
                pokeRequested = false
                return
            }
            try? await Task.sleep(nanoseconds: sliceNanoseconds)
        }
        pokeRequested = false
    }

    private func emit(_ event: FolderEvent) {
        continuation?.yield(event)
    }

    // MARK: - Sampling and diffing, as pure functions

    /// Reads the folder. Synchronous on purpose: it does no waiting of its own,
    /// and it is called from inside `FolderAccessing.withAccess(to:perform:)`
    /// so the security scope is open for the whole of it.
    ///
    /// - Returns: `.unreachable` when the root is not a readable directory.
    public static func sample(of folder: SyncFolder) -> Sample {
        let manager = FileManager.default
        // Not `resourceValues`: the root URL outlives every poll, and a URL
        // caches the resource values it has been asked for, so this check would
        // answer "still there" for the rest of the run no matter what happened
        // to the folder. See SyncFolderAccess.isDirectory(_:).
        guard SyncFolderAccess.isDirectory(folder.rootURL) else { return .unreachable }

        return Sample(
            isReachable: true,
            inbox: inboxFingerprint(of: folder.inboxURL, manager: manager),
            replies: replyFingerprint(of: folder.outboxURL, manager: manager)
        )
    }

    /// `.inboxChanged` for anything new or rewritten, `.inboxRemoved` for
    /// anything gone. Sorted by name so two runs over the same folder produce
    /// the same order.
    public static func inboxChanges(from previous: Fingerprint, to current: Fingerprint) -> [FolderEvent] {
        var events: [FolderEvent] = []
        for name in current.entries.keys.sorted() {
            guard let entry = current.entries[name] else { continue }
            if previous.entries[name] != entry {
                events.append(.inboxChanged(directoryURL: entry.url))
            }
        }
        for name in previous.entries.keys.sorted() where current.entries[name] == nil {
            events.append(.inboxRemoved(folderName: name))
        }
        return events
    }

    /// `.replyAppeared` for every reply that is new or has been rewritten. A
    /// reply that vanishes produces nothing: the Sent screen keeps what it has
    /// already recorded.
    public static func replyChanges(from previous: Fingerprint, to current: Fingerprint) -> [FolderEvent] {
        var events: [FolderEvent] = []
        for name in current.entries.keys.sorted() {
            guard let entry = current.entries[name] else { continue }
            if previous.entries[name] != entry {
                events.append(.replyAppeared(reviewFolderName: name, replyURL: entry.url))
            }
        }
        return events
    }

    // MARK: - Internals

    private static func inboxFingerprint(of inboxURL: URL, manager: FileManager) -> Fingerprint {
        guard let entries = try? manager.contentsOfDirectory(
            at: inboxURL,
            includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return .empty
        }

        var result = Fingerprint()
        for entry in entries {
            let name = entry.lastPathComponent
            if SyncFileNames.isHidden(name) { continue }
            let values = try? entry.resourceValues(forKeys: [.isDirectoryKey])
            guard values?.isDirectory == true else { continue }
            result.entries[name] = directoryEntry(at: entry, manager: manager)
        }
        return result
    }

    private static func replyFingerprint(of outboxURL: URL, manager: FileManager) -> Fingerprint {
        guard let entries = try? manager.contentsOfDirectory(
            at: outboxURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return .empty
        }

        var result = Fingerprint()
        for entry in entries {
            let name = entry.lastPathComponent
            if SyncFileNames.isHidden(name) { continue }
            guard name.hasSuffix(OutboxPayload.reviewDirectorySuffix) else { continue }
            let replyURL = entry.appendingPathComponent(DocumentFileNames.reply, isDirectory: false)
            guard manager.fileExists(atPath: replyURL.path) else { continue }
            let values = try? replyURL.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            result.entries[name] = Fingerprint.Entry(
                url: replyURL,
                modifiedAt: values?.contentModificationDate ?? Date(timeIntervalSince1970: 0),
                byteCount: Int64(values?.fileSize ?? 0)
            )
        }
        return result
    }

    /// Newest modification date and total size beneath a directory, one level
    /// deep — which is as deep as an inbox directory goes.
    private static func directoryEntry(at url: URL, manager: FileManager) -> Fingerprint.Entry {
        var newest = Date(timeIntervalSince1970: 0)
        var bytes: Int64 = 0

        let directoryValues = try? url.resourceValues(forKeys: [.contentModificationDateKey])
        if let modified = directoryValues?.contentModificationDate {
            newest = modified
        }

        let contents = (try? manager.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: []
        )) ?? []

        for file in contents {
            if SyncFileNames.isHidden(file.lastPathComponent) { continue }
            let values = try? file.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            if let modified = values?.contentModificationDate, modified > newest {
                newest = modified
            }
            bytes += Int64(values?.fileSize ?? 0)
        }
        return Fingerprint.Entry(url: url, modifiedAt: newest, byteCount: bytes)
    }
}
