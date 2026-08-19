//
//  MarkdownPDFRenderer.swift
//  Ingest · Rendering
//
//  Markdown → PDF, with the source map built in the same pass
//  (docs/03-architecture.md § 1, docs/04-flows.md § F1).
//
//  Everything becomes a PDF at ingest so there is one annotation engine and one
//  set of page coordinates, and so ink can never drift when a document is
//  reopened. That only holds if pagination is deterministic, which is why this
//  file measures rather than guesses: no reliance on a text system's internal
//  state, no floating page size, no reflow. The same `MarkdownDocument` and the
//  same `PageGeometry` produce the same pages every time.
//
//  Coordinates are top-left origin throughout; `TextFrameRenderer` owns the flip
//  into CoreText's y-up space.
//

import Foundation
import UIKit
import CoreGraphics
import CoreText
import Core

/// Lays a parsed markdown document out as an A4 PDF designed to be written on.
public struct MarkdownPDFRenderer: MarkdownPDFRendering {

    /// A guard against a pathological document paginating forever. Reaching it
    /// is reported as a render failure, which the caller turns into an error row
    /// rather than a missing document (docs/04-flows.md § F1).
    public static let maximumPages = 2000

    public init() {}

    /// Renders and builds the source map in one layout pass.
    ///
    /// - Throws: `PencilLoopError.renderFailed` when the geometry leaves no
    ///   text column, when the graphics context produces nothing, or when the
    ///   document exceeds `maximumPages`. There is never a partial result: a
    ///   half-rendered PDF would be pinned and treated as complete.
    public func render(_ document: MarkdownDocument, geometry: PageGeometry) throws -> RenderedPDF {
        guard geometry.pageWidth > 0, geometry.pageHeight > 0,
              geometry.textColumnWidth > 0, geometry.textColumnHeight > 0 else {
            throw PencilLoopError.renderFailed(reason: "The page geometry leaves no room for text.")
        }

        let typography = MarkdownTypography(geometry: geometry)
        let offsets = SourceOffsetIndex(source: document.source)
        let items = MarkdownLayoutPlanner(typography: typography, offsets: offsets).plan(document)

        let pageSize = CGSize(width: geometry.pageWidth, height: geometry.pageHeight)
        let format = UIGraphicsPDFRendererFormat()
        var info: [String: Any] = [:]
        if let title = document.title, !title.isEmpty {
            info[kCGPDFContextTitle as String] = title
        }
        format.documentInfo = info

        let renderer = UIGraphicsPDFRenderer(
            bounds: CGRect(origin: CGPoint.zero, size: pageSize),
            format: format
        )

        var outcome = PageRun()
        let data = renderer.pdfData { context in
            outcome = self.place(items, geometry: geometry, typography: typography, into: context)
        }

        if outcome.overflowed {
            throw PencilLoopError.renderFailed(
                reason: "The document runs past \(MarkdownPDFRenderer.maximumPages) pages."
            )
        }
        guard !data.isEmpty, outcome.pageCount > 0 else {
            throw PencilLoopError.renderFailed(reason: "The renderer produced no pages.")
        }

        return RenderedPDF(
            pdfData: data,
            pageCount: outcome.pageCount,
            sourceMap: SourceMap(entries: outcome.entries),
            extractedText: document.plainText
        )
    }

    // MARK: - Pagination

    /// Everything one pass over the item list produced.
    private struct PageRun {
        var entries: [SourceMap.Entry] = []
        var pageCount = 0
        var overflowed = false
    }

    private func place(
        _ items: [MarkdownLayoutItem],
        geometry: PageGeometry,
        typography: MarkdownTypography,
        into context: UIGraphicsPDFRendererContext
    ) -> PageRun {
        var run = PageRun()

        let pageSize = CGSize(width: geometry.pageWidth, height: geometry.pageHeight)
        let columnLeft = geometry.marginLeft
        let columnWidth = geometry.textColumnWidth
        let top = geometry.marginTop
        let bottom = geometry.pageHeight - geometry.marginBottom
        let minimumFragment = typography.bodyLineHeight * 1.1
        let cellPadding = 4.0

        var pageIndex = -1
        var cursor = top

        func beginPage() {
            context.beginPage()
            pageIndex += 1
            cursor = top
            run.pageCount = pageIndex + 1
        }

        func room() -> Double { bottom - cursor }

        func atPageTop() -> Bool { cursor <= top }

        func record(_ rect: CGRect, range: SourceRange) {
            guard range.isValid, !range.isEmpty else { return }
            run.entries.append(SourceMap.Entry(
                pageIndex: pageIndex,
                rect: TextFrameRenderer.normalised(rect, pageSize: pageSize),
                range: range
            ))
        }

        func fillUnderlay(_ item: MarkdownLayoutItem, rect: CGRect) {
            let cgContext = context.cgContext
            if item.codeBackground {
                cgContext.setFillColor(UIColor(white: 0.955, alpha: 1).cgColor)
                cgContext.fill(rect.insetBy(dx: -6, dy: -3))
            }
            if item.quoteRule {
                cgContext.setFillColor(UIColor(white: 0.74, alpha: 1).cgColor)
                cgContext.fill(CGRect(x: rect.minX - 10, y: rect.minY, width: 2, height: rect.height))
            }
        }

        func placeText(_ text: NSAttributedString, item: MarkdownLayoutItem) {
            let indent = min(max(item.indent, 0), max(columnWidth - 24, 0))
            let width = columnWidth - indent
            guard width > 0 else { return }

            /// Begins a page for the fragment at `start`, unless that fragment
            /// would lay out nothing even with a whole page to itself.
            ///
            /// A page begun for text that will not fit anywhere is a page the
            /// reader still scrolls through and `run.pageCount` still counts,
            /// and once `beginPage()` has been called there is no taking it
            /// back — so the question is asked first, in a column the size of
            /// the one the page break would produce. Measuring only; the same
            /// layout is redone for real on the other side of the break.
            ///
            /// - Returns: false when the item has to be dropped, which the
            ///   caller answers by returning without having begun a page.
            func beginPageIfAnythingWouldFit(from start: Int) -> Bool {
                let column = CGRect(
                    x: columnLeft + indent,
                    y: top,
                    width: width,
                    height: bottom - top
                )
                guard column.height > 0 else { return false }
                let probe = TextFrameRenderer.layout(
                    text,
                    from: start,
                    in: column,
                    pageIndex: pageIndex,
                    pageSize: pageSize,
                    into: nil
                )
                guard probe.visibleLength > 0 else { return false }
                beginPage()
                return true
            }

            var start = 0
            var isFirstFragment = true

            while start < text.length {
                if isFirstFragment, !atPageTop() {
                    cursor += item.spacingBefore
                }
                if isFirstFragment, item.keepWithNext, !atPageTop() {
                    let wanted = TextFrameRenderer.suggestedHeight(text, from: start, width: width)
                        + typography.bodyLineHeight * 1.6
                    if room() < wanted {
                        guard beginPageIfAnythingWouldFit(from: start) else { return }
                    }
                }
                if room() < minimumFragment, !atPageTop() {
                    guard beginPageIfAnythingWouldFit(from: start) else { return }
                }

                let column = CGRect(x: columnLeft + indent, y: cursor, width: width, height: room())
                guard column.height > 0 else { return }

                if item.codeBackground || item.quoteRule {
                    let probe = TextFrameRenderer.layout(
                        text,
                        from: start,
                        in: column,
                        pageIndex: pageIndex,
                        pageSize: pageSize,
                        into: nil
                    )
                    if probe.visibleLength > 0 {
                        fillUnderlay(item, rect: CGRect(
                            x: column.minX,
                            y: column.minY,
                            width: column.width,
                            height: probe.usedHeight
                        ))
                    }
                }

                let laid = TextFrameRenderer.layout(
                    text,
                    from: start,
                    in: column,
                    pageIndex: pageIndex,
                    pageSize: pageSize,
                    into: context.cgContext
                )
                guard laid.visibleLength > 0 else {
                    // Nothing fitted. On a fresh page that means it never will,
                    // and dropping one item beats looping forever.
                    if atPageTop() { return }
                    guard beginPageIfAnythingWouldFit(from: start) else { return }
                    continue
                }

                run.entries.append(contentsOf: laid.entries)
                cursor += laid.usedHeight
                start += laid.visibleLength
                isFirstFragment = false

                if start < text.length {
                    if run.pageCount >= MarkdownPDFRenderer.maximumPages {
                        run.overflowed = true
                        return
                    }
                    guard beginPageIfAnythingWouldFit(from: start) else { return }
                }
            }
            cursor += item.spacingAfter
        }

        func placeRule(_ item: MarkdownLayoutItem) {
            let thickness = 0.75
            if room() < item.spacingBefore + thickness + item.spacingAfter, !atPageTop() {
                beginPage()
            }
            if !atPageTop() { cursor += item.spacingBefore }
            let rect = CGRect(
                x: columnLeft + item.indent,
                y: cursor,
                width: max(columnWidth - item.indent, 0),
                height: thickness
            )
            context.cgContext.setFillColor(UIColor(white: 0.78, alpha: 1).cgColor)
            context.cgContext.fill(rect)
            record(rect, range: item.sourceRange)
            cursor += thickness + item.spacingAfter
        }

        func placeTable(_ content: MarkdownLayoutItem.TableContent, item: MarkdownLayoutItem) {
            let indent = min(max(item.indent, 0), max(columnWidth - 60, 0))
            let available = columnWidth - indent
            guard available > 0 else { return }
            let widths = MarkdownPDFRenderer.columnWidths(content, available: available)
            guard !widths.isEmpty else { return }

            func heightOfRow(_ cells: [NSAttributedString]) -> Double {
                var height = typography.bodyLineHeight * 0.7
                for (index, cell) in cells.enumerated() where index < widths.count {
                    let inner = widths[index] - cellPadding * 2
                    guard inner > 0 else { continue }
                    height = max(height, TextFrameRenderer.suggestedHeight(cell, from: 0, width: inner))
                }
                return height + cellPadding * 2
            }

            func drawRow(_ cells: [NSAttributedString], height: Double, isHeader: Bool) {
                let cgContext = context.cgContext
                let rowRect = CGRect(x: columnLeft + indent, y: cursor, width: available, height: height)
                if isHeader {
                    cgContext.setFillColor(UIColor(white: 0.94, alpha: 1).cgColor)
                    cgContext.fill(rowRect)
                }
                var x = columnLeft + indent
                for (index, cell) in cells.enumerated() where index < widths.count {
                    let inner = CGRect(
                        x: x + cellPadding,
                        y: cursor + cellPadding,
                        width: widths[index] - cellPadding * 2,
                        height: height - cellPadding * 2
                    )
                    if inner.width > 0, inner.height > 0 {
                        let laid = TextFrameRenderer.layout(
                            cell,
                            from: 0,
                            in: inner,
                            pageIndex: pageIndex,
                            pageSize: pageSize,
                            into: cgContext
                        )
                        run.entries.append(contentsOf: laid.entries)
                    }
                    x += widths[index]
                }
                cgContext.setFillColor(UIColor(white: 0.82, alpha: 1).cgColor)
                cgContext.fill(CGRect(
                    x: rowRect.minX,
                    y: rowRect.maxY - 0.5,
                    width: rowRect.width,
                    height: 0.5
                ))
                cursor += height
            }

            let headerHeight = content.header.isEmpty ? 0 : heightOfRow(content.header)
            if !atPageTop() { cursor += item.spacingBefore }
            if room() < headerHeight + typography.bodyLineHeight, !atPageTop() { beginPage() }
            record(
                CGRect(x: columnLeft + indent, y: cursor, width: available, height: max(headerHeight, 1)),
                range: item.sourceRange
            )
            if !content.header.isEmpty {
                drawRow(content.header, height: headerHeight, isHeader: true)
            }

            for row in content.rows {
                // A row taller than a whole page is clipped to one page rather
                // than looping. Tables are meant to be narrow
                // (docs/06-integrations.md § authoring guidance).
                let height = min(heightOfRow(row), bottom - top)
                if room() < height, !atPageTop() {
                    if run.pageCount >= MarkdownPDFRenderer.maximumPages {
                        run.overflowed = true
                        return
                    }
                    beginPage()
                    if !content.header.isEmpty {
                        drawRow(content.header, height: headerHeight, isHeader: true)
                    }
                }
                drawRow(row, height: height, isHeader: false)
            }
            cursor += item.spacingAfter
        }

        beginPage()
        for item in items {
            if run.overflowed { break }
            if run.pageCount > MarkdownPDFRenderer.maximumPages {
                run.overflowed = true
                break
            }
            switch item.kind {
            case let .text(text):
                guard text.length > 0 else { continue }
                placeText(text, item: item)
            case .rule:
                placeRule(item)
            case let .table(content):
                placeTable(content, item: item)
            }
        }
        return run
    }

    /// Column widths proportional to the natural width of the widest cell,
    /// scaled to fill the text column. Deterministic, so a table paginates the
    /// same way on every run.
    private static func columnWidths(
        _ content: MarkdownLayoutItem.TableContent,
        available: Double
    ) -> [Double] {
        var count = content.header.count
        for row in content.rows {
            count = max(count, row.count)
        }
        guard count > 0, available > 0 else { return [] }

        var natural = [Double](repeating: 0, count: count)
        func measure(_ cells: [NSAttributedString]) {
            for (index, cell) in cells.enumerated() where index < count {
                natural[index] = max(natural[index], Double(cell.size().width) + 8)
            }
        }
        measure(content.header)
        for row in content.rows {
            measure(row)
        }

        let total = natural.reduce(0, +)
        guard total > 0 else {
            return [Double](repeating: available / Double(count), count: count)
        }
        let floorWidth = min(46.0, available / Double(count))
        let widths = natural.map { max(floorWidth, available * $0 / total) }
        let sum = widths.reduce(0, +)
        guard sum > 0 else { return widths }
        return widths.map { $0 * available / sum }
    }
}
