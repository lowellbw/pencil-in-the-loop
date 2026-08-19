//
//  SourceRange.swift
//  Core · Contracts
//
//  A character range into the original markdown, encoded as `[start, end]`.
//
//  Replaces `Range<Int>` from docs/03-architecture.md: `Range<Int>` encodes as
//  `{"lowerBound":…,"upperBound":…}`, and docs/05-file-contracts.md shows
//  `"sourceRange": [1204, 1268]`. The on-disk shape wins.
//

import Foundation

/// A half-open range `[start, end)` of **UTF-8 byte offsets** into `source.md`.
///
/// Two things are frozen here and everything downstream depends on both:
///
/// 1. **Half-open.** `start` is included, `end` is not. `end - start` is the
///    length. An empty range has `start == end`. Every producer and consumer in
///    this project uses that convention with no exceptions.
/// 2. **UTF-8 bytes, from the start of the file.** Not characters, not UTF-16
///    code units, not lines. UTF-8 offsets are the only unit that means the same
///    thing in Swift, Python, Go and Rust, and `source.md` is read by tools
///    written in all four. Swift callers must therefore index via
///    `String.utf8`, which is what `range(in:)` below does — never
///    `String.index(offsetBy:)` on Characters, which counts grapheme clusters
///    and will silently disagree the moment an emoji or an accent appears.
///
/// Encodes as `[start, end]`, two JSON integers.
public struct SourceRange: Codable, Sendable, Hashable {

    /// First byte offset, inclusive.
    public var start: Int
    /// One past the last byte offset, exclusive.
    public var end: Int

    /// - Note: does not validate. Use `isValid` if you need to know.
    public init(start: Int, end: Int) {
        self.start = start
        self.end = end
    }

    /// Length in UTF-8 bytes. Negative for an inverted range, which `isValid`
    /// rejects.
    public var length: Int { end - start }

    public var isEmpty: Bool { end == start }

    /// A range is valid when it is non-negative and not inverted.
    public var isValid: Bool { start >= 0 && end >= start }

    public func contains(offset: Int) -> Bool {
        offset >= start && offset < end
    }

    public func overlaps(_ other: SourceRange) -> Bool {
        start < other.end && other.start < end
    }

    /// The smallest range covering both.
    public func union(_ other: SourceRange) -> SourceRange {
        SourceRange(start: min(start, other.start), end: max(end, other.end))
    }

    /// Shift by a byte delta. Used when a parser reports offsets relative to a
    /// fragment rather than the whole file.
    public func offset(by delta: Int) -> SourceRange {
        SourceRange(start: start + delta, end: end + delta)
    }

    // MARK: - String bridging

    /// The corresponding `String.Index` range in `text`, or nil when the range
    /// falls outside the string or lands mid-scalar.
    ///
    /// This is the only supported way to turn a `SourceRange` back into text.
    public func range(in text: String) -> Range<String.Index>? {
        guard isValid else { return nil }
        let utf8 = text.utf8
        guard start <= utf8.count, end <= utf8.count else { return nil }
        let lower = utf8.index(utf8.startIndex, offsetBy: start)
        let upper = utf8.index(utf8.startIndex, offsetBy: end)
        guard let lowerIndex = lower.samePosition(in: text),
              let upperIndex = upper.samePosition(in: text) else { return nil }
        return lowerIndex..<upperIndex
    }

    /// The substring this range names, or nil when the range does not resolve.
    public func substring(of text: String) -> String? {
        guard let range = range(in: text) else { return nil }
        return String(text[range])
    }

    /// Build a `SourceRange` from a Swift string range by measuring UTF-8
    /// offsets from the start of `text`.
    public static func from(_ range: Range<String.Index>, in text: String) -> SourceRange {
        // String.Index is shared across a String's views, so the UTF8View can
        // measure a Character-view range directly. No samePosition dance.
        let utf8 = text.utf8
        let start = utf8.distance(from: utf8.startIndex, to: range.lowerBound)
        let end = utf8.distance(from: utf8.startIndex, to: range.upperBound)
        return SourceRange(start: start, end: end)
    }

    /// The range covering the whole of `text`.
    public static func whole(of text: String) -> SourceRange {
        SourceRange(start: 0, end: text.utf8.count)
    }

    /// An empty range at offset zero. The "no source map" value.
    public static let zero = SourceRange(start: 0, end: 0)

    // MARK: - Codable

    /// Encodes as `[start, end]`.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.unkeyedContainer()
        try container.encode(start)
        try container.encode(end)
    }

    /// Decodes `[start, end]`. Throws `DecodingError.dataCorrupted` on an
    /// inverted or negative range — unlike `meta.json`, a `sourceRange` we
    /// wrote ourselves being nonsense is a bug worth surfacing, and callers
    /// that want tolerance decode into an optional.
    public init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        let start = try container.decode(Int.self)
        let end = try container.decode(Int.self)
        guard start >= 0, end >= start else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: container.codingPath,
                    debugDescription: "sourceRange must be [start, end] with 0 <= start <= end, got [\(start), \(end)]"
                )
            )
        }
        self.init(start: start, end: end)
    }
}

extension SourceRange: CustomStringConvertible {
    public var description: String { "[\(start), \(end))" }
}
