//
//  RootModel.swift
//  AppUI · Support
//
//  What the app is showing, and the one piece of start-up logic there is:
//  resolve the sync folder if there is one, and do not wait for it if there is
//  not.
//

import Foundation
import Observation
import Core

/// The shell's state: the environment, which screen is up, and the folder.
///
/// **The launch path is deliberately short.** Build the environment, read one
/// setting, show a screen. Everything to do with the sync folder happens after
/// that and never blocks it: a bookmark that resolves attaches a coordinator, a
/// bookmark that does not puts one sentence in the library's status line, and
/// either way the library is already on screen reading from the local store.
/// Cold launch to a readable page has a one-second budget
/// (docs/03-architecture.md § Performance targets) and a file provider that is
/// signed out can take much longer than that to say so.
///
/// **On failure:** the only failure that reaches the user is the library store
/// refusing to open, which is `.unusable` and one sentence. Everything else —
/// no folder, a stale bookmark, an ejected volume — is a degraded sync loop and
/// a fully working reader.
@Observable
@MainActor
public final class RootModel {

    /// Which screen the app is showing.
    public enum Phase: Sendable, Hashable {

        /// Before the first settings read has come back. A frame or two.
        case starting

        /// No folder has ever been chosen: S0, and nothing else
        /// (docs/02-spec.md § S0).
        case firstRun

        /// The library and the reader.
        case library

        /// The library store would not open. `message` is shown verbatim.
        case unusable(message: String)
    }

    public private(set) var phase: Phase = .starting

    /// Built once and held. Nil only before `start()` has run, and after a
    /// failure that made `.unusable` the phase.
    public private(set) var environment: (any AppEnvironment)?

    /// A document the app should select in the library — an agent's reply that
    /// has just been opened as a document (docs/04-flows.md § F6).
    public var pendingSelection: UUID?

    /// The live environment, when the environment is the live one. The shell
    /// needs it for the folder ladder; every view is handed `environment`.
    private var live: LiveEnvironment?

    public init() {}

    /// Previews and `AppUITests`: a shell already holding an environment, so
    /// that nothing builds a real store, opens a real container or resolves a
    /// real bookmark. `start()` finds the phase is not `.starting` and does
    /// nothing.
    public init(previewing environment: any AppEnvironment, phase: Phase = .library) {
        self.environment = environment
        self.phase = phase
    }

    // MARK: - Launch

    /// Builds the environment and decides which screen to show.
    ///
    /// Safe to call more than once: a second call after the app is running
    /// re-scans rather than rebuilding anything.
    public func start() async {
        guard case .starting = phase else {
            await noteActive()
            return
        }

        let built: LiveEnvironment
        do {
            built = try await RootModel.buildEnvironment()
        } catch let error as PencilLoopError {
            phase = .unusable(message: error.message)
            return
        } catch {
            phase = .unusable(message: error.localizedDescription)
            return
        }

        live = built
        environment = built

        var settings = await built.settings.settings

        // An install that predates the relay this build ships pointed at. First
        // run already happened, so the screen that would have adopted it never
        // runs again — `hasCompletedFirstRun` gates behaviour, not just a
        // screen, and every improvement to the default would otherwise reach
        // only people who have never opened the app.
        //
        // ─── WHY THIS ASKS ABOUT A CHOICE, NOT AN ADDRESS ────────────────────
        // It used to ask whether `serverBaseURLString` was nil, on the reasoning
        // that an address could only be there because the relay had been offered
        // and considered. That is not true, and a device proved it: the address
        // was recorded while the transport sat on `.folder`, so this read it as
        // a decision that had been made and declined to act — permanently.
        // Documents stopped arriving and nothing on screen could say why, since
        // from the app's point of view nothing was wrong.
        //
        // So it asks the question it actually means. `transportChosenByUser` is
        // set only by the two Settings actions that are a choice, so nil means
        // nobody has decided and the shipped default may still speak.
        //
        // ─── AND WHY IT NO LONGER ASKS AT ALL ────────────────────────────────
        // The folder transport is gone, so there is no longer a second thing
        // for a choice to have selected. An install that pressed "Folder" has
        // `transportChosenByUser == true` and a transport this build cannot
        // honour; respecting that choice would strand it on a transport that
        // does not exist, permanently, with nothing on screen to say why —
        // exactly the failure the paragraph above was written about. So the
        // two conditions that read the old choice are gone and the shipped
        // relay is adopted for anyone who has not already got one.
        if settings.hasCompletedFirstRun,
           RelayDefaults.isConfigured,
           let baseURL = RelayDefaults.baseURL,
           let token = RelayDefaults.token {
            do {
                try await built.adoptServer(baseURL: baseURL, token: token)
                settings = await built.settings.settings
                ReaderLog.shell.notice("Adopted the relay this build ships with.")
            } catch {
                // Nothing else to fall back to now, so this is reported rather
                // than swallowed: the guard below sends the reader to the
                // server form, which is the only way out.
                ReaderLog.shell.error("Could not adopt the shipped relay: \(error.localizedDescription)")
            }
        }

        if settings.hasCompletedFirstRun, settings.transport == .server {
            // The library first, the relay second — and emphatically in that
            // order. An HTTP request must never be made before the first frame:
            // the launch budget is one second to a readable page, and a server
            // that is slow to answer would spend all of it
            // (docs/03-architecture.md § Performance targets).
            phase = .library
            if await built.adoptPersistedServer() == false {
                await built.gateway.reportFolderUnavailable(
                    "This iPad is set to use a relay, but its address or access token is missing. Add them again in Settings."
                )
            }
            return
        }

        // No relay, or first run never finished: there is one screen left and
        // it asks for a relay.
        phase = .firstRun
    }

    /// Builds the environment away from the main thread.
    ///
    /// `LiveEnvironment.init` opens the SwiftData container, which is a
    /// synchronous store open and, after a schema change, a migration of
    /// unbounded length (`LibraryContainer`). `start()` is on the main actor
    /// because it sets `phase`, so without this hop the whole of that would run
    /// on the thread that is meant to be putting the first frame up. The
    /// launch path stays short by leaving the main actor for the one part of it
    /// that touches disk (docs/03-architecture.md § Performance targets).
    ///
    /// - Throws: whatever the initialiser throws, which is only
    ///   `PencilLoopError.storeWriteFailed`.
    private nonisolated static func buildEnvironment() async throws -> LiveEnvironment {
        try await Task.detached(priority: .userInitiated) {
            try LiveEnvironment()
        }.value
    }

    /// First run finished by adopting a relay.
    ///
    /// `adoptServer` has already attached the coordinator and started it, so
    /// there is nothing left to do but show the library — which is why this
    /// takes no argument.
    public func showLibrary() {
        phase = .library
    }

    /// The scene became active.
    ///
    /// Two jobs, both cheap: re-scan, because the relay may have taken
    /// documents while we were away (docs/02-spec.md § S1), and retry the relay
    /// if it could not be reached at launch — a network comes back, and nothing
    /// else in the app is watching for that.
    public func noteActive() async {
        guard let live, case .library = phase else { return }
        if await live.gateway.isAttached {
            await live.sync.start()
            return
        }
        _ = await live.adoptPersistedServer()
    }

    /// The scene went away. Stops the watcher; the library stays fully usable.
    public func noteInactive() async {
        guard let live else { return }
        await live.sync.stop()
    }

    /// Puts a sync problem where sync problems belong: the library's status
    /// line, through the same event stream a running coordinator would use.
    private func report(_ error: any Error, in live: LiveEnvironment) async {
        await live.gateway.reportFolderUnavailable(SyncFailure.describe(error))
    }
}
