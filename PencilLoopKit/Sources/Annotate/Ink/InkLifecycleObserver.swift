//
//  InkLifecycleObserver.swift
//  Annotate · Ink
//
//  The one case a page-keyed debounce cannot survive on its own: the process is
//  suspended before the timer fires. Everything else — recycling, rotation,
//  closing a document, switching pages — is handled by the pending work living
//  in `InkPersistenceCoordinator` rather than in a view.
//

import Foundation
import UIKit

/// Flushes ink when the app is about to stop running.
///
/// Observes the three notifications that mean "you may not get another turn":
/// resigning active, entering the background, and terminating. Each one runs the
/// flush inside a background-task assertion, because a `SwiftData` write that
/// starts as the app suspends and does not finish is exactly the data loss the
/// assertion exists to prevent.
///
/// **On failure:** if the assertion cannot be taken — the system is already out
/// of background time — the flush is attempted anyway. It is a few milliseconds
/// of work and very likely to complete; failing to try would guarantee the loss
/// the assertion only makes unlikely.
///
/// Not `Sendable`, and not an actor: it is a bag of notification tokens owned by
/// whoever created it, and it hands the actual work to a `@Sendable` closure.
public final class InkLifecycleObserver {

    private let tokens: [NSObjectProtocol]

    /// - Parameter onDeactivate: what to run. In practice
    ///   `{ await coordinator.flushAll() }`.
    ///
    /// Main actor because `UIApplication`'s notification names are; the object
    /// itself is not isolated, so `deinit` can unregister from wherever it
    /// happens to run.
    @MainActor
    public init(onDeactivate: @escaping @Sendable () async -> Void) {
        let names = [
            UIApplication.willResignActiveNotification,
            UIApplication.didEnterBackgroundNotification,
            UIApplication.willTerminateNotification
        ]
        let centre = NotificationCenter.default
        self.tokens = names.map { name in
            centre.addObserver(forName: name, object: nil, queue: OperationQueue.main) { _ in
                Task { await InkLifecycleObserver.flush(using: onDeactivate) }
            }
        }
    }

    deinit {
        let centre = NotificationCenter.default
        for token in self.tokens {
            centre.removeObserver(token)
        }
    }

    /// Runs a flush under a background-task assertion.
    ///
    /// Public because the scene that owns the reader should call the same thing
    /// from its `scenePhase` handler: notifications and SwiftUI's scene phase do
    /// not always both arrive, and flushing twice costs nothing — the second one
    /// finds nothing pending.
    @MainActor
    public static func flush(using body: @Sendable () async -> Void) async {
        let identifier = UIApplication.shared.beginBackgroundTask(
            withName: "co.pencil-loop.ink-flush",
            expirationHandler: nil
        )
        await body()
        guard identifier != UIBackgroundTaskIdentifier.invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
    }
}
