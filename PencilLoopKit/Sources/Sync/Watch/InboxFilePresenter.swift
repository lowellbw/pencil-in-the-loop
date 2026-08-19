//
//  InboxFilePresenter.swift
//  Sync · Watch
//
//  The `NSFilePresenter` half of the watcher, and deliberately the smaller
//  half.
//
//  ─── WHY THIS DOES NOT EMIT EVENTS ───────────────────────────────────────────
//  docs/04-flows.md § F1 draws ingest as "source writes inbox/<slug>/ →
//  NSFilePresenter fires". On a file-provider folder that is not reliable: the
//  provider materialises a directory entry before the bytes behind it exist,
//  delivers files in whatever order the transfer completes, and may say nothing
//  at all for an item that was evicted and later re-downloaded
//  (docs/02-spec.md § S1, and integrations/mac-watcher/README.md § Why polling,
//  not FSEvents, which reached the same conclusion independently on the Mac).
//
//  So the presenter is an accelerant, not a source of truth: every callback
//  does exactly one thing, which is to ask the poll loop to run now instead of
//  in fifteen seconds. Nothing observes the callback's arguments, nothing
//  diffs, and a callback that never arrives costs latency and nothing else.
//  ─────────────────────────────────────────────────────────────────────────────
//

import Foundation

/// Tells the watcher that something in the sync folder moved.
///
/// **When it fails or is unavailable:** it says nothing, and the poll loop
/// carries the whole load. That is the normal case on a file provider, and it
/// is why nothing in this app depends on a presenter callback arriving.
// SAFETY: every stored property is a `let` — a URL, an OperationQueue and a @Sendable closure — nothing mutates after `init`, and the callbacks only forward to that closure.
public final class InboxFilePresenter: NSObject, NSFilePresenter, @unchecked Sendable {

    /// The directory being presented. Registering on the sync root covers both
    /// `inbox/` and `outbox/` through the subitem callbacks.
    public let presentedItemURL: URL?

    /// Callbacks arrive here. Serial by construction: the callbacks are cheap
    /// and there is no reason to let them overlap.
    public let presentedItemOperationQueue: OperationQueue

    /// What to do when anything at all changes. Called with no arguments on
    /// purpose — see the file header.
    private let onChange: @Sendable () -> Void

    /// - Parameters:
    ///   - url: the directory to present, normally the sync root.
    ///   - onChange: run on every callback. Must be cheap and must be safe to
    ///     call far more often than anything actually changed.
    public init(url: URL, onChange: @escaping @Sendable () -> Void) {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.name = "co.pencil-loop.sync.presenter"
        self.presentedItemURL = url
        self.presentedItemOperationQueue = queue
        self.onChange = onChange
        super.init()
    }

    /// Registers with the coordination system. Best-effort: on a provider that
    /// never calls back, this costs nothing and changes nothing.
    public func register() {
        NSFileCoordinator.addFilePresenter(self)
    }

    /// Unregisters. Idempotent, and required — a presenter that outlives its
    /// watcher keeps the whole object graph alive.
    public func unregister() {
        NSFileCoordinator.removeFilePresenter(self)
    }

    // MARK: - NSFilePresenter

    /// Something inside the presented directory changed.
    public func presentedSubitemDidChange(at url: URL) {
        onChange()
    }

    /// The presented directory itself changed.
    public func presentedItemDidChange() {
        onChange()
    }
}
