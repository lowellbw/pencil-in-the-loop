//
//  FirstRunView.swift
//  AppUI · FirstRun
//
//  S0. One screen, one job (docs/02-spec.md § S0).
//

import SwiftUI
import UniformTypeIdentifiers
import Core

/// Pick the sync folder. That is the whole screen.
///
/// A short line of explanation and a button that opens `fileImporter`. No
/// account, no login, no carousel, no logo (docs/01-design-principles.md § 6).
/// The bookmark is stored and `inbox/`/`outbox/` are created by
/// `SyncFolderChoice.adopt(_:folderAccess:settings:)`; once
/// `AppSettings.hasCompletedFirstRun` is set, the shell shows the library
/// instead and this screen is never seen again.
///
/// **On failure:** the picker's error, or the folder's, appears under the
/// button in secondary text and the button stays. There is no dead end here —
/// the only way out of this screen is choosing a folder, so it must always be
/// possible to try again.
public struct FirstRunView: View {

    private let environment: any AppEnvironment
    private let onFinish: (SyncFolder) -> Void

    @State private var isChoosingFolder = false
    @State private var isPreparing = false
    @State private var problem: String?

    /// - Parameters:
    ///   - environment: settings are written through it, the folder is prepared
    ///     through its `folderAccess`, and the one-time speech asset download
    ///     is started through its transcriber (docs/03-architecture.md § 4).
    ///   - onFinish: called with the prepared folder, so the shell can start
    ///     syncing it without re-reading settings.
    public init(
        environment: any AppEnvironment,
        onFinish: @escaping (SyncFolder) -> Void = { _ in }
    ) {
        self.environment = environment
        self.onFinish = onFinish
    }

    public var body: some View {
        VStack(spacing: 24) {
            Text("Choose a folder this iPad shares with your computer. Documents put there appear in your library, and the reviews you send go back the same way.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)

            Button("Choose Folder…") {
                isChoosingFolder = true
            }
            .font(.body)
            .disabled(isPreparing)

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
                let folder = try await SyncFolderChoice.adopt(
                    url,
                    folderAccess: self.environment.folderAccess,
                    settings: self.environment.settings
                )
                // Queued, not awaited to completion: the download runs in the
                // background and Settings reports it (docs/03-architecture.md § 4).
                await self.environment.transcriber.prepareAssets()
                self.onFinish(folder)
            } catch {
                self.problem = SyncFolderChoice.describe(error)
            }
            self.isPreparing = false
        }
    }
}

#Preview("First run") {
    FirstRunView(environment: PreviewEnvironment())
}
