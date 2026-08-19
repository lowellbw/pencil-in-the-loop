//
//  LibraryFetch.swift
//  Storage · Store
//
//  `LibraryQuery` turned into a `FetchDescriptor`. Kept out of `DocumentStore`
//  so the search rules can be read, and tested, without the actor around them.
//
//  ─── WHAT SEARCH COVERS, AND HOW ─────────────────────────────────────────────
//  docs/02-spec.md § S1 requires search across the document text *and* the
//  recognised handwriting. That is three columns: `Document.title`,
//  `Document.extractedText`, and `Page.recognisedInk` across the to-many
//  relationship. All three are in one `#Predicate`, so the fetch is one round
//  trip to SQLite and no rows are faulted in to be filtered afterwards.
//
//  Two things shaped the predicate, and both are worth knowing before editing it:
//
//  1. `Page.recognisedInk` is a non-optional String. `#Predicate` over an
//     optional String across a relationship is the classic SwiftData fetch that
//     compiles and then throws at runtime, so the optionality lives in the DTO
//     instead (see Page.swift).
//  2. `localizedStandardContains` is the only case- and diacritic-insensitive
//     containment SwiftData will translate into SQL. `contains` is
//     case-sensitive and `localizedCaseInsensitiveContains` is not translated.
//  ─────────────────────────────────────────────────────────────────────────────
//

import Foundation
import SwiftData
import Core

/// Builds the fetches the Library runs.
enum LibraryFetch {

    /// The descriptor for one Library query.
    static func descriptor(for query: LibraryQuery) -> FetchDescriptor<Document> {
        let states = allowedStateRawValues(query.states)
        let sort = sortDescriptors(for: query)

        guard let term = searchTerm(in: query) else {
            return FetchDescriptor<Document>(
                predicate: #Predicate<Document> { document in
                    states.contains(document.stateRaw)
                },
                sortBy: sort
            )
        }

        return FetchDescriptor<Document>(
            predicate: #Predicate<Document> { document in
                states.contains(document.stateRaw)
                    && (document.title.localizedStandardContains(term)
                        || document.extractedText.localizedStandardContains(term)
                        || document.pages.contains(where: { page in
                            page.recognisedInk.localizedStandardContains(term)
                        }))
            },
            sortBy: sort
        )
    }

    /// The search text, trimmed. Nil when there is no text filter at all — the
    /// caller then uses the cheaper predicate above.
    static func searchTerm(in query: LibraryQuery) -> String? {
        guard let text = query.searchText else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// The states a query admits, as raw strings.
    ///
    /// An empty set means "every state except `.archived`" (DTOs.swift,
    /// `LibraryQuery.states`), which is what keeps archived documents out of all
    /// three Library sections without every caller remembering to say so.
    static func allowedStateRawValues(_ states: Set<DocState>) -> [String] {
        guard states.isEmpty == false else {
            return DocState.librarySections.map(\.rawValue)
        }
        return states.map(\.rawValue).sorted()
    }

    /// Plain ascending order, exactly as `LibraryQuery.ascending` freezes it:
    /// `true` is oldest-first for `.dateAdded` and **A–Z** for `.title`; `false`
    /// is newest-first and Z–A (DTOs.swift).
    ///
    /// Both branches therefore read the same way — `ascending` maps to
    /// `.forward` — and the tie-breaker is the other column. `.title` breaks
    /// ties newest-first because two documents with the same title are almost
    /// always the same plan sent twice.
    static func sortDescriptors(for query: LibraryQuery) -> [SortDescriptor<Document>] {
        switch query.sort {
        case .dateAdded:
            return [
                SortDescriptor(\Document.addedAt, order: query.ascending ? .forward : .reverse),
                SortDescriptor(\Document.title, order: .forward)
            ]
        case .title:
            return [
                SortDescriptor(\Document.title, order: query.ascending ? .forward : .reverse),
                SortDescriptor(\Document.addedAt, order: .reverse)
            ]
        }
    }
}
