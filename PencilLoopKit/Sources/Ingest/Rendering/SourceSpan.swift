//
//  SourceSpan.swift
//  Ingest · Rendering
//
//  The thing that survives CoreText layout.
//
//  docs/03-architecture.md § 1 asks for `(pageIndex, rect) → range in the
//  original markdown`, recorded *while* rendering rather than reconstructed
//  afterwards. The mechanism is an attribute: every character appended to the
//  `NSAttributedString` carries a `SourceSpan` naming where it came from, and
//  because a `CTRun` is by definition a run of glyphs sharing one attribute
//  dictionary, no glyph run can ever straddle two spans. Walking the runs of a
//  laid-out `CTFrame` therefore hands back the mapping directly.
//
//  A reference type rather than a value on purpose: attribute values are
//  objects, and distinct objects are what make CoreText break runs at span
//  boundaries.
//

import Foundation
import Core

/// Where one stretch of laid-out text came from in `source.md`.
///
/// `utf16Start` is the span's own location in the composed attributed string,
/// which is what lets a run that covers only part of the span be narrowed to
/// the bytes it actually drew.
final class SourceSpan: NSObject {

    /// The whole span's range in `source.md`.
    let range: SourceRange

    /// Location of this span in the composed `NSAttributedString`, in UTF-16
    /// code units — the unit CoreText reports run ranges in.
    let utf16Start: Int

    /// Byte offset in `source.md` for each UTF-16 code unit of the span's text,
    /// plus one past the end. Present only when the laid-out text is
    /// byte-identical to the source it claims to come from.
    ///
    /// Nil for synthetic text (a list bullet, a table rule) and for text the
    /// parser transformed on the way through (an entity, a backslash escape).
    /// A nil table costs granularity, never correctness: the whole span's range
    /// is reported instead of a per-line slice of it.
    private let byteOffsets: [Int]?

    /// A span whose text is claimed to occupy `range` in the source.
    ///
    /// When `offsets` is supplied the claim is verified — and corrected — with
    /// `SourceOffsetIndex.locate(_:near:)` before the per-code-unit table is
    /// built, so a parser range that included the surrounding syntax narrows to
    /// the text itself.
    init(text: String, range: SourceRange, utf16Start: Int, offsets: SourceOffsetIndex?) {
        var resolved = range
        if let offsets, let located = offsets.locate(text, near: range) {
            resolved = located
        }
        self.range = resolved
        self.utf16Start = utf16Start
        if text.utf8.count == resolved.length {
            self.byteOffsets = SourceSpan.byteOffsets(for: text, from: resolved.start)
        } else {
            self.byteOffsets = nil
        }
        super.init()
    }

    /// A span for synthetic text — a bullet, a numbering prefix — that stands in
    /// for source it was not drawn from.
    ///
    /// Pass the narrowest range that honestly produced the glyphs, which for a
    /// list bullet is the item's marker syntax and not the item: there is no
    /// per-code-unit table here, so the whole of `range` is reported for every
    /// run of the span, and a span covering a whole list item makes the bullet
    /// the first map entry containing every offset in that item — which is what
    /// `SourceMap.rect(containing:)` would then answer with. An empty range is
    /// a legitimate value and contributes nothing to the map.
    init(markerFor range: SourceRange, utf16Start: Int) {
        self.range = range
        self.utf16Start = utf16Start
        self.byteOffsets = nil
        super.init()
    }

    /// The source range behind one laid-out run.
    ///
    /// - Parameters:
    ///   - location: the run's start, in the composed string's UTF-16 offsets.
    ///   - length: the run's length in UTF-16 code units.
    /// - Returns: the exact byte range the run drew when this span has a
    ///   per-code-unit table, and the whole span's range when it does not.
    func sourceRange(forUTF16 location: Int, length: Int) -> SourceRange {
        guard let byteOffsets else { return range }
        let lower = location - utf16Start
        let upper = lower + length
        guard lower >= 0, upper >= lower, upper < byteOffsets.count else { return range }
        return SourceRange(start: byteOffsets[lower], end: byteOffsets[upper])
    }

    private static func byteOffsets(for text: String, from start: Int) -> [Int] {
        var offsets: [Int] = []
        offsets.reserveCapacity(text.utf16.count + 1)
        var byte = start
        for scalar in text.unicodeScalars {
            let scalarText = String(scalar)
            let utf16Width = scalarText.utf16.count
            for _ in 0 ..< utf16Width {
                offsets.append(byte)
            }
            byte += scalarText.utf8.count
        }
        offsets.append(byte)
        return offsets
    }
}

extension NSAttributedString.Key {

    /// Carries a `SourceSpan` through CoreText layout. Read back per `CTRun`
    /// while walking a laid-out frame; see `TextFrameRenderer`.
    static let pencilLoopSourceSpan = NSAttributedString.Key("co.pencil-loop.sourceSpan")
}
