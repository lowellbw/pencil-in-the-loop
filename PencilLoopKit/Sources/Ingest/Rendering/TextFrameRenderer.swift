//
//  TextFrameRenderer.swift
//  Ingest · Rendering
//
//  One column of text, laid out with CoreText, drawn, and read back.
//
//  This is the source map's factory floor. `CTFramesetterCreateFrame` gives a
//  `CTFrame`; its `CTLine`s carry origins and its `CTRun`s carry both
//  typographic bounds and the attribute dictionary they were composed with. A
//  run is by definition a stretch of glyphs sharing one attribute dictionary, so
//  a run can never straddle two `SourceSpan`s — which is what makes
//  `(pageIndex, rect) → SourceRange` fall out of layout instead of having to be
//  reconstructed from it (docs/03-architecture.md § 1).
//
//  Coordinates: everything crossing this file's boundary is **top-left origin,
//  y increasing downwards**, matching `NormalisedRect`. CoreText is y-up, so the
//  flip happens here and nowhere else.
//

import Foundation
import UIKit
import CoreGraphics
import CoreText
import Core

/// Lays out, draws and measures one attributed string inside one column.
struct TextFrameRenderer {

    /// What one column of layout produced.
    struct Outcome {

        /// UTF-16 code units of the string that fitted. Zero means nothing fit.
        var visibleLength: Int = 0

        /// Points consumed from the top of the column, measured to the descender
        /// of the last line that fitted.
        var usedHeight: Double = 0

        /// Source map entries for everything drawn, in reading order.
        var entries: [SourceMap.Entry] = []
    }

    /// Height this text wants, given unlimited vertical room. Used to decide
    /// whether a heading would be stranded at the foot of a page.
    static func suggestedHeight(_ text: NSAttributedString, from start: Int, width: Double) -> Double {
        guard text.length > start, start >= 0, width > 0 else { return 0 }
        let framesetter = CTFramesetterCreateWithAttributedString(text as CFAttributedString)
        var fitRange = CFRange(location: 0, length: 0)
        let size = CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter,
            CFRange(location: start, length: 0),
            nil,
            CGSize(width: width, height: Double.greatestFiniteMagnitude),
            &fitRange
        )
        return Double(size.height)
    }

    /// Lays `text` out from `start` inside `columnRect`, optionally drawing it,
    /// and returns what fitted along with its source map entries.
    ///
    /// - Parameters:
    ///   - columnRect: top-left origin, in page points.
    ///   - context: nil to measure without drawing. Measuring and drawing use
    ///     identical inputs, so the two passes agree exactly — which is what
    ///     lets a code panel be painted underneath text whose height is not
    ///     known until it has been laid out.
    /// - Returns: an empty outcome when nothing fits, which the caller answers
    ///   with a page break rather than by dropping the text.
    static func layout(
        _ text: NSAttributedString,
        from start: Int,
        in columnRect: CGRect,
        pageIndex: Int,
        pageSize: CGSize,
        into context: CGContext?
    ) -> Outcome {
        var outcome = Outcome()
        guard text.length > start, start >= 0, columnRect.width > 0, columnRect.height > 0 else {
            return outcome
        }

        let framesetter = CTFramesetterCreateWithAttributedString(text as CFAttributedString)
        let flipped = CGRect(
            x: columnRect.minX,
            y: pageSize.height - columnRect.maxY,
            width: columnRect.width,
            height: columnRect.height
        )
        let path = CGPath(rect: flipped, transform: nil)
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: start, length: 0), path, nil)

        let visible = CTFrameGetVisibleStringRange(frame)
        guard visible.length > 0 else { return outcome }
        outcome.visibleLength = visible.length

        if let context {
            context.saveGState()
            context.translateBy(x: 0, y: pageSize.height)
            context.scaleBy(x: 1, y: -1)
            context.textMatrix = CGAffineTransform.identity
            CTFrameDraw(frame, context)
            context.restoreGState()
        }

        let lines = CTFrameGetLines(frame) as? [CTLine] ?? []
        guard !lines.isEmpty else { return outcome }
        var origins = [CGPoint](repeating: CGPoint.zero, count: lines.count)
        CTFrameGetLineOrigins(frame, CFRange(location: 0, length: 0), &origins)

        var lowestBottom = Double(flipped.maxY)

        for (lineIndex, line) in lines.enumerated() {
            var ascent = CGFloat(0)
            var descent = CGFloat(0)
            var leading = CGFloat(0)
            _ = CTLineGetTypographicBounds(line, &ascent, &descent, &leading)

            let baseline = Double(flipped.minY) + Double(origins[lineIndex].y)
            lowestBottom = min(lowestBottom, baseline - Double(descent))

            let lineTop = Double(pageSize.height) - (baseline + Double(ascent))
            let lineHeight = Double(ascent) + Double(descent)
            let lineLeft = Double(flipped.minX) + Double(origins[lineIndex].x)

            var lineEntries: [SourceMap.Entry] = []
            let runs = CTLineGetGlyphRuns(line) as? [CTRun] ?? []
            for run in runs {
                let runRange = CTRunGetStringRange(run)
                guard runRange.length > 0, runRange.location >= 0, runRange.location < text.length else {
                    continue
                }
                guard let span = text.attribute(
                    .pencilLoopSourceSpan,
                    at: runRange.location,
                    effectiveRange: nil
                ) as? SourceSpan else { continue }

                let range = span.sourceRange(forUTF16: runRange.location, length: runRange.length)
                guard range.isValid, !range.isEmpty else { continue }

                let leftOffset = Double(CTLineGetOffsetForStringIndex(line, runRange.location, nil))
                let rightOffset = Double(CTLineGetOffsetForStringIndex(
                    line,
                    runRange.location + runRange.length,
                    nil
                ))
                let width = abs(rightOffset - leftOffset)
                guard width > 0 else { continue }

                let rect = CGRect(
                    x: lineLeft + min(leftOffset, rightOffset),
                    y: lineTop,
                    width: width,
                    height: lineHeight
                )
                lineEntries.append(SourceMap.Entry(
                    pageIndex: pageIndex,
                    rect: normalised(rect, pageSize: pageSize),
                    range: range
                ))
            }
            outcome.entries.append(contentsOf: coalesced(lineEntries))
        }

        outcome.usedHeight = max(0, Double(pageSize.height) - lowestBottom - Double(columnRect.minY))
        return outcome
    }

    /// Point rect to `NormalisedRect`, top-left origin. The one place the
    /// division happens.
    static func normalised(_ rect: CGRect, pageSize: CGSize) -> NormalisedRect {
        NormalisedRect(
            cgRectLikeX: Double(rect.minX),
            y: Double(rect.minY),
            width: Double(rect.width),
            height: Double(rect.height),
            inPageWidth: Double(pageSize.width),
            pageHeight: Double(pageSize.height)
        )
    }

    /// Merges neighbouring entries on one line whose source ranges are
    /// contiguous.
    ///
    /// A sentence with one bold word in it is three runs and one passage; a
    /// reader looking up the range behind a touch wants the passage. Entries are
    /// only merged when they are adjacent in the source as well as on the page,
    /// so a run that skipped over syntax characters still starts a new entry.
    private static func coalesced(_ entries: [SourceMap.Entry]) -> [SourceMap.Entry] {
        guard entries.count > 1 else { return entries }
        var merged: [SourceMap.Entry] = []
        for entry in entries {
            guard var last = merged.last,
                  last.pageIndex == entry.pageIndex,
                  last.range.end == entry.range.start else {
                merged.append(entry)
                continue
            }
            last.range = SourceRange(start: last.range.start, end: entry.range.end)
            last.rect = last.rect.union(entry.rect)
            merged[merged.count - 1] = last
        }
        return merged
    }
}
