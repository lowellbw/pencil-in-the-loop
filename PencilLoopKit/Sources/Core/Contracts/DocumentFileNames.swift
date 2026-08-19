//
//  DocumentFileNames.swift
//  Core · Contracts
//
//  The file names inside a document directory, and the two names a review
//  directory carries that no Core type already owns.
//
//  These strings are a public format (docs/05-file-contracts.md): every tool
//  that writes the sync folder spells them, and so did Sync, Ingest, Storage
//  and Export, in four separate files. STYLE.md § 9 — a constant that appears in
//  two modules belongs in Core — and three Wave 1 units asked for it
//  independently. `review.json` and `manifest.json` are not here because they
//  already live on `ReviewBundle` and `BundleManifest`, beside the types that
//  produce them.
//

import Foundation

/// The names of the files inside `inbox/<YYYY-MM-DD-slug>/`, of the pinned copy
/// of that directory in the app container, and of the two markdown files in a
/// review directory.
///
/// **Never fails.** Everything here is a constant; there is no filesystem
/// access and nothing to be unavailable.
public enum DocumentFileNames {

    /// `document.pdf` — rendered or original. Always present by the time
    /// ingest finishes.
    public static let document = "document.pdf"

    /// `source.md` — the original markdown, when there was one.
    public static let sourceMarkdown = "source.md"

    /// `sourcemap.json` — rendered rect to source range, written whenever this
    /// app did the rendering. Absent for an imported PDF.
    public static let sourceMap = "sourcemap.json"

    /// `meta.json` — origin, title, dates. Optional, and every field in it is
    /// optional too (DocumentMetadata.swift).
    public static let metadata = "meta.json"

    /// `reply.md` — what an agent writes back into a review directory
    /// (docs/04-flows.md § F6).
    public static let reply = "reply.md"

    /// `review.md` — the prose half of a review bundle, and the file the
    /// watcher on the other side gates on (docs/05-file-contracts.md).
    public static let reviewMarkdown = "review.md"

    /// `note.json` — the paper a notebook was ruled with, so that pages
    /// appended later match the ones already in it (docs/11-backlog.md § B1).
    ///
    /// Written only for documents this app authored, and deliberately **not**
    /// part of the sync contract: the ruling is already baked into
    /// `document.pdf`, so nothing on the other side of the folder or the relay
    /// needs it. Absent for every document that arrived from somewhere else.
    public static let note = "note.json"

    /// Every file name a document directory may hold, in the order a reader
    /// should prefer them.
    public static let documentFiles = [document, sourceMarkdown, sourceMap, metadata]
}
