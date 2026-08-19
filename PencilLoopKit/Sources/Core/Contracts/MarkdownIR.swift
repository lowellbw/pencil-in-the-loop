//
//  MarkdownIR.swift
//  Core · Contracts
//
//  Our own markdown block IR. Several types in one file because they are one
//  grammar; listed in tooling/lint/style_allowlist.txt.
//
//  **No `swift-markdown` type ever escapes its adapter.** `Markdown.Document`,
//  `Markdown.Markup` and friends may appear only inside
//  Sources/Ingest/Adapters/SwiftMarkdownAdapter.swift, which is the single file
//  permitted to `import Markdown` (enforced by tooling/lint/check_imports.py).
//  Everything downstream — the PDF renderer, the source map builder, the tests —
//  sees only the types below. That keeps a pre-1.0 package dependency from
//  reaching into six modules, and it makes the renderer testable without
//  parsing anything.
//
//  **Every node carries a `sourceRange`.** That is the whole point: the renderer
//  lays out a node, records where it landed on the page, and pairs that rect
//  with the node's range to build `sourcemap.json`. A node with a placeholder
//  range is a hole in the source map, so adapters must fill them honestly —
//  `SourceRange.zero` means "unknown", not "start of file".
//

import Foundation

/// A parsed markdown document, ready to lay out.
public struct MarkdownDocument: Codable, Sendable, Hashable {

    /// The original markdown, verbatim. Kept alongside the blocks because every
    /// `sourceRange` is a byte offset into *this* string, and a source map is
    /// meaningless without the text it indexes.
    public var source: String

    /// Top-level blocks in document order.
    public var blocks: [MarkdownBlock]

    /// The first level-1 heading's plain text, when there is one. This is the
    /// title Ingest prefers over the filename.
    public var title: String?

    public init(source: String, blocks: [MarkdownBlock], title: String? = nil) {
        self.source = source
        self.blocks = blocks
        self.title = title
    }

    /// Plain text of the whole document, one block per line, for the search
    /// index and for the speech term list.
    public var plainText: String {
        blocks.map(\.plainText).filter { !$0.isEmpty }.joined(separator: "\n")
    }
}

/// One block-level node.
///
/// Cases carry their children inline. Arrays supply the indirection, so the enum
/// needs no `indirect` and its synthesised `Codable` conformance stays intact.
public enum MarkdownBlock: Codable, Sendable, Hashable {

    /// `level` is 1…6, clamped by the adapter.
    case heading(level: Int, inlines: [InlineRun], sourceRange: SourceRange)

    case paragraph(inlines: [InlineRun], sourceRange: SourceRange)

    /// `language` is the info string, nil when the fence had none. Code is
    /// verbatim including its newlines. Rendering must not re-wrap it — the
    /// authoring guidance in docs/06-integrations.md keeps lines under 76
    /// characters precisely so that no wrapping is needed.
    ///
    /// **Two ranges, because a fenced block has two extents.** `sourceRange`
    /// covers the whole node, fences included, like every other case here;
    /// `contentRange` covers `code` alone. An agent asked to edit the code a
    /// comment points at needs the second — handed the first it would replace
    /// the fences too — and the first is what the source map and every
    /// enclosing node are built from. They are equal when there were no fences,
    /// which is an indented code block or a raw HTML block.
    case codeBlock(language: String?, code: String, contentRange: SourceRange, sourceRange: SourceRange)

    /// `ordered` distinguishes `1.` from `-`. Nested lists appear as a `list`
    /// block inside an item's `blocks`.
    case list(ordered: Bool, items: [ListItem], sourceRange: SourceRange)

    case blockquote(blocks: [MarkdownBlock], sourceRange: SourceRange)

    /// `header` may be empty for a headerless table. Every row should have the
    /// same cell count as the header; the renderer pads rather than trapping.
    case table(header: [TableCell], rows: [TableRow], sourceRange: SourceRange)

    case thematicBreak(sourceRange: SourceRange)

    /// Where this node came from in `MarkdownDocument.source`.
    public var sourceRange: SourceRange {
        switch self {
        case let .heading(_, _, range): return range
        case let .paragraph(_, range): return range
        case let .codeBlock(_, _, _, range): return range
        case let .list(_, _, range): return range
        case let .blockquote(_, range): return range
        case let .table(_, _, range): return range
        case let .thematicBreak(range): return range
        }
    }

    /// The range of the node's *content*, which differs from `sourceRange`
    /// only for a fenced code block.
    ///
    /// Use this when the bytes are going to be quoted or replaced; use
    /// `sourceRange` when the node is being located.
    public var contentRange: SourceRange {
        if case let .codeBlock(_, _, range, _) = self { return range }
        return sourceRange
    }

    /// Text with all formatting dropped. Used for search, term lists and the
    /// quoted excerpts in `review.md`.
    public var plainText: String {
        switch self {
        case let .heading(_, inlines, _):
            return inlines.map(\.text).joined()
        case let .paragraph(inlines, _):
            return inlines.map(\.text).joined()
        case let .codeBlock(_, code, _, _):
            return code
        case let .list(_, items, _):
            return items.map(\.plainText).joined(separator: "\n")
        case let .blockquote(blocks, _):
            return blocks.map(\.plainText).joined(separator: "\n")
        case let .table(header, rows, _):
            let headerLine = header.map(\.plainText).joined(separator: "\t")
            let bodyLines = rows.map { row in
                row.cells.map(\.plainText).joined(separator: "\t")
            }
            return ([headerLine] + bodyLines).filter { !$0.isEmpty }.joined(separator: "\n")
        case .thematicBreak:
            return ""
        }
    }
}

/// One item in an ordered or unordered list. Items hold blocks, not inlines, so
/// that a paragraph and a nested list can both live in one bullet.
public struct ListItem: Codable, Sendable, Hashable {
    public var blocks: [MarkdownBlock]
    public var sourceRange: SourceRange

    public init(blocks: [MarkdownBlock], sourceRange: SourceRange) {
        self.blocks = blocks
        self.sourceRange = sourceRange
    }

    public var plainText: String {
        blocks.map(\.plainText).joined(separator: "\n")
    }
}

/// One table row.
public struct TableRow: Codable, Sendable, Hashable {
    public var cells: [TableCell]
    public var sourceRange: SourceRange

    public init(cells: [TableCell], sourceRange: SourceRange) {
        self.cells = cells
        self.sourceRange = sourceRange
    }
}

/// One table cell. Cells hold inlines only — a block inside a table cell is not
/// supported and the adapter flattens it.
public struct TableCell: Codable, Sendable, Hashable {
    public var inlines: [InlineRun]
    public var sourceRange: SourceRange

    public init(inlines: [InlineRun], sourceRange: SourceRange) {
        self.inlines = inlines
        self.sourceRange = sourceRange
    }

    public var plainText: String { inlines.map(\.text).joined() }
}

/// A run of text sharing one set of inline attributes.
///
/// Adjacent runs with identical attributes may be merged by the adapter, but
/// only when their source ranges are contiguous — merging across a gap would
/// break the source map.
public struct InlineRun: Codable, Sendable, Hashable {

    /// The literal text, with markdown syntax characters already removed.
    public var text: String

    /// Emphasis, strong, code, strikethrough — combinable.
    public var attributes: InlineAttributes

    /// Destination when `attributes` contains `.link`, otherwise nil. Kept as a
    /// `String`, not a `URL`: markdown link targets are frequently relative or
    /// malformed and must survive round-tripping unchanged.
    public var linkDestination: String?

    /// Range in `MarkdownDocument.source` covering this run's *text*, excluding
    /// the surrounding syntax characters.
    public var sourceRange: SourceRange

    public init(
        text: String,
        attributes: InlineAttributes = [],
        linkDestination: String? = nil,
        sourceRange: SourceRange
    ) {
        self.text = text
        self.attributes = attributes
        self.linkDestination = linkDestination
        self.sourceRange = sourceRange
    }
}

/// Inline formatting flags.
///
/// Encodes as a single JSON integer (the raw bit field), not an object, so that
/// an IR dump stays readable and small.
public struct InlineAttributes: OptionSet, Codable, Sendable, Hashable {

    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    public static let emphasis = InlineAttributes(rawValue: 1 << 0)
    public static let strong = InlineAttributes(rawValue: 1 << 1)
    public static let code = InlineAttributes(rawValue: 1 << 2)
    public static let link = InlineAttributes(rawValue: 1 << 3)
    public static let strikethrough = InlineAttributes(rawValue: 1 << 4)

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(rawValue: try container.decode(Int.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}
