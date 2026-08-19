//
//  MarkdownLayoutPlanner.swift
//  Ingest · Rendering
//
//  IR in, placeable items out. This is where a `SourceSpan` is attached to
//  every character that will be drawn, which is the whole reason the source map
//  can be built in the same pass as the PDF rather than reconstructed afterwards
//  (docs/03-architecture.md § 1).
//
//  Nothing here measures a page. Pagination belongs to the renderer; the
//  planner only decides what the text looks like and how far in it sits.
//

import Foundation
import UIKit
import Core

/// Flattens a `MarkdownDocument` into the sequence the renderer places.
struct MarkdownLayoutPlanner {

    /// Extra indent per blockquote level, in points.
    static let quoteIndent: Double = 16

    /// Extra indent applied to a code block, leaving room for its panel.
    static let codeIndent: Double = 8

    let typography: MarkdownTypography

    /// Used to pin each run's text to the bytes it really occupies. Optional so
    /// the planner can be exercised with hand-built IR in a test.
    let offsets: SourceOffsetIndex?

    init(typography: MarkdownTypography, offsets: SourceOffsetIndex? = nil) {
        self.typography = typography
        self.offsets = offsets
    }

    func plan(_ document: MarkdownDocument) -> [MarkdownLayoutItem] {
        var items: [MarkdownLayoutItem] = []
        append(document.blocks, indent: 0, quoted: false, listDepth: 0, into: &items)
        return items
    }

    // MARK: - Blocks

    private func append(
        _ blocks: [MarkdownBlock],
        indent: Double,
        quoted: Bool,
        listDepth: Int,
        into items: inout [MarkdownLayoutItem]
    ) {
        for block in blocks {
            switch block {
            case let .heading(level, inlines, range):
                let clamped = min(max(level, 1), 6)
                let text = attributed(inlines, role: .heading(level: clamped))
                guard text.length > 0 else { continue }
                items.append(MarkdownLayoutItem(
                    kind: .text(text),
                    indent: indent,
                    spacingBefore: headingSpacing(level: clamped),
                    spacingAfter: typography.bodyLineHeight * 0.35,
                    keepWithNext: true,
                    quoteRule: quoted,
                    sourceRange: range
                ))

            case let .paragraph(inlines, range):
                let text = attributed(inlines, role: quoted ? .quote : .body)
                guard text.length > 0 else { continue }
                items.append(MarkdownLayoutItem(
                    kind: .text(text),
                    indent: indent,
                    spacingBefore: typography.bodyLineHeight * 0.45,
                    spacingAfter: typography.bodyLineHeight * 0.45,
                    quoteRule: quoted,
                    sourceRange: range
                ))

            case let .codeBlock(_, code, _, range):
                let text = attributedCode(code, range: range)
                guard text.length > 0 else { continue }
                items.append(MarkdownLayoutItem(
                    kind: .text(text),
                    indent: indent + MarkdownLayoutPlanner.codeIndent,
                    spacingBefore: typography.bodyLineHeight * 0.55,
                    spacingAfter: typography.bodyLineHeight * 0.55,
                    quoteRule: quoted,
                    codeBackground: true,
                    sourceRange: range
                ))

            case let .list(ordered, listItems, _):
                for (position, item) in listItems.enumerated() {
                    appendListItem(
                        item,
                        marker: marker(ordered: ordered, position: position, depth: listDepth),
                        indent: indent,
                        quoted: quoted,
                        listDepth: listDepth,
                        into: &items
                    )
                }

            case let .blockquote(inner, _):
                append(
                    inner,
                    indent: indent + MarkdownLayoutPlanner.quoteIndent,
                    quoted: true,
                    listDepth: listDepth,
                    into: &items
                )

            case let .table(header, rows, range):
                let content = MarkdownLayoutItem.TableContent(
                    header: header.map { attributed($0.inlines, role: .tableHeader) },
                    rows: rows.map { row in row.cells.map { attributed($0.inlines, role: .tableCell) } }
                )
                guard !content.header.isEmpty || !content.rows.isEmpty else { continue }
                items.append(MarkdownLayoutItem(
                    kind: .table(content),
                    indent: indent,
                    spacingBefore: typography.bodyLineHeight * 0.6,
                    spacingAfter: typography.bodyLineHeight * 0.6,
                    quoteRule: quoted,
                    sourceRange: range
                ))

            case let .thematicBreak(range):
                items.append(MarkdownLayoutItem(
                    kind: .rule,
                    indent: indent,
                    spacingBefore: typography.bodyLineHeight * 0.8,
                    spacingAfter: typography.bodyLineHeight * 0.8,
                    quoteRule: quoted,
                    sourceRange: range
                ))
            }
        }
    }

    // MARK: - Lists

    private func appendListItem(
        _ item: ListItem,
        marker: String,
        indent: Double,
        quoted: Bool,
        listDepth: Int,
        into items: inout [MarkdownLayoutItem]
    ) {
        let markerWidth = width(of: marker)
        var remaining = item.blocks
        var leadInlines: [InlineRun] = []
        var leadRange = item.sourceRange

        if let first = remaining.first, case let .paragraph(inlines, range) = first {
            leadInlines = inlines
            leadRange = range
            remaining.removeFirst()
        }

        // The bullet stands for the marker syntax that produced it — `- `, `1. `
        // — and for nothing wider. It used to carry the whole list item's range,
        // and because a marker span has no per-code-unit table it reported that
        // whole range for the two glyphs of a bullet. `SourceMap.rect(containing:)`
        // answers with the *first* entry containing an offset, and the bullet is
        // recorded first, so every reverse lookup inside a list item — "scroll to
        // this range", a highlight — landed on a few points of bullet instead of
        // on the words at that offset.
        //
        // Empty when the item has no lead paragraph to bound it, which the
        // renderer drops rather than recording a range it cannot justify.
        let markerEnd = min(max(leadRange.start, item.sourceRange.start), item.sourceRange.end)
        let markerRange = SourceRange(start: item.sourceRange.start, end: markerEnd)

        let text = attributed(
            leadInlines,
            role: quoted ? .quote : .body,
            marker: marker,
            markerRange: markerRange,
            hangingIndent: markerWidth
        )
        if text.length > 0 {
            items.append(MarkdownLayoutItem(
                kind: .text(text),
                indent: indent,
                spacingBefore: typography.bodyLineHeight * 0.2,
                spacingAfter: typography.bodyLineHeight * 0.2,
                quoteRule: quoted,
                sourceRange: leadRange
            ))
        }

        append(
            remaining,
            indent: indent + markerWidth,
            quoted: quoted,
            listDepth: listDepth + 1,
            into: &items
        )
    }

    private func marker(ordered: Bool, position: Int, depth: Int) -> String {
        guard !ordered else { return "\(position + 1).\u{2003}" }
        let bullets = ["\u{2022}", "\u{25E6}", "\u{2023}"]
        return bullets[min(max(depth, 0), bullets.count - 1)] + "\u{2003}"
    }

    private func width(of marker: String) -> Double {
        guard !marker.isEmpty else { return 0 }
        let measured = NSAttributedString(
            string: marker,
            attributes: typography.attributes(for: .marker)
        )
        return Double(measured.size().width)
    }

    private func headingSpacing(level: Int) -> Double {
        let scale = [1.4, 1.2, 1.0, 0.9, 0.8, 0.8][min(max(level, 1), 6) - 1]
        return typography.bodyLineHeight * scale
    }

    // MARK: - Composition

    /// Builds the attributed string for a run of inlines, attaching a
    /// `SourceSpan` to every character so the renderer can read the mapping back
    /// off each `CTRun`.
    private func attributed(
        _ inlines: [InlineRun],
        role: MarkdownTypography.Role,
        marker: String = "",
        markerRange: SourceRange = .zero,
        hangingIndent: Double = 0
    ) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let style = typography.paragraphStyle(for: role, hangingIndent: hangingIndent)

        if !marker.isEmpty {
            var attributes = typography.attributes(for: .marker)
            attributes[.paragraphStyle] = style
            attributes[.pencilLoopSourceSpan] = SourceSpan(
                markerFor: markerRange,
                utf16Start: result.length
            )
            result.append(NSAttributedString(string: marker, attributes: attributes))
        }

        for run in inlines where !run.text.isEmpty {
            var attributes = typography.attributes(for: role, inline: run.attributes)
            attributes[.paragraphStyle] = style
            attributes[.pencilLoopSourceSpan] = SourceSpan(
                text: run.text,
                range: run.sourceRange,
                utf16Start: result.length,
                offsets: offsets
            )
            result.append(NSAttributedString(string: run.text, attributes: attributes))
        }
        return result
    }

    private func attributedCode(_ code: String, range: SourceRange) -> NSAttributedString {
        var text = code
        while text.hasSuffix("\n") {
            text.removeLast()
        }
        guard !text.isEmpty else { return NSAttributedString() }
        var attributes = typography.attributes(for: .code)
        attributes[.paragraphStyle] = typography.paragraphStyle(for: .code)
        attributes[.pencilLoopSourceSpan] = SourceSpan(
            text: text,
            range: range,
            utf16Start: 0,
            offsets: offsets
        )
        return NSAttributedString(string: text, attributes: attributes)
    }
}
