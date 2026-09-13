//
//  LibraryModel.swift
//  AppUI · Library
//
//  What the sidebar knows. Every read goes through `DocumentStoring`, every
//  re-scan through `SyncCoordinating`, and nothing here touches the filesystem
//  itself.
//

import Foundation
import Observation
import Core
import Ingest

/// The library's state: the rows, the query that produced them, and the one
/// line of status the sidebar is allowed to show.
///
/// **Offline is the normal case, not an error path.** Nothing here awaits the
/// network, a failed re-scan leaves the existing rows exactly where they were,
/// and a document that could not be ingested arrives as a row whose
/// `localState` is `.unavailable` rather than as an absence
/// (docs/04-flows.md § F1).
@Observable
public final class LibraryModel {

    /// Every readable document, newest first by default, in one flat list.
    /// `rows(in:)` splits it into the three sections.
    public private(set) var rows: [DocumentSummary] = []

    /// Matches title, extracted document text and recognised handwriting — the
    /// store does the matching, this is only what the user typed
    /// (docs/02-spec.md § S1).
    public var searchText: String = ""

    /// Date added or title. A title list is read A–Z, which is `ascending`
    /// true; a date list is read newest-first, which is `ascending` false
    /// (DTOs.swift § LibraryQuery).
    public var sort: LibrarySort = .dateAdded

    /// Status sections, or one section per group (docs/02-spec.md § S1).
    ///
    /// **Not part of `query`, and deliberately absent from `reloadKey`.** Both
    /// sectionings are built in the same pass over the same fetched rows, so
    /// switching this is a re-render and costs no round trip to the store.
    ///
    /// Remembered, so the reader chooses once rather than every launch. The
    /// write is coalesced in the store and skipped entirely when `load()` is
    /// merely restoring what was already saved.
    /// Whether archived documents are shown, in a section of their own at the
    /// bottom (docs/02-spec.md § S1).
    ///
    /// Off by default and not remembered: archiving something is how you get it
    /// out of the way, so a library that stayed opened on the archive would
    /// undo the gesture. This is a look, not a mode.
    public var showsArchived = false

    public var grouping: LibraryGrouping = .group {
        didSet {
            guard grouping != oldValue else { return }
            let wanted = grouping
            Task { [environment] in try? await environment.groups.setLibraryGrouping(wanted) }
        }
    }

    /// False until the first load finishes, so the empty state does not flash
    /// before the rows arrive.
    public private(set) var isLoaded = false

    /// One line under the list: what the last re-scan found, or why it could
    /// not run. Nil most of the time.
    public private(set) var statusMessage: String?

    /// Which transport is in force, so the empty state can offer the right
    /// thing. Read once per load rather than observed: it changes only in
    /// Settings, and Settings closing reloads the library anyway.
    public private(set) var transport: SyncTransport = .folder

    private var grouped: [DocState: [DocumentSummary]] = [:]
    private var pinnedRows: [DocumentSummary] = []
    private var groupSections: [GroupSection] = []
    private var archivedRows: [DocumentSummary] = []

    /// Every group in use, whether or not the current search left a row in it.
    ///
    /// Read from the settings store rather than derived from `rows`, because
    /// `rows` is filtered by the search text and a Group menu that shrank while
    /// the user typed would hide the group they were looking for.
    private var allGroupNames: [String] = []

    /// `folderName` to group name, as of the last load. The rows the store
    /// returns do not carry this — see `DocumentSummary.groupName`.
    private var groupsByFolderName: [String: String] = [:]

    private let environment: any AppEnvironment

    public init(environment: any AppEnvironment) {
        self.environment = environment
    }

    /// Changes whenever the list has to be fetched again. The view drives its
    /// reload from this rather than from two separate change handlers.
    public var reloadKey: String {
        sort.rawValue + "\u{1F}" + searchText + "\u{1F}" + (showsArchived ? "+archived" : "")
    }

    /// The query the current search and sort describe.
    public var query: LibraryQuery {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return LibraryQuery(
            searchText: trimmed.isEmpty ? nil : trimmed,
            // Empty means every state *except* archived, which is the normal
            // case; naming them all is the only way to ask for it as well.
            states: showsArchived ? Set(DocState.allCases) : [],
            sort: sort,
            ascending: sort == .title
        )
    }

    /// One section of the sidebar in `.group` mode.
    ///
    /// A nested type because it means nothing outside this model: the view asks
    /// for `sections` and draws what it is given.
    public struct GroupSection: Identifiable, Hashable, Sendable {

        /// The group's name, or nil for Ungrouped — which is a place rather
        /// than a group, and is why this is not just a `String`.
        public let name: String?

        public let rows: [DocumentSummary]

        /// A name can never collide with the Ungrouped id: a group name with a
        /// unit separator in it does not survive `DocumentGroups.normalised`.
        public var id: String { name ?? "\u{1F}ungrouped" }

        /// What the section header says.
        public var displayName: String { name ?? "Ungrouped" }
    }

    /// The rows of one section, in the order the store returned them.
    ///
    /// Pinned documents are **not** here. They are drawn once, in the Pinned
    /// section above (`pinned`); a row in two places is a row you can tap twice
    /// and a selection that highlights in two sections at once.
    public func rows(in state: DocState) -> [DocumentSummary] {
        grouped[state] ?? []
    }

    /// The Pinned section, above every state section (docs/02-spec.md § S1).
    ///
    /// In the store's order, which is the order the sort menu asked for — the
    /// section is a different *place*, not a different sort
    /// (`Document.pinnedAt`).
    public var pinned: [DocumentSummary] {
        pinnedRows
    }

    /// The group sections, alphabetically, with Ungrouped last.
    ///
    /// Alphabetically because a name the user chose has no other stable order,
    /// and Ungrouped last because it is the residue rather than a group. Rows
    /// *within* every section still obey the sort menu — grouping is a place,
    /// not a sort, which is the rule the Pinned section already follows
    /// (docs/02-spec.md § S1).
    ///
    /// A group whose every row was filtered out by the search does not appear,
    /// for the same reason an empty state section does not.
    public var sections: [GroupSection] {
        groupSections
    }

    /// Every group in use, for the row's Group menu. Empty until the first load.
    public var groupNames: [String] {
        allGroupNames
    }

    /// The archived documents, when they are being shown, newest first.
    ///
    /// Drawn last and in one section in both modes: archived is a state the
    /// reader put a document into to stop seeing it, so scattering those rows
    /// back through the groups they came from would be the opposite of what the
    /// gesture asked for.
    public var archived: [DocumentSummary] {
        archivedRows
    }

    /// The selected row, if the selection still names one.
    public func summary(id: UUID?) -> DocumentSummary? {
        guard let id else { return nil }
        return rows.first { $0.id == id }
    }

    /// Fetches the rows for the current query.
    ///
    /// Failure is reported in `statusMessage` and leaves the previous rows on
    /// screen: a library that empties itself because one read threw is worse
    /// than a stale one.
    public func load() async {
        transport = await environment.settings.settings.transport
        let settings = await environment.settings.settings
        grouping = settings.libraryGroupingOrDefault
        let filed = settings.groups
        groupsByFolderName = filed.assignments
        allGroupNames = filed.orderedNames
        do {
            let fetched = try await environment.store.summaries(query)
            apply(fetched)
            isLoaded = true
        } catch {
            statusMessage = SyncFailure.describe(error)
            isLoaded = true
        }
    }

    /// Pull-to-refresh: the same scan the 15-second poll runs, on demand.
    ///
    /// It exists because file coordination does not reliably see every change a
    /// provider makes in the background, so this is what the user reaches for
    /// when a document they know was sent has not appeared
    /// (docs/02-spec.md § S1, docs/04-flows.md § F1). It therefore has to say
    /// what it found, or the gesture teaches the user nothing.
    public func refresh() async {
        do {
            let ingested = try await environment.sync.refresh()
            statusMessage = ingested == 0
                ? "No new documents"
                : "\(ingested) new " + (ingested == 1 ? "document" : "documents")
        } catch {
            statusMessage = SyncFailure.describe(error)
        }
        await load()
    }

    /// Takes a document out of the archive.
    ///
    /// Restored to **Read**, not Unread. It has been in the library and been
    /// seen; calling it Unread would claim it had just arrived, and would put
    /// it back at the top of a section it has no business being at the top of.
    public func unarchive(_ summary: DocumentSummary) async {
        do {
            try await environment.store.setState(.read, documentId: summary.id)
            await load()
        } catch {
            statusMessage = SyncFailure.describe(error)
        }
    }

    /// Swipe to archive. `.archived` is hidden from all three sections and its
    /// bytes stay on disk until the user purges them in Settings
    /// (docs/02-spec.md § S6).
    public func archive(_ summary: DocumentSummary) async {
        do {
            try await environment.store.setState(.archived, documentId: summary.id)
            apply(rows.filter { $0.id != summary.id })
        } catch {
            statusMessage = SyncFailure.describe(error)
        }
    }

    /// Swipe to pin, or to un-pin. The row moves between the Pinned section and
    /// its state section; nothing else about it changes (docs/02-spec.md § S1).
    ///
    /// Re-groups from the rows already in hand rather than re-reading the
    /// store: the pin is a local fact and the list is already correct for the
    /// current query, so a round trip would only make the row jump a frame
    /// later than the finger that moved it.
    public func setPinned(_ pinned: Bool, _ summary: DocumentSummary) async {
        do {
            try await environment.store.setPinned(pinned, documentId: summary.id)
            apply(rows.map { row in
                guard row.id == summary.id else { return row }
                var updated = row
                updated.pinnedAt = pinned ? Date() : nil
                return updated
            })
        } catch {
            statusMessage = SyncFailure.describe(error)
        }
    }

    /// Files a document into a group, or takes it out of one with nil
    /// (docs/02-spec.md § S1).
    ///
    /// Re-sections from the rows already in hand rather than re-reading the
    /// store, for the same reason `setPinned` does: the assignment is a local
    /// fact and the list is already correct for the current query, so a round
    /// trip would only make the row jump a frame later than the finger that
    /// moved it.
    ///
    /// The name the store settles on may not be the name that was asked for — a
    /// spelling matching a group already in use joins that group under the
    /// spelling on screen — so the new map is read back rather than assumed.
    public func setGroupName(_ name: String?, forFolderName folderName: String) async {
        do {
            try await environment.groups.setGroupName(name, forFolderName: folderName)
            await reapplyGroups()
        } catch {
            statusMessage = SyncFailure.describe(error)
        }
    }

    /// Renames a group, moving every document filed under it.
    ///
    /// Renaming onto a name already in use merges the two — see
    /// `DocumentGrouping.renameGroup(_:to:)`, which explains why that is the
    /// only coherent answer.
    public func renameGroup(_ name: String, to newName: String) async {
        do {
            try await environment.groups.renameGroup(name, to: newName)
            await reapplyGroups()
        } catch {
            statusMessage = SyncFailure.describe(error)
        }
    }

    /// Drag to reorder the Pinned section.
    ///
    /// Applies the new order locally before writing it, so the row lands under
    /// the finger that dropped it rather than a round trip later — the same
    /// bargain `setPinned` strikes, and the reason the store is told the whole
    /// order rather than one move.
    public func movePinned(fromOffsets source: IndexSet, toOffset destination: Int) async {
        var reordered = pinnedRows
        reordered.move(fromOffsets: source, toOffset: destination)
        let ids = reordered.map(\.id)

        // Stamp the rows in hand the way the store is about to stamp them —
        // newest first, a second apart — rather than re-reading afterwards. The
        // reasoning is `setPinned`'s: the order is a local fact and a round trip
        // would only make the row land a frame after the finger that dropped it.
        // Mirroring the rule rather than just reassigning `pinnedRows` matters
        // because every later re-section sorts on these dates, so the two have
        // to agree or the next reload of an unrelated row would undo the drag.
        let now = Date()
        var stamps: [UUID: Date] = [:]
        for (offset, id) in ids.enumerated() {
            stamps[id] = now.addingTimeInterval(TimeInterval(-offset))
        }
        apply(rows.map { row in
            guard let stamp = stamps[row.id] else { return row }
            var updated = row
            updated.pinnedAt = stamp
            return updated
        })

        do {
            try await environment.store.reorderPinned(ids)
        } catch {
            statusMessage = SyncFailure.describe(error)
            // The write is the thing that lasts, so if it failed the list has to
            // go back to what is actually stored rather than keep a drag nobody
            // recorded.
            await load()
        }
    }

    /// Draws the group sections in this order, first to last.
    ///
    /// Takes the whole order rather than one move, because the sheet that calls
    /// it collects the drags locally and writes once on Done — reordering four
    /// groups should be one settings write, not four.
    ///
    /// Ungrouped is not in the list and does not move: it is the residue rather
    /// than a group, and it stays last.
    public func moveGroups(to names: [String]) async {
        do {
            try await environment.groups.reorderGroups(names)
            await reapplyGroups()
        } catch {
            statusMessage = SyncFailure.describe(error)
        }
    }

    /// Re-reads the map and re-sections, without re-fetching.
    private func reapplyGroups() async {
        let filed = await environment.groups.groups()
        groupsByFolderName = filed.assignments
        allGroupNames = filed.orderedNames
        apply(rows)
    }

    // MARK: - Making a document

    /// Blank paper, ruled and added to the library (docs/11-backlog.md § B1).
    ///
    /// **Takes nothing and asks nothing.** A new note used to open a sheet with
    /// a title field, a paper picker and a page-count stepper in front of it —
    /// three questions between somebody and a blank page, all three of which
    /// have a good default and two of which are easier to answer once there is
    /// something on the paper. It is named by its first sentence or renamed
    /// from the page, and re-ruled from the page.
    ///
    /// - Returns: the new document's id, so the caller can select it and drop
    ///   the reader straight onto page one. Nil on failure, with the reason in
    ///   `statusMessage`, and nothing has been created.
    public func createNotebook() async -> UUID? {
        do {
            // Read rather than guessed. Every untitled note made on one day
            // wants the same folder name, so this is what turns the second one
            // into `-2` rather than a collision on the store's unique
            // constraint — and untitled is now the ordinary case.
            let existing = try await environment.store.knownFolderNames()
            let created = try await NoteCreator().createNotebook(existingFolderNames: existing)
            let summary = try await environment.store.upsert(created)
            await load()
            return summary.id
        } catch {
            statusMessage = SyncFailure.describe(error)
            return nil
        }
    }

    /// Follows the sync stream for as long as the sidebar is on screen.
    ///
    /// Ingest events reload the list; a folder that went away sets the status
    /// line and nothing else, because losing the folder costs new documents
    /// only (docs/02-spec.md § Cross-cutting).
    ///
    /// A folder problem emitted before this started listening still arrives:
    /// the gateway keeps the last one and replays it on registration, which is
    /// what puts a stale bookmark's sentence under an empty library at launch
    /// (`SyncEventRelay`).
    public func observeSync() async {
        for await event in environment.sync.events() {
            switch event {
            case .ingested, .ingestFailed, .replyReceived:
                await load()
            case let .revised(_, title):
                // The row is already in the list; what changed is under it.
                // One line says so, because a document that silently changes
                // under the reader's ink is worse than one that says it did.
                await load()
                statusMessage = "\(title) was updated by the sender"
            case let .withdrawn(_, title):
                // Gone from the list and into Archived, with everything the
                // reader did to it. The line says where, so a document that
                // vanishes from the sidebar is never a document that vanished.
                await load()
                statusMessage = "\(title) was withdrawn by the sender and moved to Archived"
            case let .scanFinished(ingestedCount):
                if ingestedCount > 0 {
                    await load()
                }
            case .reviewWritten:
                // A bundle reached `outbox/`, which is when a queued review is
                // recorded and its document moves to "Read"
                // (ReviewSheetModel § recordDelivery).
                await load()
            case let .folderUnavailable(reason):
                statusMessage = reason
            case .scanStarted, .transcriptsUpgraded:
                // A rewritten transcript changes nothing the sidebar shows; the
                // reader listens for that one itself (`ReaderModel` § Sync).
                continue
            }
        }
    }

    /// Puts one line under the list. The folder picker in the empty state and
    /// the sidebar's own error paths use it; the model itself sets it after a
    /// re-scan.
    public func report(_ message: String) {
        statusMessage = message
    }

    /// Splits one fetch into the sections the sidebar draws.
    ///
    /// A pinned document goes into `pinnedRows` and *not* into its state
    /// section, so every row appears exactly once. `.archived` is excluded from
    /// both — including from Pinned, so archiving something pinned makes it
    /// leave the list like anything else rather than becoming the one archived
    /// document still on screen.
    private func apply(_ fetched: [DocumentSummary]) {
        let decorated = fetched.map { row -> DocumentSummary in
            var updated = row
            updated.groupName = self.groupsByFolderName[row.folderName]
            return updated
        }
        rows = decorated
        var sections: [DocState: [DocumentSummary]] = [:]
        var pinned: [DocumentSummary] = []
        var byGroup: [String: [DocumentSummary]] = [:]
        var ungrouped: [DocumentSummary] = []
        // Gated here as well as in the query. The store is asked not to return
        // archived rows unless they were wanted, but a bucket that fills from
        // whatever arrives would draw an Archived section the reader never
        // asked for the moment any store answered differently.
        archivedRows = showsArchived ? decorated.filter { $0.state == .archived } : []
        for summary in decorated where summary.state != .archived {
            // The invariant that made Pinned work holds in both modes and for
            // the same reason: a pinned row is drawn in Pinned and nowhere else.
            guard summary.isPinned == false else {
                pinned.append(summary)
                continue
            }
            sections[summary.state, default: []].append(summary)
            if let name = summary.groupName {
                byGroup[name, default: []].append(summary)
            } else {
                ungrouped.append(summary)
            }
        }
        grouped = sections
        // Pinned is the one section the sort menu does not reach: it is in the
        // order the reader dragged it into, which is stored as the pin moments
        // themselves, newest first (docs/02-spec.md § S1).
        pinnedRows = pinned.sorted { left, right in
            (left.pinnedAt ?? .distantPast) > (right.pinnedAt ?? .distantPast)
        }
        // `allGroupNames` is already in the reader's order, so filtering it is
        // cheaper than sorting the keys and keeps one source of order.
        let named = allGroupNames
            .filter { byGroup[$0]?.isEmpty == false }
            .map { GroupSection(name: $0, rows: byGroup[$0] ?? []) }
        groupSections = named + (ungrouped.isEmpty ? [] : [GroupSection(name: nil, rows: ungrouped)])
    }
}
