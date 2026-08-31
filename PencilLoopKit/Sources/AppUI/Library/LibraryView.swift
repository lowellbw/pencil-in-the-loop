//
//  LibraryView.swift
//  AppUI · Library
//
//  S1. The sidebar of the app's one `NavigationSplitView` (docs/02-spec.md §
//  S1, docs/01-design-principles.md § 3).
//

import SwiftUI
import Core
import Sync

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

    /// Which columns are showing.
    ///
    /// Bound rather than left automatic so that opening a document can close
    /// the library behind it: docs/01-design-principles.md § 4 asks for a page
    /// that goes edge to edge, with no persistent sidebar over it. On an iPad
    /// in landscape the automatic behaviour keeps both columns, which leaves
    /// the reader in about two thirds of the screen with a list of other
    /// documents beside it — the opposite of content-first.
    ///
    /// The sidebar is never more than a swipe or the toolbar button away, and
    /// it comes back when the selection clears, so returning to an empty detail
    /// shows the library rather than an empty column.
    ///
    /// `.all` rather than `.automatic`, and the difference is not cosmetic:
    /// binding this property at all changes what `.automatic` means, and it
    /// collapses the sidebar on launch — leaving a first run staring at "No
    /// Document Selected" with the library hidden behind a button.
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var isListening = false
    @State private var narration: NarrationController?
    @State private var isShowingSettings = false

    /// True while a new note is being made, which is long enough to press the
    /// button twice. Two taps used to mean two notebooks.
    @State private var isCreatingNote = false

    /// The group being named or renamed, or nil. One piece of state rather than
    /// a bool and a payload, which cannot then disagree.
    @State private var naming: GroupNameSheet.Mode?

    /// True while the group-order sheet is up.
    @State private var isReorderingGroups = false

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
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebar
        } detail: {
            if let summary = model.summary(id: selection) {
                detail(summary)
                    // The system puts its own sidebar toggle in the detail
                    // column's toolbar, so with `libraryButton` beside it there
                    // were two chevrons in the top left doing almost-but-not-
                    // quite the same thing. Ours is the one that stays: it
                    // clears the selection as well as showing the column, which
                    // is what closing a document actually means here.
                    .toolbar(removing: .sidebarToggle)
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            libraryButton
                        }
                    }
            } else {
                Text("No Document Selected")
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
        }
        .sheet(isPresented: $isListening) {
            if let narration = self.narration {
                NarrationSheet(narration: narration)
            }
        }
        .onChange(of: selection) { _, chosen in
            // Opening a document gives it the whole screen; closing one brings
            // the library back rather than leaving an empty column beside an
            // empty detail.
            columnVisibility = chosen == nil ? .all : .detailOnly
        }
    }

    /// The way back, as a button rather than a swipe.
    ///
    /// Opening a document collapses the sidebar to give the page the whole
    /// screen, and the way back was then the system's edge swipe. Under a
    /// Pencil that swipe draws a line across the page — `drawingPolicy` is
    /// `.pencilOnly`, so a Pencil dragged anywhere over the paper is ink, and
    /// the sidebar never appears. One tap, on a target a Pencil can hit, is the
    /// difference between navigating with the pen and having to put it down
    /// (docs/01-design-principles.md § 5).
    ///
    /// Clearing the selection rather than only setting `columnVisibility`: the
    /// two are already tied together by `onChange` below, and the selection is
    /// the thing that is actually changing — the document is being closed.
    ///
    /// It lives here, in the library's own toolbar, because the selection is
    /// the library's. The reader knows nothing about it and needs to know
    /// nothing about it; its `onBack` stays for containers that have no
    /// sidebar at all.
    private var libraryButton: some View {
        Button {
            selection = nil
        } label: {
            Label("Library", systemImage: "sidebar.left")
        }
        .accessibilityLabel("Library")
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
            pinnedSection
            if model.grouping == .status {
                ForEach(DocState.librarySections, id: \.self) { state in
                    sectionView(for: state)
                }
            } else {
                ForEach(model.sections) { section in
                    groupSectionView(for: section)
                }
            }
            archivedSection
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
        .sheet(item: $naming) { mode in
            GroupNameSheet(mode: mode, model: model)
        }
        .sheet(isPresented: $isReorderingGroups) {
            GroupOrderSheet(model: model)
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                newNoteButton
            }
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
        .sheet(isPresented: $isShowingSettings) {
            SettingsView(environment: environment)
        }
    }

    /// The documents kept at the top, above every state section
    /// (docs/02-spec.md § S1).
    ///
    /// Absent rather than empty when nothing is pinned: an empty "Pinned"
    /// heading is a permanent piece of furniture explaining a feature the user
    /// is not using, which docs/01-design-principles.md § 6 rules out. The
    /// state sections already work this way.
    @ViewBuilder private var pinnedSection: some View {
        let summaries = model.pinned
        if summaries.isEmpty == false {
            Section("Pinned") {
                ForEach(summaries) { summary in
                    row(for: summary, isFilingTarget: false)
                }
                .onMove { source, destination in
                    Task { await self.model.movePinned(fromOffsets: source, toOffset: destination) }
                }
            }
        }
    }

    @ViewBuilder private func sectionView(for state: DocState) -> some View {
        let summaries = model.rows(in: state)
        if summaries.isEmpty == false {
            Section(state.displayName) {
                ForEach(summaries) { summary in
                    row(for: summary, isFilingTarget: true)
                }
            }
        }
    }

    /// What has been put out of the way, when the reader has asked to see it.
    ///
    /// Last, and in one section in both modes. Archiving is how a document
    /// stops being in the way, so putting those rows back among the groups they
    /// came from would undo the gesture that moved them.
    ///
    /// No group tint and no filing: a document in here is not anywhere, and the
    /// only thing worth offering is the way out.
    @ViewBuilder private var archivedSection: some View {
        let summaries = model.archived
        if model.showsArchived && summaries.isEmpty == false {
            Section("Archived") {
                ForEach(summaries) { summary in
                    LibraryRow(summary: summary)
                        .tag(summary.id)
                        .selectionDisabled(summary.isLocal == false)
                        .swipeActions(edge: .trailing) {
                            Button {
                                Task { await self.model.unarchive(summary) }
                            } label: {
                                Label("Restore", systemImage: "arrow.uturn.backward")
                            }
                            .tint(.blue)
                        }
                }
            }
        }
    }

    /// One group's rows, or the Ungrouped residue.
    ///
    /// Absent rather than empty, like every other section here: a group whose
    /// rows the search filtered out is not a heading worth keeping on screen.
    ///
    /// The header carries the rename, which is where Files and Photos put it. An
    /// Ungrouped header carries nothing, because there is no group there to
    /// rename.
    @ViewBuilder private func groupSectionView(for section: LibraryModel.GroupSection) -> some View {
        if section.rows.isEmpty == false {
            Section {
                ForEach(section.rows) { summary in
                    row(for: summary, isFilingTarget: true, tint: section.name.map(GroupPalette.colour(for:)))
                }
            } header: {
                groupHeader(for: section)
            }
        }
    }

    /// A group's heading: the drop target that files a document into it, and
    /// where renaming and reordering live.
    ///
    /// The heading is the drop target rather than the section, because a
    /// `Section` is not a view and has nothing to attach a destination to. The
    /// **Ungrouped** heading is a target too — dropping there takes a document
    /// out of its group, which is the only way to say that by dragging.
    @ViewBuilder private func groupHeader(for section: LibraryModel.GroupSection) -> some View {
        Label {
            Text(section.displayName)
        } icon: {
            // A dot rather than colouring the heading itself. Section headings
            // are small caps in secondary grey and read as furniture; a
            // coloured one reads as a warning. This is the shape Reminders and
            // Calendar use for the same job, and Ungrouped has no dot because
            // it is not a group.
            if let name = section.name {
                Image(systemName: "circle.fill")
                    .foregroundStyle(GroupPalette.colour(for: name))
                    .font(.caption2)
            }
        }
            .dropDestination(for: String.self) { folderNames, _ in
                guard let folderName = folderNames.first, folderName.isEmpty == false else {
                    return false
                }
                Task { await self.model.setGroupName(section.name, forFolderName: folderName) }
                return true
            }
            .contextMenu {
                if let name = section.name {
                    Button {
                        naming = .rename(current: name)
                    } label: {
                        Label("Rename Group…", systemImage: "pencil")
                    }
                }
                Button {
                    isReorderingGroups = true
                } label: {
                    Label("Reorder Groups…", systemImage: "arrow.up.arrow.down")
                }
            }
            .accessibilityHint(
                section.name == nil
                    ? "Drop a document here to take it out of its group"
                    : "Drop a document here to file it in this group. Touch and hold to rename or reorder."
            )
    }

    /// One row, wherever it is drawn.
    ///
    /// The Pinned section and the state sections are the same rows in a
    /// different place, so they get the same gestures: pinning is on the
    /// leading edge and archiving on the trailing, in both. A pinned row that
    /// could not be un-pinned by the gesture that pinned it would be a
    /// one-way door.
    private func row(for summary: DocumentSummary, isFilingTarget: Bool, tint: Color? = nil) -> some View {
        LibraryRow(summary: summary)
            .tag(summary.id)
            .selectionDisabled(summary.isLocal == false)
            .listRowBackground(background(for: summary, tint: tint))
            // Draggable only outside Pinned. In Pinned the drag reorders the
            // section, and one row cannot mean both at once; a pinned row is
            // filed from its context menu instead.
            .modifier(FilingDragModifier(folderName: summary.folderName, isEnabled: isFilingTarget))
            .swipeActions(edge: .leading) {
                Button {
                    Task { await self.model.setPinned(summary.isPinned == false, summary) }
                } label: {
                    // "Unpin" rather than "Pinned": a swipe action is a verb,
                    // and it says what the tap will do, not what is true now.
                    summary.isPinned
                        ? Label("Unpin", systemImage: "pin.slash")
                        : Label("Pin", systemImage: "pin")
                }
                .tint(LibraryView.pinnedColour)
            }
            .swipeActions(edge: .trailing) {
                Button {
                    Task { await self.model.archive(summary) }
                } label: {
                    Label("Archive", systemImage: "archivebox")
                }
            }
            .contextMenu {
                groupMenu(for: summary)
                listenMenu(for: summary)
            }
    }

    /// Listen to a row without opening it.
    ///
    /// Starting a paper playing and then reading something else is the obvious
    /// way to use this, and going through the reader to reach it made listening
    /// feel like a property of the open document rather than of the document.
    /// So the sidebar gets the same sheet, pointed at the row that was pressed.
    @ViewBuilder private func listenMenu(for summary: DocumentSummary) -> some View {
        Button {
            Task {
                let controller = self.listenController(for: summary)
                if controller.hasNarration {
                    await controller.play()
                }
                self.isListening = true
            }
        } label: {
            Label(
                NarrationFetcher.hasNarration(forFolderName: summary.folderName)
                    ? "Listen"
                    : "Listen…",
                systemImage: NarrationFetcher.hasNarration(forFolderName: summary.folderName)
                    ? "headphones.circle.fill"
                    : "headphones"
            )
        }
        .disabled(summary.isLocal == false)
    }

    /// Makes the controller on first use and points it at the pressed row.
    ///
    /// One controller for the whole sidebar rather than one per row:
    /// `target(folderName:title:)` re-points it and clears what it knew, and
    /// only one sheet is ever open, so a second is state nobody reads.
    private func listenController(for summary: DocumentSummary) -> NarrationController {
        let controller = self.narration ?? NarrationController(environment: self.environment)
        controller.target(folderName: summary.folderName, title: summary.title)
        self.narration = controller
        return controller
    }

    /// The wash behind a row: green for pinned, its group's colour inside a
    /// group section, and nothing anywhere else.
    ///
    /// **The two can never collide**, which is what makes one function safe: a
    /// pinned row is drawn in Pinned and nowhere else, so a row is either the
    /// pinned one or in a group, never both.
    ///
    /// Green is the motif for pinning and is the same green the pin swipe is
    /// tinted with, so the gesture and its result say the same thing. Change
    /// one and change the other.
    ///
    /// Deliberately never the accent colour: a `List` draws selection in the
    /// accent, and a row painted that way would be indistinguishable from the
    /// document you have open. Nil while the row is selected for the same
    /// reason — the selection is the more urgent of the two facts, and two
    /// washes over each other are a third colour that means nothing.
    private func background(for summary: DocumentSummary, tint: Color?) -> Color? {
        guard selection != summary.id else { return nil }
        if summary.isPinned {
            return LibraryView.pinnedColour.opacity(LibraryView.pinnedTintOpacity)
        }
        guard let tint else { return nil }
        return tint.opacity(LibraryView.groupTintOpacity)
    }

    /// The one colour that means "pinned" — the row wash and the swipe.
    ///
    /// Computed rather than stored because `LibraryView` is generic over its
    /// detail view, and a generic type cannot hold a static stored property.
    private static var pinnedColour: Color { .green }

    /// A wash rather than a fill. Light enough that the row still reads as a row
    /// and label text keeps its contrast in both appearances; enough to pick the
    /// shelf out of the grouped grey at a glance, which is all it has to do.
    private static var pinnedTintOpacity: Double { 0.14 }

    /// Lighter than the pinned wash, and deliberately so. Pinned is a shelf you
    /// put things on and should be the loudest thing in the sidebar; a group is
    /// just where a document lives, and there may be six of them on screen at
    /// once. Enough to see the blocks, not enough to make a list of documents
    /// look like a chart.
    private static var groupTintOpacity: Double { 0.09 }

    /// Makes a row draggable, or leaves it exactly as it was.
    ///
    /// A `ViewModifier` rather than an `if` around `.draggable`, because the two
    /// branches of an `if` in a `ViewBuilder` are different types and the row
    /// would lose its identity when the branch changed — which in a `List` means
    /// losing the selection and any in-flight swipe.
    private struct FilingDragModifier: ViewModifier {

        let folderName: String
        let isEnabled: Bool

        func body(content: Content) -> some View {
            if isEnabled {
                content.draggable(folderName)
            } else {
                content
            }
        }
    }

    /// Filing one document, from a touch-and-hold.
    ///
    /// **Not a third swipe action, because there is no third edge** — pin is on
    /// the leading one and archive on the trailing — and not a new gesture,
    /// which docs/01-design-principles.md § 5 rules out. A context menu is what
    /// Files, Mail and Photos use for exactly this, it is invisible until it is
    /// asked for so it costs the row no chrome (§ 6), and it is the only one of
    /// the three that can hold a list of names.
    ///
    /// The menu offers every group in the library, not only the ones the current
    /// search left on screen — see `LibraryModel.groupNames`.
    @ViewBuilder private func groupMenu(for summary: DocumentSummary) -> some View {
        Menu {
            ForEach(model.groupNames, id: \.self) { name in
                Button {
                    Task { await self.model.setGroupName(name, forFolderName: summary.folderName) }
                } label: {
                    // A checkmark rather than a disabled row: the current group
                    // is worth naming, and tapping it again costs nothing.
                    if summary.groupName == name {
                        Label(name, systemImage: "checkmark")
                    } else {
                        Text(name)
                    }
                }
            }
            if model.groupNames.isEmpty == false {
                Divider()
            }
            Button {
                naming = .create(folderName: summary.folderName)
            } label: {
                Label("New Group…", systemImage: "plus")
            }
            if summary.groupName != nil {
                Button(role: .destructive) {
                    Task { await self.model.setGroupName(nil, forFolderName: summary.folderName) }
                } label: {
                    Label("Remove from Group", systemImage: "minus.circle")
                }
            }
        } label: {
            Label("Group", systemImage: "folder")
        }
    }

    /// Making a note rather than waiting for a document to arrive.
    ///
    /// ─── ONE TAP, AND NOTHING TO ANSWER FIRST ────────────────────────────────
    /// This was a menu with two entries, each opening a sheet: a title field, a
    /// paper picker, a page-count stepper, Cancel and Create. Five decisions
    /// between a person with a Pencil in their hand and a blank page, at the
    /// moment they have a thought they want to write down.
    ///
    /// Every one of them had a good default, and every one of them is easier to
    /// answer *after* there is something on the paper: the note names itself
    /// from its first sentence, the ruling is changed from the page while you
    /// are looking at it, and pages are added when you run out. So the button
    /// makes the notebook and opens it, and there is nothing to cancel.
    /// ─────────────────────────────────────────────────────────────────────────
    private var newNoteButton: some View {
        Button {
            self.createNote()
        } label: {
            Label("New Note", systemImage: "square.and.pencil")
        }
        .disabled(isCreatingNote)
        .accessibilityLabel("New Note")
    }

    /// Makes a notebook and opens it on page one.
    ///
    /// The selection is what opens it, and the row has to be in the list before
    /// it can be selected — `LibraryModel.createNotebook` reloads before it
    /// returns, which is the same two steps `selecting` takes and for the same
    /// reason.
    private func createNote() {
        guard isCreatingNote == false else { return }
        isCreatingNote = true
        Task {
            let created = await self.model.createNotebook()
            self.isCreatingNote = false
            // On failure the reason is already in the status line under the
            // list, and nothing has been created.
            guard let created else { return }
            self.selection = created
        }
    }

    /// Sort and Group By, in one menu.
    ///
    /// Two labelled pickers in the menu the toolbar already has, rather than a
    /// fourth toolbar item — the column is narrow and a fourth control crowds
    /// the title out (`newMenu` says the same thing about the third). It is also
    /// the shape Files and Photos use, which is the test
    /// docs/01-design-principles.md § 3 sets.
    private var sortMenu: some View {
        Menu {
            Picker("Sort By", selection: $model.sort) {
                Text("Date Added").tag(LibrarySort.dateAdded)
                Text("Title").tag(LibrarySort.title)
            }
            Divider()
            Picker("Group By", selection: $model.grouping) {
                Text("Status").tag(LibraryGrouping.status)
                Text("Group").tag(LibraryGrouping.group)
            }
            // Only in Group mode, and only with something to order. A control
            // that visibly cannot apply is worse than one that is absent
            // (docs/01-design-principles.md § 6).
            if model.grouping == .group && model.groupNames.count > 1 {
                Divider()
                Button {
                    isReorderingGroups = true
                } label: {
                    Label("Reorder Groups…", systemImage: "arrow.up.arrow.down")
                }
            }
            Divider()
            Toggle(isOn: $model.showsArchived) {
                Label("Show Archived", systemImage: "archivebox")
            }
        } label: {
            Label("Sort", systemImage: "arrow.up.arrow.down")
        }
        .accessibilityLabel("Sort and Group")
    }

    /// "No documents" in secondary label colour, a way to start writing, and
    /// the folder picker. Nothing else — no illustration, no headline
    /// (docs/01-design-principles.md § 6).
    @ViewBuilder private var emptyState: some View {
        if model.isLoaded && model.rows.isEmpty {
            VStack(spacing: 16) {
                if model.searchText.isEmpty {
                    Text("No documents")
                        .font(.body)
                        .foregroundStyle(.secondary)
                    // The only useful thing to do with an empty library and no
                    // network, and the same one tap as the toolbar's.
                    Button("New Note") {
                        self.createNote()
                    }
                    .font(.body)
                    .disabled(isCreatingNote)
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

}

#Preview("Library") {
    LibraryView(
        environment: PreviewEnvironment(summaries: DocumentSummary.previewSamples)
    ) { summary in
        Text(summary.title)
            .font(.body)
    }
}

#Preview("Grouped") {
    LibraryView(
        environment: PreviewEnvironment(
            summaries: DocumentSummary.previewSamples,
            settings: .previewGrouped
        )
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
