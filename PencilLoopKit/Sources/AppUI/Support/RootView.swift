//
//  RootView.swift
//  AppUI · Support
//
//  The whole app, arranged: first run when there is no folder, the library and
//  the reader when there is, and the review sheet over the top of it.
//
//  This is the only file that knows all five screens exist. Each of them takes
//  its environment through `init` and knows nothing about the others; what
//  belongs here is the wiring between them — which document the reader opens,
//  which document the review sheet is about, and where an agent's reply lands
//  when it is opened as a document.
//

import SwiftUI
import Core

/// The app's root.
///
/// **On failure:** a library store that will not open shows one sentence and
/// nothing else — there is no library to fall back to. Every other failure is
/// handled by the screen it happens on: a folder that has gone away is a line
/// in the library's status area, a document that will not parse is a sentence
/// in the reader, and a review that cannot be written keeps the sheet open with
/// everything the user typed still in it.
public struct RootView: View {

    @State private var model: RootModel
    @State private var reviewing: DocumentDetail?

    /// Held here rather than in the library so that the reader and the review
    /// sheet — neither of which knows the sidebar exists — can say the rows have
    /// moved (`LibraryReloadSignal`).
    @State private var libraryReload = LibraryReloadSignal()

    @Environment(\.scenePhase) private var scenePhase

    /// - Parameter model: the shell's state. Made by `PencilLoopApp` so it
    ///   survives every view update the scene makes.
    public init(model: RootModel = RootModel()) {
        _model = State(initialValue: model)
    }

    public var body: some View {
        content
            .task {
                await model.start()
            }
            .onChange(of: scenePhase) { _, phase in
                Task {
                    switch phase {
                    case .active:
                        await self.model.noteActive()
                    case .background:
                        await self.model.noteInactive()
                    default:
                        break
                    }
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .starting:
            // No spinner and no logo: this state lasts one settings read, and
            // nothing here is waiting on a network
            // (docs/01-design-principles.md § 6).
            Color(uiColor: .systemGroupedBackground)
                .ignoresSafeArea()

        case .firstRun:
            if let environment = model.environment {
                FirstRunView(
                    environment: environment,
                    onFinish: { folder in
                        Task { await self.model.adopt(folder) }
                    },
                    onAdoptedServer: {
                        self.model.showLibrary()
                    }
                )
            }

        case .library:
            if let environment = model.environment {
                library(environment)
            }

        case let .unusable(message):
            ReaderUnavailableView(message: message)
        }
    }

    /// The split view, the reader in its detail column, and the review sheet.
    private func library(_ environment: any AppEnvironment) -> some View {
        LibraryView(
            environment: environment,
            selecting: model.pendingSelection,
            reload: libraryReload
        ) { summary in
            ReaderView(
                environment: environment,
                documentId: summary.id,
                title: summary.title,
                // The store promotes a document to "Reviewing" inside the write
                // that annotates it, and says so to nobody. The sidebar is on
                // screen beside the reader, so it has to be told to look again
                // (docs/04-flows.md § F2, `LibraryReloadSignal`).
                onDocumentChanged: { self.libraryReload.note() },
                onReview: { documentId in
                    self.presentReview(for: documentId, environment: environment)
                }
            )
        }
        // A sent review moves the document to "Read", or a queued one holds it
        // in "Reviewing"; either way the row the sheet was opened from is stale
        // by the time it closes (ReviewSheetModel § recordDelivery).
        .sheet(item: $reviewing, onDismiss: { self.libraryReload.note() }) { detail in
            ReviewSheet(environment: environment, document: detail) { newDocumentId in
                // An agent's reply, opened as a document. It is in the library
                // already — Sync ingested it — so selecting it is all that is
                // left (docs/04-flows.md § F6).
                self.model.pendingSelection = newDocumentId
            }
        }
    }

    /// Fetches the document the review sheet is about.
    ///
    /// One store round trip, on a button press, deliberately: the reader's copy
    /// of the comments is as old as the last time it loaded, and the sheet is
    /// the screen where their exact text is about to be sent somewhere.
    private func presentReview(for documentId: UUID, environment: any AppEnvironment) {
        Task {
            guard let detail = try? await environment.store.detail(id: documentId) else { return }
            self.reviewing = detail
        }
    }
}

#Preview("Root · library") {
    RootView(
        model: RootModel(
            previewing: PreviewEnvironment(summaries: DocumentSummary.previewSamples)
        )
    )
}

#Preview("Root · first run") {
    RootView(model: RootModel(previewing: PreviewEnvironment(), phase: .firstRun))
}
