//
//  SourceMap.swift
//  Core · Contracts
//
//  `sourcemap.json`. Built while rendering markdown to PDF, then used in the
//  other direction to turn a page-anchored comment back into a character range
//  in the markdown the model actually wrote.
//
//  docs/05-file-contracts.md names the file but does not show its shape, so the
//  shape below is a design decision of this unit. See contracts/schema/
//  sourcemap.schema.json and contracts/fixtures/sourcemap.json.
//

import Foundation

/// Rendered geometry paired with source offsets, one entry per laid-out run.
///
/// Written to `sourcemap.json` next to `document.pdf` whenever the document was
/// rendered from `source.md` (docs/04-flows.md § F1). Absent for an imported
/// PDF, which is why every consumer treats it as optional and falls back to
/// quoted-text matching.
///
/// Entries need not be sorted, must not overlap within a page in a way that
/// matters (the nearest-centre lookup breaks ties by document order), and should
/// be as fine-grained as the renderer can manage — one entry per text run beats
/// one per paragraph.
public struct SourceMap: Codable, Sendable, Hashable {

    /// One laid-out run: where it ended up, and where it came from.
    public struct Entry: Codable, Sendable, Hashable {

        /// Zero-based page in `document.pdf`.
        public var pageIndex: Int

        /// Where the run landed, normalised, top-left origin.
        public var rect: NormalisedRect

        /// The UTF-8 byte range in `source.md` it was laid out from.
        public var range: SourceRange

        public init(pageIndex: Int, rect: NormalisedRect, range: SourceRange) {
            self.pageIndex = pageIndex
            self.rect = rect
            self.range = range
        }
    }

    /// Format version. Bump only for a breaking change; readers must accept a
    /// version they do not recognise by ignoring fields they do not know.
    public var version: Int

    /// The document id from `meta.json`, when known. Lets a stray sourcemap be
    /// matched to its document.
    public var documentId: String?

    /// Relative filename the offsets index into. Always `source.md` today; a
    /// field rather than a constant so a future multi-source document does not
    /// need a new format.
    public var sourceFile: String

    /// Unit of `range`. Always `"utf8"` — see `SourceRange` for why. Present so
    /// a reader can refuse a file it would misinterpret rather than silently
    /// mis-slicing.
    public var offsetEncoding: String

    public var entries: [Entry]

    public init(
        version: Int = SourceMap.currentVersion,
        documentId: String? = nil,
        sourceFile: String = "source.md",
        offsetEncoding: String = SourceMap.utf8Encoding,
        entries: [Entry]
    ) {
        self.version = version
        self.documentId = documentId
        self.sourceFile = sourceFile
        self.offsetEncoding = offsetEncoding
        self.entries = entries
    }

    public static let currentVersion = 1
    public static let utf8Encoding = "utf8"

    /// An empty map. Distinguishable from "no map at all", which is `nil`.
    public static let empty = SourceMap(entries: [])

    public var isEmpty: Bool { entries.isEmpty }

    enum CodingKeys: String, CodingKey {
        case version
        case documentId
        case sourceFile = "source"
        case offsetEncoding
        case entries
    }

    // MARK: - Lookups

    /// The source range of the entry nearest to `rect` on `page`.
    ///
    /// Used when a comment is anchored by touch point and we want the character
    /// range behind it. Nearest is measured centre-to-centre; an entry that
    /// actually contains the rect's centre always wins over one that does not,
    /// so a touch inside a paragraph never snaps to the heading above it.
    ///
    /// - Returns: nil when the page has no entries — the caller then falls back
    ///   to quoted-text matching, and if that fails, to the rect itself.
    public func range(nearest rect: NormalisedRect, page: Int) -> SourceRange? {
        let candidates = entries.filter { $0.pageIndex == page }
        guard !candidates.isEmpty else { return nil }

        let containing = candidates.filter { $0.rect.contains(x: rect.midX, y: rect.midY) }
        let pool = containing.isEmpty ? candidates : containing

        var best: Entry?
        var bestDistance = Double.infinity
        for entry in pool {
            let distance = entry.rect.centreDistance(to: rect)
            if distance < bestDistance {
                bestDistance = distance
                best = entry
            }
        }
        return best?.range
    }

    /// Where a character offset ended up on the page.
    ///
    /// The inverse direction: given a range in `source.md` (from an agent's
    /// edit, or from a comment that was resolved by text match), find the page
    /// and rect to scroll to.
    ///
    /// - Returns: the **tightest** entry whose range contains the offset — the
    ///   one with the shortest range, ties broken by document order — or nil
    ///   when nothing contains it. Offsets inside syntax characters that were
    ///   never laid out (a fence marker, a link's brackets) legitimately have
    ///   no geometry.
    ///
    /// Tightest rather than first because entries need not be sorted and need
    /// not be disjoint (see this type's own note on granularity): a producer
    /// that emits one entry for a list item *and* one per bullet inside it has
    /// done nothing wrong, and taking the first match would scroll to the whole
    /// list where the caller asked for one line. Today's renderer emits fine
    /// entries and either rule would agree; this one goes on agreeing with the
    /// caller when a coarser entry appears.
    public func rect(containing offset: Int) -> (page: Int, rect: NormalisedRect)? {
        var tightest: Entry?
        for entry in entries where entry.range.contains(offset: offset) {
            guard let current = tightest else {
                tightest = entry
                continue
            }
            if entry.range.length < current.range.length {
                tightest = entry
            }
        }
        guard let tightest else { return nil }
        return (tightest.pageIndex, tightest.rect)
    }

    /// Every entry on one page, in the order they were recorded.
    public func entries(onPage page: Int) -> [Entry] {
        entries.filter { $0.pageIndex == page }
    }

    /// The union of every rect on a page whose range overlaps `range`.
    ///
    /// This is what turns a resolved text match into a highlight: one call,
    /// one rect per page the passage spans.
    public func rects(forRange range: SourceRange) -> [(page: Int, rect: NormalisedRect)] {
        var byPage: [Int: NormalisedRect] = [:]
        for entry in entries where entry.range.overlaps(range) {
            byPage[entry.pageIndex] = (byPage[entry.pageIndex] ?? .zero).union(entry.rect)
        }
        return byPage
            .sorted { $0.key < $1.key }
            .map { (page: $0.key, rect: $0.value) }
    }
}
