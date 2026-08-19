//
//  NoteSidecar.swift
//  Core · Contracts
//
//  `note.json` — what a document written in this app remembers about itself.
//
//  Deliberately **not** part of the sync contract in docs/05-file-contracts.md.
//  The ruling is already drawn into `document.pdf`, so nothing on the other
//  side of the folder or the relay has any use for this file; it exists only so
//  that pages appended to a notebook months later can be ruled the same way as
//  the ones already in it. A document that arrived from somewhere else has no
//  sidecar, and nothing anywhere may require one.
//

import Foundation

/// The paper a notebook was ruled with, and how many sheets it had when it was
/// last written.
///
/// **On a missing or unreadable file:** the caller treats the notebook as
/// `.plain`. Losing the ruling of appended pages is a cosmetic disappointment;
/// refusing to add a page because a sidecar would not parse is not.
public struct NoteSidecar: Codable, Sendable, Hashable {

    /// The ruling drawn into every page of `document.pdf`.
    public var paper: PaperStyle

    /// The number of pages at the time this file was written. Advisory — the
    /// PDF is the authority, and `DocumentIngestor` measures it.
    public var pageCount: Int

    public init(paper: PaperStyle, pageCount: Int) {
        self.paper = paper
        self.pageCount = pageCount
    }
}
