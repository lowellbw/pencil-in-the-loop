//
//  SyncEventRelay.swift
//  AppUI · Support
//
//  `SyncGateway`'s listener list, and the one folder problem it remembers.
//
//  ─── WHY THIS IS NOT ACTOR STATE ─────────────────────────────────────────────
//  `SyncCoordinating.events()` is nonisolated and returns its stream
//  synchronously, so a gateway that keeps its listeners inside the actor can
//  only register them from a `Task` — which means a consumer that has already
//  called `events()` and started iterating can still miss an event emitted
//  before that task got its turn. The registration has to complete before
//  `events()` returns, and that means a lock rather than an actor hop.
//
//  The same list is where a folder problem is remembered. `AsyncStream` does not
//  replay, and the one folder problem that matters most is emitted before any
//  view exists: `RootModel.start()` resolves the bookmark in the same
//  continuation that sets `phase = .library`, so a stale bookmark, an ejected
//  volume or a signed-out provider reaches `reportFolderUnavailable` before
//  SwiftUI has built `LibraryView` and run its `.task`. That sentence used to be
//  emitted to nobody, and the user got a silent empty library.
//  ─────────────────────────────────────────────────────────────────────────────
//

import Foundation
import os
import Core

/// The gateway's listeners, and the last folder problem, behind one lock.
///
/// **On failure:** there is none to report. Registering, removing and emitting
/// are total; a listener whose stream has already finished simply drops what it
/// is yielded, which is what `AsyncStream` does anyway.
nonisolated final class SyncEventRelay: Sendable {

    /// Everything the relay holds. One value under one lock, so that a listener
    /// arriving cannot interleave with an event being sent — the interleaving
    /// is the bug this type exists to remove.
    private nonisolated struct State {

        var listeners: [UUID: AsyncStream<SyncEvent>.Continuation] = [:]

        /// The last `.folderUnavailable`, kept so a listener that arrives after
        /// it was emitted still learns the folder is not there. Cleared as soon
        /// as anything else happens, because every other event is proof the
        /// folder answered.
        var folderProblem: SyncEvent?
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    init() {}

    /// Registers a listener, and replays the folder problem it was too late for.
    ///
    /// The replay happens outside the lock: yielding is cheap, but a stream
    /// whose consumer has gone away runs its `onTermination` handler, and that
    /// handler comes back here to remove itself.
    func add(_ identifier: UUID, _ continuation: AsyncStream<SyncEvent>.Continuation) {
        let missed = state.withLock { current -> SyncEvent? in
            current.listeners[identifier] = continuation
            return current.folderProblem
        }
        guard let missed else { return }
        continuation.yield(missed)
    }

    func remove(_ identifier: UUID) {
        state.withLock { current in
            current.listeners[identifier] = nil
        }
    }

    /// Sends one event to everyone listening, and updates what a late listener
    /// will be told.
    func emit(_ event: SyncEvent) {
        let continuations = state.withLock { current -> [AsyncStream<SyncEvent>.Continuation] in
            if case .folderUnavailable = event {
                current.folderProblem = event
            } else {
                current.folderProblem = nil
            }
            return Array(current.listeners.values)
        }
        for continuation in continuations {
            continuation.yield(event)
        }
    }

    /// A folder has been resolved and a coordinator attached, so whatever the
    /// last problem was, it is over.
    func clearFolderProblem() {
        state.withLock { current in
            current.folderProblem = nil
        }
    }

    /// What a listener registering now would be replayed, or nil when the
    /// folder is not known to be in trouble. For tests and for `SyncGateway`'s
    /// own reading of its state.
    var folderProblem: SyncEvent? {
        state.withLock { current in current.folderProblem }
    }
}
