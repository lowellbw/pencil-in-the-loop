//
//  SwiftMarkdownAdapter.swift
//  Ingest · Adapters
//
//  **The only file in the repo permitted to `import Markdown`**
//  (STYLE.md § 7, enforced by tooling/lint/check_imports.py).
//
//  Nothing from `swift-markdown` appears in a signature here — every member is
//  either public and speaks Core's IR, or private and speaks the parser's. That
//  is not tidiness: `swift-markdown` is pre-1.0, and confining it to one file
//  means swapping or upgrading the parser is one file's worth of work rather
//  than six modules' (MarkdownIR.swift header).
//
//  Both modules declare a `SourceRange` and a `ListItem`, so Core's are written
//  qualified throughout this file. Unqualified would compile to whichever the
//  compiler preferred and silently produce the wrong IR.
//
//  Offsets: see SourceOffsetIndex.swift. The parser reports 1-based
//  (line, column); everything we emit is UTF-8 byte offsets into the exact
//  string that was passed in, verified against the bytes wherever the parser
//  also told us what text it read.
//

import Foundation
import Markdown
import Core

/// Parses markdown into Core's IR with `swift-markdown`.
public struct SwiftMarkdownAdapter: MarkdownParsing {

    public init() {}

    /// - Parameter markdown: the full contents of `source.md`.
    /// - Returns: a document whose every node's `sourceRange` indexes UTF-8
    ///   byte offsets into that exact string.
    /// - Throws: `PencilLoopError.markdownParseFailed` only when the parser
    ///   returns nothing at all for a source that plainly has content. Callers
    ///   must not let that lose the document — `MarkdownFallback.preformatted`
    ///   turns the raw text into a renderable document instead
    ///   (docs/04-flows.md § F1).
    public func parse(_ markdown: String) throws -> MarkdownDocument {
        let index = SourceOffsetIndex(source: markdown)
        let root = Markdown.Document(parsing: markdown)

        var blocks: [MarkdownBlock] = []
        for child in root.children {
            blocks.append(contentsOf: convert(child, index: index))
        }

        let hasContent = markdown.contains { character in
            !character.isWhitespace
        }
        if blocks.isEmpty, hasContent {
            throw PencilLoopError.markdownParseFailed(
                reason: "The parser found no blocks in a document that is not empty."
            )
        }

        return MarkdownDocument(source: markdown, blocks: blocks, title: firstHeadingText(in: blocks))
    }

    // MARK: - Ranges

    /// Where a code block's *content* sits inside the block's own range.
    ///
    /// A fenced block's `sourceRange` covers the fences; `code` does not. The
    /// literal the parser read is searched for inside the block, which is the
    /// same verification `SourceOffsetIndex.locate(_:near:)` does everywhere
    /// else in this file.
    ///
    /// - Returns: the block range itself when the content cannot be located —
    ///   an indented code block, whose leading four spaces the parser strips,
    ///   is the case that happens in practice. Coarse but never wrong, which is
    ///   the rule for every range here (MarkdownIR.swift header).
    private func contentRange(
        of code: String,
        in blockRange: Core.SourceRange,
        index: SourceOffsetIndex
    ) -> Core.SourceRange {
        guard code.isEmpty == false else { return blockRange }
        guard let located = index.locate(code, near: blockRange) else { return blockRange }
        guard located.start >= blockRange.start, located.end <= blockRange.end else { return blockRange }
        return located
    }

    // MARK: - Blocks

    private func convert(_ markup: Markup, index: SourceOffsetIndex) -> [MarkdownBlock] {
        let blockRange = sourceRange(of: markup, index: index)

        switch markup {
        case let heading as Heading:
            return [.heading(
                level: min(max(heading.level, 1), 6),
                inlines: inlines(of: heading, index: index),
                sourceRange: blockRange
            )]

        case let paragraph as Paragraph:
            return [.paragraph(inlines: inlines(of: paragraph, index: index), sourceRange: blockRange)]

        case let code as CodeBlock:
            return [.codeBlock(
                language: trimmed(code.language),
                code: code.code,
                contentRange: contentRange(of: code.code, in: blockRange, index: index),
                sourceRange: blockRange
            )]

        case let html as HTMLBlock:
            // Raw HTML is shown verbatim rather than dropped. A block that
            // vanishes from the page is a hole in the source map.
            return [.codeBlock(
                language: "html",
                code: html.rawHTML,
                contentRange: blockRange,
                sourceRange: blockRange
            )]

        case let quote as BlockQuote:
            var inner: [MarkdownBlock] = []
            for child in quote.children {
                inner.append(contentsOf: convert(child, index: index))
            }
            return [.blockquote(blocks: inner, sourceRange: blockRange)]

        case is ThematicBreak:
            return [.thematicBreak(sourceRange: blockRange)]

        case let list as UnorderedList:
            return [.list(ordered: false, items: items(list.listItems, index: index), sourceRange: blockRange)]

        case let list as OrderedList:
            return [.list(ordered: true, items: items(list.listItems, index: index), sourceRange: blockRange)]

        case let table as Table:
            return [convert(table, range: blockRange, index: index)]

        default:
            // Block directives, custom blocks and anything a future release
            // adds: keep the children rather than the wrapper.
            var inner: [MarkdownBlock] = []
            for child in markup.children {
                inner.append(contentsOf: convert(child, index: index))
            }
            return inner
        }
    }

    private func items<S: Sequence>(
        _ listItems: S,
        index: SourceOffsetIndex
    ) -> [Core.ListItem] where S.Element: Markup {
        listItems.map { item in
            var blocks: [MarkdownBlock] = []
            for child in item.children {
                blocks.append(contentsOf: convert(child, index: index))
            }
            return Core.ListItem(blocks: blocks, sourceRange: sourceRange(of: item, index: index))
        }
    }

    private func convert(
        _ table: Table,
        range tableRange: Core.SourceRange,
        index: SourceOffsetIndex
    ) -> MarkdownBlock {
        var header: [TableCell] = []
        for cell in table.head.cells {
            header.append(TableCell(
                inlines: inlines(of: cell, index: index),
                sourceRange: sourceRange(of: cell, index: index)
            ))
        }

        var rows: [TableRow] = []
        for row in table.body.rows {
            var cells: [TableCell] = []
            for cell in row.cells {
                cells.append(TableCell(
                    inlines: inlines(of: cell, index: index),
                    sourceRange: sourceRange(of: cell, index: index)
                ))
            }
            rows.append(TableRow(cells: cells, sourceRange: sourceRange(of: row, index: index)))
        }

        return .table(header: header, rows: rows, sourceRange: tableRange)
    }

    // MARK: - Inlines

    private func inlines(of markup: Markup, index: SourceOffsetIndex) -> [InlineRun] {
        var runs: [InlineRun] = []
        for child in markup.children {
            collect(child, attributes: [], link: nil, index: index, into: &runs)
        }
        return merged(runs)
    }

    private func collect(
        _ markup: Markup,
        attributes: InlineAttributes,
        link: String?,
        index: SourceOffsetIndex,
        into runs: inout [InlineRun]
    ) {
        switch markup {
        case let text as Text:
            add(text.string, attributes: attributes, link: link, markup: markup, index: index, into: &runs)

        case let code as InlineCode:
            add(code.code, attributes: attributes.union(.code), link: link, markup: markup, index: index, into: &runs)

        case is SoftBreak:
            // A newline inside a paragraph is a space on the page, so a break
            // cannot be verified by looking for its own text. It is anchored to
            // the line ending instead — see SourceOffsetIndex.lineBreakRange.
            addBreak(" ", attributes: attributes, link: link, index: index, into: &runs)

        case is LineBreak:
            addBreak("\n", attributes: attributes, link: link, index: index, into: &runs)

        case let emphasis as Emphasis:
            recurse(emphasis, attributes: attributes.union(.emphasis), link: link, index: index, into: &runs)

        case let strong as Strong:
            recurse(strong, attributes: attributes.union(.strong), link: link, index: index, into: &runs)

        case let struck as Strikethrough:
            recurse(struck, attributes: attributes.union(.strikethrough), link: link, index: index, into: &runs)

        case let anchor as Link:
            recurse(anchor, attributes: attributes.union(.link), link: anchor.destination ?? link, index: index, into: &runs)

        default:
            // Images contribute their alt text; inline HTML contributes
            // nothing, which is the right answer for a tag.
            recurse(markup, attributes: attributes, link: link, index: index, into: &runs)
        }
    }

    private func recurse(
        _ markup: Markup,
        attributes: InlineAttributes,
        link: String?,
        index: SourceOffsetIndex,
        into runs: inout [InlineRun]
    ) {
        for child in markup.children {
            collect(child, attributes: attributes, link: link, index: index, into: &runs)
        }
    }

    /// Appends one run of literal text, with its offsets checked against the
    /// bytes the parser claims it read.
    ///
    /// Two anchors are tried, in order: where the parser said the node was, and
    /// — when that turns up nothing — the end of the previous run. The second is
    /// what saves a node the parser did not position, since inline text always
    /// arrives in document order.
    private func add(
        _ text: String,
        attributes: InlineAttributes,
        link: String?,
        markup: Markup,
        index: SourceOffsetIndex,
        into runs: inout [InlineRun]
    ) {
        guard !text.isEmpty else { return }
        var resolved = sourceRange(of: markup, index: index)
        if let located = index.locate(text, near: resolved) {
            resolved = located
        } else {
            let previousEnd = runs.last?.sourceRange.end ?? 0
            let anchor = Core.SourceRange(start: previousEnd, end: previousEnd)
            resolved = index.locate(text, near: anchor) ?? resolved
        }
        runs.append(InlineRun(
            text: text,
            attributes: attributes,
            linkDestination: link,
            sourceRange: resolved
        ))
    }

    /// A soft or hard break: one byte of line ending on disk, a space or a
    /// newline on the page.
    ///
    /// When the line ending cannot be found the break gets an **empty range at
    /// the end of the run before it**, not `.zero`. Both contribute nothing to
    /// the source map, which is what `lineBreakRange(from:)` documents as the
    /// answer — but `.zero` also moved the cursor back to the start of the file,
    /// and the next run searches near where the previous one ended. A run
    /// anchored at offset 0 finds the first identical string near the top of the
    /// document and reports it confidently, which is worse than the coarse
    /// answer this module's rule prefers.
    private func addBreak(
        _ text: String,
        attributes: InlineAttributes,
        link: String?,
        index: SourceOffsetIndex,
        into runs: inout [InlineRun]
    ) {
        let previousEnd = runs.last?.sourceRange.end ?? 0
        let range = index.lineBreakRange(from: previousEnd)
            ?? Core.SourceRange(start: previousEnd, end: previousEnd)
        runs.append(InlineRun(
            text: text,
            attributes: attributes,
            linkDestination: link,
            sourceRange: range
        ))
    }

    /// Merges neighbouring runs that share attributes **and** are contiguous in
    /// the source. Merging across a gap would break the source map
    /// (MarkdownIR.swift § InlineRun).
    ///
    /// The byte-length check is the second half of that rule. A soft break
    /// becomes a space on the page, one byte for one byte, so merging it into
    /// the sentence around it keeps the offsets exact — but the same break in a
    /// CRLF file is two bytes for one, and merging there would shift every
    /// character after it. Runs are only joined when the text still measures
    /// exactly the range it claims.
    private func merged(_ runs: [InlineRun]) -> [InlineRun] {
        var result: [InlineRun] = []
        for run in runs {
            guard var last = result.last,
                  last.attributes == run.attributes,
                  last.linkDestination == run.linkDestination,
                  last.sourceRange.end == run.sourceRange.start,
                  last.text.utf8.count + run.text.utf8.count
                      == run.sourceRange.end - last.sourceRange.start else {
                result.append(run)
                continue
            }
            last.text += run.text
            last.sourceRange = Core.SourceRange(start: last.sourceRange.start, end: run.sourceRange.end)
            result[result.count - 1] = last
        }
        return result
    }

    // MARK: - Ranges

    /// The node's range in UTF-8 bytes, falling back to the nearest ancestor
    /// that has one.
    ///
    /// `SourceRange.zero` means "unknown", not "start of file"
    /// (MarkdownIR.swift header), so it is only returned when neither the node
    /// nor any ancestor was positioned.
    private func sourceRange(of markup: Markup, index: SourceOffsetIndex) -> Core.SourceRange {
        var candidate: Markup? = markup
        while let current = candidate {
            if let reported = current.range {
                return index.range(
                    fromLine: reported.lowerBound.line,
                    fromColumn: reported.lowerBound.column,
                    toLine: reported.upperBound.line,
                    toColumn: reported.upperBound.column
                )
            }
            candidate = current.parent
        }
        return .zero
    }

    private func trimmed(_ language: String?) -> String? {
        guard let language else { return nil }
        let value = language.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private func firstHeadingText(in blocks: [MarkdownBlock]) -> String? {
        for block in blocks {
            guard case let .heading(level, inlines, _) = block, level == 1 else { continue }
            let text = inlines
                .map(\.text)
                .joined()
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { return text }
        }
        return nil
    }
}
