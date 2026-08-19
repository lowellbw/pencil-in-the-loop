//
//  SourceOffsetIndex.swift
//  Ingest · Adapters
//
//  The offset convention, in one place.
//
//  `SourceRange` is frozen as **half-open UTF-8 byte offsets from the start of
//  `source.md`** (Core/Contracts/SourceRange.swift). Markdown parsers do not
//  speak that language: `swift-markdown` reports 1-based (line, column) pairs,
//  and Swift's own `String.Index` counts grapheme clusters while `NSRange`
//  counts UTF-16 code units. Three different units for the same position is
//  exactly how a source map ends up two characters out on every accented
//  character in the document.
//
//  So every conversion in this module funnels through here, and the rule is:
//
//  1. Positions arrive as (line, column) and are treated as **byte** columns,
//     which is what cmark-gfm counts underneath `swift-markdown`.
//  2. The result is snapped to a UTF-8 scalar boundary, so a range can never
//     land mid-character even if the column semantics turn out to be something
//     else on some future release of the parser.
//  3. Where the parser also told us *what text* it found, `locate(_:near:)`
//     verifies the offsets against the bytes actually in the file and corrects
//     them if they disagree. That turns an assumption about a dependency into a
//     checked fact, which matters because everything downstream — the source
//     map, the anchors in `review.json`, the agent's edit landing in the right
//     paragraph — is built on these numbers.
//

import Foundation
import Core

/// Converts a parser's 1-based (line, column) positions into the UTF-8 byte
/// offsets `SourceRange` is defined in, and verifies them against the source.
///
/// Cheap to build (one pass over the bytes) and immutable afterwards, so one
/// instance is shared by the adapter, the layout planner and the renderer.
struct SourceOffsetIndex {

    /// The source, as UTF-8 bytes. Every offset in this type indexes this array.
    let bytes: [UInt8]

    /// Byte offset of the first byte of each line. Line 1 is `lineStarts[0]`.
    private let lineStarts: [Int]

    init(source: String) {
        let bytes = Array(source.utf8)
        var starts: [Int] = [0]
        for index in 0 ..< bytes.count where bytes[index] == 0x0A {
            starts.append(index + 1)
        }
        self.bytes = bytes
        self.lineStarts = starts
    }

    /// The range covering the whole source.
    var wholeRange: SourceRange { SourceRange(start: 0, end: bytes.count) }

    /// The byte offset of a 1-based (line, column) position, clamped into the
    /// line it names so a parser that over-reports a column cannot produce an
    /// offset inside the next paragraph.
    func byteOffset(line: Int, column: Int) -> Int {
        guard !lineStarts.isEmpty else { return 0 }
        let lineIndex = min(max(line - 1, 0), lineStarts.count - 1)
        let start = lineStarts[lineIndex]
        let end = lineIndex + 1 < lineStarts.count ? lineStarts[lineIndex + 1] : bytes.count
        return min(max(start + max(column - 1, 0), start), end)
    }

    /// A half-open byte range from two 1-based (line, column) positions.
    ///
    /// Inverted input is normalised rather than rejected: a parser that reports
    /// an end before a start is a bug we would rather survive than propagate.
    func range(fromLine: Int, fromColumn: Int, toLine: Int, toColumn: Int) -> SourceRange {
        let first = byteOffset(line: fromLine, column: fromColumn)
        let second = byteOffset(line: toLine, column: toColumn)
        return snapped(SourceRange(start: min(first, second), end: max(first, second)))
    }

    /// Moves both ends of a range outwards onto UTF-8 scalar boundaries and
    /// clamps it into the source.
    ///
    /// Outwards rather than inwards on purpose: growing a range by one
    /// continuation byte still quotes the right passage, whereas shrinking it
    /// can cut a character in half and make `SourceRange.substring(of:)` return
    /// nil.
    func snapped(_ range: SourceRange) -> SourceRange {
        var start = min(max(range.start, 0), bytes.count)
        var end = min(max(range.end, start), bytes.count)
        while start > 0, start < bytes.count, isContinuation(bytes[start]) {
            start -= 1
        }
        while end < bytes.count, isContinuation(bytes[end]) {
            end += 1
        }
        return SourceRange(start: start, end: end)
    }

    /// Finds `text` in the source at or near `range`, and returns the range it
    /// actually occupies.
    ///
    /// This is the verification step. The parser tells us both a position and
    /// the literal it read there; when the two agree the answer is `range`
    /// itself and the search costs one memcmp. When they disagree — a column
    /// that counted characters rather than bytes, a node whose range covers its
    /// syntax as well as its content — the nearest exact match inside the
    /// window wins.
    ///
    /// - Returns: nil when `text` does not appear within `window` bytes of
    ///   `range.start`, in which case the caller keeps the parser's range and
    ///   accepts coarser granularity rather than a wrong answer.
    func locate(_ text: String, near range: SourceRange, window: Int = 256) -> SourceRange? {
        let needle = Array(text.utf8)
        guard !needle.isEmpty, needle.count <= bytes.count else { return nil }

        if range.length == needle.count, matches(needle, at: range.start) {
            return range
        }

        let lower = max(0, range.start - window)
        let upper = min(bytes.count - needle.count, range.start + window)
        guard lower <= upper else { return nil }

        var best: Int?
        var bestDistance = Int.max
        for candidate in lower ... upper where matches(needle, at: candidate) {
            let distance = abs(candidate - range.start)
            if distance < bestDistance {
                bestDistance = distance
                best = candidate
            }
        }
        guard let start = best else { return nil }
        return SourceRange(start: start, end: start + needle.count)
    }

    /// The range of the line ending at or just after `offset`, skipping the
    /// spaces, tabs and backslash a markdown line break may sit behind.
    ///
    /// Breaks are the one inline node whose laid-out text is not the text in the
    /// file — a soft break is a newline in the source and a space on the page —
    /// so they cannot be verified by searching for their own content. Anchoring
    /// them to the actual line ending keeps them one byte wide instead of
    /// inheriting the whole paragraph's range, which would put a paragraph-sized
    /// entry in the source map behind a single space.
    ///
    /// - Returns: nil when the next few bytes are not a line ending, in which
    ///   case the caller uses an empty range and the break contributes nothing
    ///   to the map.
    func lineBreakRange(from offset: Int, within limit: Int = 16) -> SourceRange? {
        var cursor = max(offset, 0)
        let end = min(cursor + limit, bytes.count)
        while cursor < end {
            let byte = bytes[cursor]
            if byte == 0x0A {
                return SourceRange(start: cursor, end: cursor + 1)
            }
            if byte == 0x0D {
                let next = cursor + 1
                if next < bytes.count, bytes[next] == 0x0A {
                    return SourceRange(start: cursor, end: next + 1)
                }
                return SourceRange(start: cursor, end: next)
            }
            // Space, tab or backslash: the trailing run that makes a hard break.
            guard byte == 0x20 || byte == 0x09 || byte == 0x5C else { return nil }
            cursor += 1
        }
        return nil
    }

    // MARK: - Private

    private func isContinuation(_ byte: UInt8) -> Bool {
        byte & 0xC0 == 0x80
    }

    private func matches(_ needle: [UInt8], at offset: Int) -> Bool {
        guard offset >= 0, offset + needle.count <= bytes.count else { return false }
        for index in 0 ..< needle.count where bytes[offset + index] != needle[index] {
            return false
        }
        return true
    }
}
