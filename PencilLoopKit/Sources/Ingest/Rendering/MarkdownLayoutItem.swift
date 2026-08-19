//
//  MarkdownLayoutItem.swift
//  Ingest · Rendering
//
//  The flat list the renderer walks. `MarkdownLayoutPlanner` turns the nested
//  IR into a sequence of these; the renderer then does nothing but place them,
//  which is what keeps pagination deterministic — the same document and the
//  same `PageGeometry` produce the same item list and therefore the same page
//  breaks, every run (Protocols.swift § MarkdownPDFRendering).
//

import Foundation
import UIKit
import Core

/// One placeable thing: a run of text, a rule, or a table.
///
/// Nesting — a list inside a blockquote inside a list — is flattened into
/// `indent`, so the renderer never recurses and a deeply nested document cannot
/// cost more than a deep one.
struct MarkdownLayoutItem {

    /// A table, already composed into per-cell attributed strings.
    struct TableContent {
        var header: [NSAttributedString]
        var rows: [[NSAttributedString]]
    }

    enum Kind {
        case text(NSAttributedString)
        case rule
        case table(TableContent)
    }

    var kind: Kind

    /// Points from the left edge of the text column. Carries list and
    /// blockquote nesting.
    var indent: Double = 0

    /// Space above, suppressed at the top of a page so every page starts on the
    /// same baseline.
    var spacingBefore: Double = 0

    /// Space below.
    var spacingAfter: Double = 0

    /// A heading with nothing under it at the foot of a page is a bad page.
    /// Items marked this way move to the next page rather than stranding.
    var keepWithNext: Bool = false

    /// Draw the blockquote bar to the left of this item.
    var quoteRule: Bool = false

    /// Fill a panel behind this item.
    var codeBackground: Bool = false

    /// What this item was laid out from. Recorded for rules and tables, which
    /// have no text runs of their own to carry a span.
    var sourceRange: SourceRange = .zero
}
