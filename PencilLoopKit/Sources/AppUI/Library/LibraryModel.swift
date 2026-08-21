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
    private let environment: any AppEnvironment

    public init(environment: any AppEnvironment) {
        self.environment = environment
    }

    /// Changes whenever the list has to be fetched again. The view drives its
    /// reload from this rather than from two separate change handlers.
    public var reloadKey: String {
        sort.rawValue + "\u{1F}" + searchText
    }

    /// The query the current search and sort describe.
    public var query: LibraryQuery {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return LibraryQuery(
            searchText: trimmed.isEmpty ? nil : trimmed,
            states: [],
            sort: sort,
            ascending: sort == .title
        )
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
        do {
            let fetched = try await environment.store.summaries(query)
            apply(fetched)
            isLoaded = true
        } catch {
            statusMessage = SyncFolderChoice.describe(error)
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
            statusMessage = SyncFolderChoice.describe(error)
        }
        await load()
    }

    /// Swipe to archive. `.archived` is hidden from all three sections and its
    /// bytes stay on disk until the user purges them in Settings
    /// (docs/02-spec.md § S6).
    public func archive(_ summary: DocumentSummary) async {
        do {
            try await environment.store.setState(.archived, documentId: summary.id)
            apply(rows.filter { $0.id != summary.id })
        } catch {
            statusMessage = SyncFolderChoice.describe(error)
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
                updated.isPinned = pinned
                return updated
            })
        } catch {
            statusMessage = SyncFolderChoice.describe(error)
        }
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
            statusMessage = SyncFolderChoice.describe(error)
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
            case .scanStarted:
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
        rows = fetched
        var sections: [DocState: [DocumentSummary]] = [:]
        var pinned: [DocumentSummary] = []
        for summary in fetched where summary.state != .archived {
            if summary.isPinned {
                pinned.append(summary)
            } else {
                sections[summary.state, default: []].append(summary)
            }
        }
        grouped = sections
        pinnedRows = pinned
    }
}
