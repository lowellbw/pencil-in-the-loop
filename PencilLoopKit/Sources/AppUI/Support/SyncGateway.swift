//
//  SyncGateway.swift
//  AppUI · Support
//
//  The `SyncCoordinating` the app holds for its whole life, in front of the one
//  it may or may not have yet.
//
//  ─── WHY THERE IS A THING IN FRONT OF SYNC AT ALL ────────────────────────────
//  `SyncCoordinator` is built around a resolved `SyncFolder`. The app is not:
//  it launches before the folder is picked (S0), and it launches perfectly well
//  when the folder has gone away — an ejected volume, a signed-out provider, a
//  bookmark that will not resolve. Losing the folder costs you *new* documents,
//  never existing ones (docs/02-spec.md § Cross-cutting), and the library must
//  open at full speed either way.
//
//  Making `AppEnvironment.sync` optional would push that decision into every
//  screen. Rebuilding the environment when a folder arrives would rebuild every
//  view with it, mid-session. So the environment holds this instead: a stable
//  face that forwards to a coordinator once there is one, and answers honestly
//  when there is not.
//  ─────────────────────────────────────────────────────────────────────────────
//

import Foundation
import Core

/// A `SyncCoordinating` that can be handed its real implementation later.
///
/// **On failure — which here means "no folder yet":** `start()` and `stop()` do
/// nothing, `refresh()` and `ingestReply(fromReviewDirectory:)` throw
/// `PencilLoopError.folderUnavailable`, and `send(_:)` throws the same. Every
/// one of those is user-initiated and has somewhere to show it. Nothing here
/// ever throws into background work, and nothing on the reading or annotating
/// path touches this type at all.
///
/// **Events survive the swap.** A view that started listening before the folder
/// resolved keeps its stream and starts receiving events the moment one is
/// attached. That is the whole reason the listener list lives here rather than
/// being taken from the coordinator on demand.
///
/// **And a folder problem survives having no listeners at all.** The one that
/// matters most is emitted before the library exists — see `SyncEventRelay`,
/// which holds the listeners, remembers the last problem, and replays it to
/// whoever starts listening next.
public actor SyncGateway: SyncCoordinating {

    private var coordinator: (any SyncCoordinating)?
    private var forwarding: Task<Void, Never>?

    /// The listeners, outside the actor so `events()` can register one before
    /// it returns. A `let` of a `Sendable` type, so the nonisolated members
    /// below can reach it (`SyncEventRelay`).
    private nonisolated let relay = SyncEventRelay()

    /// Whether `start()` has been called. A coordinator attached afterwards is
    /// started immediately, so the order of "app foregrounded" and "folder
    /// resolved" does not matter.
    private var isStarted = false

    public init() {}

    // MARK: - Attaching

    /// True once there is a folder and a coordinator behind this.
    public var isAttached: Bool { coordinator != nil }

    /// Puts a real coordinator behind the gateway, replacing any previous one.
    ///
    /// Starts it if the app has already asked the gateway to start.
    public func attach(_ newCoordinator: any SyncCoordinating) async {
        await detach()
        coordinator = newCoordinator
        // A folder has resolved, so whatever the last problem was, it is over
        // and a listener arriving now must not be told otherwise.
        relay.clearFolderProblem()
        let stream = newCoordinator.events()
        forwarding = Task { [relay] in
            for await event in stream {
                relay.emit(event)
            }
        }
        if isStarted {
            await newCoordinator.start()
        }
    }

    /// Lets go of the current coordinator, keeping the listeners. For a folder
    /// the user has replaced in Settings.
    public func detach() async {
        forwarding?.cancel()
        forwarding = nil
        if let coordinator {
            await coordinator.stop()
        }
        coordinator = nil
    }

    /// Reports a folder-level problem to everyone listening, when there is no
    /// coordinator to report it for us — a bookmark that would not resolve at
    /// launch, most often.
    ///
    /// Launch is exactly the moment when "everyone listening" is nobody:
    /// `RootModel.start()` resolves the bookmark before SwiftUI has built the
    /// library. The reason is therefore kept and replayed to the first listener
    /// that appears, which is what puts the sentence in the status line instead
    /// of leaving an unexplained empty library (`SyncEventRelay`).
    public func reportFolderUnavailable(_ reason: String) {
        emit(.folderUnavailable(reason: reason))
    }

    // MARK: - SyncCoordinating

    /// Begins watching and scans, once there is something to watch. Idempotent,
    /// and remembered: a coordinator attached later starts without a second
    /// call.
    public func start() async {
        isStarted = true
        await coordinator?.start()
    }

    /// Stops watching. The library stays fully usable afterwards.
    public func stop() async {
        isStarted = false
        await coordinator?.stop()
    }

    /// A full re-scan, as pull-to-refresh triggers.
    ///
    /// - Throws: `.folderUnavailable` when no folder has been resolved. The
    ///   gesture then shows that sentence in the library's status line, which
    ///   is exactly what the user needs to know.
    public func refresh() async throws -> Int {
        guard let coordinator else { throw SyncGateway.noFolder }
        return try await coordinator.refresh()
    }

    /// One stream per consumer, live across an attach.
    ///
    /// The listener is registered before this returns, not in a `Task` that
    /// gets its turn later: a consumer that has called this and begun iterating
    /// must not be able to miss an event emitted in between. Anything already
    /// emitted that a late listener still needs — a folder that is not there —
    /// is replayed into the stream on registration (`SyncEventRelay`).
    public nonisolated func events() -> AsyncStream<SyncEvent> {
        let identifier = UUID()
        let (stream, continuation) = AsyncStream<SyncEvent>.makeStream()
        continuation.onTermination = { [weak self] _ in
            self?.relay.remove(identifier)
        }
        relay.add(identifier, continuation)
        return stream
    }

    /// Writes a bundle to `outbox/`, or queues it when the folder is
    /// unreachable — both of which need a folder to have been chosen at all.
    ///
    /// - Throws: `.folderUnavailable` when none has. The review sheet keeps the
    ///   comments, keeps the closing instruction, and offers copy, share and
    ///   save; nothing the user wrote is lost by this failing
    ///   (docs/06-integrations.md § The universal fallback).
    public func send(_ payload: OutboxPayload) async throws -> WrittenReview {
        guard let coordinator else { throw SyncGateway.noFolder }
        return try await coordinator.send(payload)
    }

    @discardableResult
    public func ingestReply(fromReviewDirectory reviewDirectoryName: String) async throws -> UUID {
        guard let coordinator else { throw SyncGateway.noFolder }
        return try await coordinator.ingestReply(fromReviewDirectory: reviewDirectoryName)
    }

    // MARK: - Internals

    private static let noFolder = PencilLoopError.folderUnavailable(
        reason: "No sync folder is set up on this iPad. Choose one in Settings; everything already in the library stays readable."
    )

    private nonisolated func emit(_ event: SyncEvent) {
        relay.emit(event)
    }
}
