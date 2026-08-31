//
//  FirstRunView.swift
//  AppUI · FirstRun
//
//  S0. One screen, one job — and in the ordinary case nobody sees it
//  (docs/02-spec.md § S0).
//

import SwiftUI
import Core
import Sync

/// Settle the relay. That is the whole screen.
///
/// **It tries the shipped relay first.** A build that ships pointed at one
/// (`Config/Local.xcconfig` → `RelayDefaults`) adopts it without asking: no
/// address, no token, no account, no decision, no carousel, no logo
/// (docs/01-design-principles.md § 6). For most installs first run is a status
/// line that is gone before it is read.
///
/// **The form is the fallback, not the flow.** Two builds reach it: one made
/// from a checkout with no `Config/Local.xcconfig`, which knows the address but
/// not the token and so asks only for that; and one with neither, which asks
/// for both. Settings offers the same form afterwards (S6).
///
/// This screen used to settle a *folder*, with the relay as the quiet second
/// option. The folder transport is gone and the two have swapped places — there
/// is now one way to be set up, which is the point.
///
/// **On failure:** the reason appears in secondary text and the form stays.
/// There is no dead end here — the only way out of this screen is a relay, so
/// it must always be possible to try again.
public struct FirstRunView: View {

    private let environment: any AppEnvironment

    /// Called once a relay is connected. Takes no argument: `adoptServer` has
    /// already attached the coordinator by the time this fires.
    private let onAdoptedServer: () -> Void

    @State private var isPreparing = false
    @State private var problem: String?

    /// Nil until the shipped relay has been tried. Until then the screen shows
    /// the status line alone: offering a form for half a second and then taking
    /// it away would be worse than showing nothing.
    @State private var hasTriedDefault = false
    @State private var isChoosingServer = false
    @State private var serverURLText = ""
    @State private var serverToken = ""

    /// - Parameters:
    ///   - environment: settings are written through it, the relay is adopted
    ///     through it, and the one-time speech asset download is started
    ///     through its transcriber (docs/03-architecture.md § 4).
    ///   - onAdoptedServer: called once the relay is attached, so the shell can
    ///     show the library without re-reading settings.
    public init(
        environment: any AppEnvironment,
        onAdoptedServer: @escaping () -> Void = {}
    ) {
        self.environment = environment
        self.onAdoptedServer = onAdoptedServer
    }

    public var body: some View {
        VStack(spacing: 24) {
            Text(explanation)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)

            // Only once the shipped relay has been tried and did not work.
            // Before that there is nothing to enter and nothing worth tapping.
            if hasTriedDefault {
                Button("Connect a Relay…") {
                    isChoosingServer = true
                }
                .font(.body)
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
        .task {
            await self.adoptShippedRelay()
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

    /// Connect a relay the user typed in.
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

    /// What the screen says, which depends only on how far the build got.
    private var explanation: String {
        if RelayDefaults.isPartiallyConfigured {
            return "This build knows your relay's address but not its access token. Enter the token to connect."
        }
        if hasTriedDefault {
            return "Connect the relay your documents are sent to. Its address and access token are in the relay's setup output."
        }
        return "Connecting to your library."
    }

    /// Adopt the relay this build ships with, if it ships with one.
    ///
    /// This is the whole of first run for anyone using a configured build: no
    /// address, no token, no screen they have to understand before they can
    /// read anything.
    private func adoptShippedRelay() async {
        guard hasTriedDefault == false, isPreparing == false else { return }
        isPreparing = true

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
                // Stated rather than apologised for, with the form underneath.
                // There is no other transport to fall back to now.
                problem = SyncServerChoice.describe(error)
            }
        }

        // The address without the token — a checkout built without
        // `Config/Local.xcconfig`. Ask for the token with the address already
        // filled in, rather than an empty form.
        if RelayDefaults.isPartiallyConfigured, let baseURL = RelayDefaults.baseURL {
            serverURLText = baseURL.absoluteString
            hasTriedDefault = true
            isPreparing = false
            isChoosingServer = true
            return
        }

        hasTriedDefault = true
        isPreparing = false
    }
}

#Preview("First run") {
    FirstRunView(environment: PreviewEnvironment())
}
