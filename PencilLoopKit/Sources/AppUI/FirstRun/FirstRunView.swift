//
//  FirstRunView.swift
//  AppUI · FirstRun
//
//  S0. One screen, one job (docs/02-spec.md § S0).
//

import SwiftUI
import UniformTypeIdentifiers
import Core
import Sync

/// Settle the sync folder. That is the whole screen, and in the ordinary case
/// nobody reads it.
///
/// **It tries the default first.** The app's own iCloud container needs no
/// picking and is visible on the Mac as `iCloud Drive/PencilLoop`
/// (`DefaultSyncFolder`), so on a device with iCloud Drive on, this screen
/// resolves it, adopts it and is gone — one line of status, no decision, no
/// account, no carousel, no logo (docs/01-design-principles.md § 6).
///
/// **The picker is the fallback, not the flow.** iCloud Drive can be off, the
/// device can be signed out, and somebody may simply keep their documents
/// somewhere else. Then the button appears, with the reason above it, and S0 is
/// what it always was. Settings offers the same picker afterwards (S6), so the
/// default is a default rather than a decision made on the user's behalf.
///
/// Either way the bookmark is stored and `inbox/`/`outbox/` are created by
/// `SyncFolderChoice.adopt(_:folderAccess:settings:)` — one path for a picked
/// folder and a defaulted one, so there is no second way to be half-set-up.
/// Once `AppSettings.hasCompletedFirstRun` is set the shell shows the library
/// instead and this screen is never seen again.
///
/// **On failure:** the reason appears in secondary text and the button stays.
/// There is no dead end here — the only way out of this screen is a folder, so
/// it must always be possible to try again.
public struct FirstRunView: View {

    private let environment: any AppEnvironment
    private let onFinish: (SyncFolder) -> Void

    /// Called when the user connected a relay instead of picking a folder.
    /// Takes no folder, because there is not one — `adoptServer` has already
    /// attached the coordinator by the time this fires.
    private let onAdoptedServer: () -> Void

    @State private var isChoosingFolder = false
    @State private var isPreparing = false
    @State private var problem: String?

    /// Nil until the default has been tried. Until then the screen shows the
    /// status line alone: offering a picker for half a second and then taking
    /// it away as iCloud answers would be worse than showing nothing.
    @State private var hasTriedDefault = false
    @State private var isChoosingServer = false
    @State private var serverURLText = ""
    @State private var serverToken = ""

    /// - Parameters:
    ///   - environment: settings are written through it, the folder is prepared
    ///     through its `folderAccess`, and the one-time speech asset download
    ///     is started through its transcriber (docs/03-architecture.md § 4).
    ///   - onFinish: called with the prepared folder, so the shell can start
    ///     syncing it without re-reading settings.
    public init(
        environment: any AppEnvironment,
        onFinish: @escaping (SyncFolder) -> Void = { _ in },
        onAdoptedServer: @escaping () -> Void = {}
    ) {
        self.environment = environment
        self.onFinish = onFinish
        self.onAdoptedServer = onAdoptedServer
    }

    public var body: some View {
        VStack(spacing: 24) {
            Text(explanation)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)

            // Only once the default has been tried and did not work. Before
            // that there is nothing to choose and nothing worth tapping.
            if hasTriedDefault {
                Button("Choose Folder…") {
                    isChoosingFolder = true
                }
                .font(.body)
                .disabled(isPreparing)

                // The second way out, and deliberately the quieter one. A
                // folder needs no network, no account and nobody's uptime, and
                // stays the path this app was designed around.
                Button("Use a relay instead…") {
                    isChoosingServer = true
                }
                .font(.footnote)
                .disabled(isPreparing)
            }

            if let problem {
                Text(problem)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .fileImporter(isPresented: $isChoosingFolder, allowedContentTypes: [.folder]) { result in
            self.handle(result)
        }
        .task {
            await self.adoptDefaultFolder()
        }
        .sheet(isPresented: $isChoosingServer) {
            NavigationStack {
                Form {
                    SyncServerForm(
                        urlText: $serverURLText,
                        token: $serverToken,
                        isBusy: isPreparing,
                        problem: problem,
                        onConnect: { Task { await self.adoptServer() } }
                    )
                }
                .navigationTitle("Relay")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { isChoosingServer = false }
                    }
                }
            }
        }
    }

    /// Connect a relay from first run.
    ///
    /// The token is cleared as soon as the call returns, whichever way it went:
    /// a credential should not sit in view state waiting to be screenshotted.
    private func adoptServer() async {
        isPreparing = true
        problem = nil
        do {
            let url = try SyncServerChoice.validate(urlText: serverURLText, token: serverToken)
            try await environment.adoptServer(
                baseURL: url,
                token: SyncServerChoice.cleaned(token: serverToken)
            )
            serverToken = ""
            isChoosingServer = false
            await environment.transcriber.prepareAssets()
            onAdoptedServer()
        } catch {
            serverToken = ""
            problem = SyncServerChoice.describe(error)
        }
        isPreparing = false
    }

    /// What the screen says, which depends only on whether the default is still
    /// being tried.
    private var explanation: String {
        if hasTriedDefault {
            return "Choose a folder this iPad shares with your computer. Documents put there appear in your library, and the reviews you send go back the same way."
        }
        if RelayDefaults.isConfigured {
            return "Connecting to your library."
        }
        return "Setting up your folder in iCloud Drive. Documents put there appear in your library, and the reviews you send go back the same way."
    }

    /// Resolve the app's iCloud folder and adopt it, falling back to the picker.
    ///
    /// The resolve is `Task.detached` because
    /// `url(forUbiquityContainerIdentifier:)` blocks, for seconds on a first
    /// call — running it on the main actor would hold the frame this screen is
    /// currently drawing (`DefaultSyncFolder`, file header).
    private func adoptDefaultFolder() async {
        guard hasTriedDefault == false, isPreparing == false else { return }
        isPreparing = true

        // A build that ships pointed at a relay has nothing to ask. This is the
        // whole of first run for anyone using one: no folder, no address, no
        // token, no screen they have to understand before they can read
        // anything.
        if RelayDefaults.isConfigured,
           let baseURL = RelayDefaults.baseURL,
           let token = RelayDefaults.token {
            do {
                try await environment.adoptServer(baseURL: baseURL, token: token)
                await environment.transcriber.prepareAssets()
                isPreparing = false
                onAdoptedServer()
                return
            } catch {
                // Fall through to the folder. A relay that will not take us is
                // a reason to offer the other transport, not to stop.
                problem = SyncServerChoice.describe(error)
            }
        }
        do {
            let url = try await Task.detached(priority: .userInitiated) {
                try DefaultSyncFolder.locate()
            }.value
            try await self.finish(adopting: url)
        } catch {
            // Not an error the user did anything about, so it is stated rather
            // than apologised for, and the picker appears underneath it.
            self.problem = SyncFolderChoice.describe(error)
            self.hasTriedDefault = true
        }
        isPreparing = false
    }

    private func handle(_ result: Result<URL, any Error>) {
        switch result {
        case let .success(url):
            adopt(url)
        case let .failure(error):
            problem = SyncFolderChoice.describe(error)
        }
    }

    private func adopt(_ url: URL) {
        isPreparing = true
        problem = nil
        Task {
            do {
                try await self.finish(adopting: url)
            } catch {
                self.problem = SyncFolderChoice.describe(error)
            }
            self.isPreparing = false
        }
    }

    /// Adopt a folder, however it was arrived at.
    ///
    /// The picked and the defaulted paths share this so that there is exactly
    /// one place `hasCompletedFirstRun` is set and one place the speech assets
    /// are queued.
    private func finish(adopting url: URL) async throws {
        let folder = try await SyncFolderChoice.adopt(
            url,
            folderAccess: self.environment.folderAccess,
            settings: self.environment.settings
        )
        // Queued, not awaited to completion: the download runs in the
        // background and Settings reports it (docs/03-architecture.md § 4).
        await self.environment.transcriber.prepareAssets()
        self.onFinish(folder)
    }
}

#Preview("First run") {
    FirstRunView(environment: PreviewEnvironment())
}
