//
//  LibraryReloadSignal.swift
//  AppUI · Library
//
//  The nudge that tells the sidebar its rows are stale.
//
//  ─── WHY THE SIDEBAR NEEDS TELLING ───────────────────────────────────────────
//  `.unread → .reviewing` is written inside the store, at the moment of the
//  write that annotates a document — `DocumentStore.addComment` and
//  `saveDrawing` both call `markAnnotated`, which is "on the first annotation,
//  never on open" (docs/04-flows.md § F2) stated once, in the one place that
//  cannot be raced. The reader deliberately does not write it a second time
//  (ReaderModel § Annotation).
//
//  But `markAnnotated` emits no `SyncEvent`, and `LibraryModel.load()` runs only
//  on a search or sort change, a pull-to-refresh, an archive and a sync event.
//  In a `NavigationSplitView` the sidebar sits beside the reader, so without a
//  nudge a document the user has just annotated stays filed under "Unread" for
//  the rest of the session and the visible half of F2 never happens.
//
//  A counter rather than a closure into `LibraryModel`, because the reader must
//  not hold the library's model: this is one integer, `LibraryView` watches it,
//  and everything else only ever increments it.
//  ─────────────────────────────────────────────────────────────────────────────
//

import Foundation
import Observation

/// A shared "the rows have moved" counter.
///
/// Held by `RootView` for the life of the scene and handed to both the library
/// and the reader. Incrementing it makes `LibraryView` re-read from the store;
/// nothing else observes it.
///
/// **On failure:** none possible. A reload that fails is `LibraryModel`'s to
/// report, and it leaves the previous rows on screen.
@Observable
public final class LibraryReloadSignal {

    /// Bumped every time something has changed a row. Read by `LibraryView` and
    /// by nothing else.
    public private(set) var revision = 0

    public init() {}

    /// Something has changed a document's state, its comment count or its ink.
    ///
    /// Cheap and safe to over-call: one `summaries(_:)` read against a local
    /// store, and a reload that finds nothing new replaces the rows with equal
    /// ones.
    public func note() {
        revision &+= 1
    }
}
