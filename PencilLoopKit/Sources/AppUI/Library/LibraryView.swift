//
//  LibraryView.swift
//  AppUI · Library
//
//  S1. The sidebar of the app's one `NavigationSplitView` (docs/02-spec.md §
//  S1, docs/01-design-principles.md § 3).
//

import SwiftUI
import UniformTypeIdentifiers
import Core

/// The library sidebar and the split view that holds it.
///
/// The detail column is supplied by the caller: the reader is another unit's
/// screen, and the library has no business knowing its type. `RootView` passes
/// the reader; a preview passes a placeholder.
///
/// **Offline:** everything here works with no network. Rows that are not yet
/// local are dimmed and disabled rather than failing on tap, rows that failed
/// to ingest show their reason, and pull-to-refresh reports a folder it cannot
/// reach in the status line instead of blocking the list
/// (docs/02-spec.md § S1).
public struct LibraryView<Detail: View>: View {

    private let environment: any AppEnvironment
    private let selecting: UUID?
    private let reload: LibraryReloadSignal
    private let detail: (DocumentSummary) -> Detail

    @State private var model: LibraryModel
    @State private var selection: UUID?
    @State private var isChoosingFolder = false
    @State private var isShowingSettings = false

    /// - Parameters:
    ///   - environment: the one route to every dependency, the folder picker's
    ///     `folderAccess` included.
    ///   - selecting: a document to select when it changes — an agent's reply
    ///     that has just been opened as a document (docs/04-flows.md § F6). The
    ///     selection is otherwise the sidebar's own; this only nudges it.
    ///   - reload: bumped by whatever has changed a row while the sidebar was
    ///     on screen beside it — an annotation promoting a document to
    ///     "Reviewing", a review being sent (`LibraryReloadSignal`). A caller
    ///     with nothing to report can leave it out.
    ///   - detail: the reader, built for whichever row is selected.
    public init(
        environment: any AppEnvironment,
        selecting: UUID? = nil,
        reload: LibraryReloadSignal = LibraryReloadSignal(),
        @ViewBuilder detail: @escaping (DocumentSummary) -> Detail
    ) {
        self.environment = environment
        self.selecting = selecting
        self.reload = reload
        self.detail = detail
        _model = State(initialValue: LibraryModel(environment: environment))
    }

    public var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            if let summary = model.summary(id: selection) {
                detail(summary)
            } else {
                Text("No Document Selected")
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Sidebar

    /// The one line of status the sidebar is allowed to show — why documents
    /// have stopped arriving, or what the last pull found.
    ///
    /// **Not a `ToolbarItem(placement: .bottomBar)`, which is where this lived
    /// and where it did not work.** A toolbar item in the sidebar column of a
    /// `NavigationSplitView` is laid out in whatever width the toolbar gives
    /// it, which on an iPad sidebar is a couple of hundred points; the sentence
    /// wrapped, then truncated, and read "The sync…". A status line that cannot
    /// be read is the silence docs/02-spec.md § F7 exists to prevent, and it
    /// fails exactly when it matters, because the longest messages are the ones
    /// explaining a real problem.
    ///
    /// A bottom safe-area inset instead: full column width, as many lines as
    /// the sentence needs, and `fixedSize` so it grows downward rather than
    /// being compressed back into one truncated line.
    @ViewBuilder
    private var statusLine: some View {
        if let status = model.statusMessage {
            Text(status)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.bar)
                .accessibilityLabel(status)
        }
    }

    private var sidebar: some View {
        List(selection: $selection) {
            ForEach(DocState.librarySections, id: \.self) { state in
                sectionView(for: state)
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Library")
        .searchable(text: $model.searchText, prompt: "Search documents and notes")
        .refreshable {
            await model.refresh()
        }
        .overlay {
            emptyState
        }
        .safeAreaInset(edge: .bottom) {
            statusLine
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                sortMenu
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    isShowingSettings = true
                } label: {
                    Label("Settings", systemImage: "gearshape")
                }
                .accessibilityLabel("Settings")
            }
        }
        .task(id: model.reloadKey) {
            // Typing changes the key on every keystroke and `.task(id:)`
            // cancels the previous run, so this is a debounce rather than a
            // delay: only the last query in a burst reaches the store.
            if model.searchText.isEmpty == false {
                try? await Task.sleep(for: .milliseconds(200))
            }
            if Task.isCancelled == false {
                await model.load()
            }
        }
        .task {
            await model.observeSync()
        }
        .onChange(of: reload.revision) { _, _ in
            // Something beside the sidebar changed a row: a document annotated
            // in the reader, or a review sent. `.onChange` rather than
            // `.task(id:)` so that appearing does not run a second load on top
            // of the one `reloadKey` already runs (`LibraryReloadSignal`).
            Task { await self.model.load() }
        }
        .onChange(of: selecting) { _, requested in
            guard let requested else { return }
            Task {
                // The row may not be in the list yet — a reply is ingested and
                // announced in the same breath — so load before selecting.
                await self.model.load()
                self.selection = requested
            }
        }
        .fileImporter(isPresented: $isChoosingFolder, allowedContentTypes: [.folder]) { result in
            self.adopt(result)
        }
        .sheet(isPresented: $isShowingSettings) {
            SettingsView(environment: environment)
        }
    }

    @ViewBuilder private func sectionView(for state: DocState) -> some View {
        let summaries = model.rows(in: state)
        if summaries.isEmpty == false {
            Section(state.displayName) {
                ForEach(summaries) { summary in
                    LibraryRow(summary: summary)
                        .tag(summary.id)
                        .selectionDisabled(summary.isLocal == false)
                        .swipeActions(edge: .trailing) {
                            Button {
                                Task { await self.model.archive(summary) }
                            } label: {
                                Label("Archive", systemImage: "archivebox")
                            }
                        }
                }
            }
        }
    }

    private var sortMenu: some View {
        Menu {
            Picker("Sort By", selection: $model.sort) {
                Text("Date Added").tag(LibrarySort.dateAdded)
                Text("Title").tag(LibrarySort.title)
            }
        } label: {
            Label("Sort", systemImage: "arrow.up.arrow.down")
        }
        .accessibilityLabel("Sort")
    }

    /// "No documents" in secondary label colour and the folder picker. Nothing
    /// else — no illustration, no headline (docs/01-design-principles.md § 6).
    @ViewBuilder private var emptyState: some View {
        if model.isLoaded && model.rows.isEmpty {
            VStack(spacing: 16) {
                if model.searchText.isEmpty {
                    Text("No documents")
                        .font(.body)
                        .foregroundStyle(.secondary)
                    Button("Choose Folder…") {
                        isChoosingFolder = true
                    }
                    .font(.body)
                } else {
                    Text("No Results")
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
            }
            .multilineTextAlignment(.center)
            .padding()
        }
    }

    private func adopt(_ result: Result<URL, any Error>) {
        switch result {
        case let .success(url):
            Task {
                do {
                    let folder = try await SyncFolderChoice.adopt(
                        url,
                        folderAccess: self.environment.folderAccess,
                        settings: self.environment.settings
                    )
                    // Persisting the bookmark is half of it; this is what makes
                    // documents start arriving (AppEnvironment.adoptFolder).
                    await self.environment.adoptFolder(folder)
                    await self.model.refresh()
                } catch {
                    self.model.report(SyncFolderChoice.describe(error))
                }
            }
        case let .failure(error):
            model.report(SyncFolderChoice.describe(error))
        }
    }
}

#Preview("Library") {
    LibraryView(
        environment: PreviewEnvironment(summaries: DocumentSummary.previewSamples)
    ) { summary in
        Text(summary.title)
            .font(.body)
    }
}

#Preview("Empty") {
    LibraryView(environment: PreviewEnvironment()) { summary in
        Text(summary.title)
            .font(.body)
    }
}
