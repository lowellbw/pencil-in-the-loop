//
//  AnchorResolver.swift
//  Core · Contracts
//
//  ─── SIGNATURES ONLY ─────────────────────────────────────────────────────────
//  W0-B froze these signatures and wrote the doc comments. **Unit U6 writes the
//  bodies.** Every `fatalError("WAVE 1 (U6)")` below is a deliberate placeholder
//  so the file is syntactically complete and everything that calls it compiles
//  today; this is the one file in the repo allowed that pattern, and
//  tooling/lint/check_style.py allow-lists it by name.
//
//  U6: replace the bodies, leave the signatures and the doc comments alone. If a
//  signature turns out to be wrong, that is a change request to the lead, not a
//  local edit — six modules are compiled against these.
//  ─────────────────────────────────────────────────────────────────────────────
//
//  The four-step ladder from docs/03-architecture.md § 3. It runs twice in a
//  document's life: once when the review is written, and again when the agent
//  re-resolves the anchor against a document it may since have regenerated.
//  Both sides must climb the same ladder in the same order or a comment lands in
//  the wrong place.
//

import Foundation

/// Resolves a stored `Anchor` back to a range of text.
///
/// A namespace, not an instance: this is pure text processing with no state and
/// no dependencies, and making it an object would only invite someone to give it
/// a cache.
///
/// **The ladder, in order. Never reorder it.**
///
/// 1. **Exact `prefix + quoted + suffix`.** Almost always hits, and it is the
///    only step that disambiguates a quote appearing twice in a document.
///    Yields `.exact`.
/// 2. **Exact `quoted` alone.** The context moved but the sentence did not.
///    When the quote occurs more than once, the occurrence nearest the previous
///    match position wins. Yields `.quoteOnly`.
/// 3. **Fuzzy `quoted`.** Whitespace normalised, then Levenshtein distance
///    within `fuzzyTolerance` of the quote's length. This is what survives a
///    regenerated document with a reworded sentence. Yields `.fuzzy` with the
///    similarity, so the caller can describe how confident it is.
/// 4. **Page + rect.** No text matched. Yields `.rectFallback`, which every
///    consumer must describe as approximate. `review.md` says so in prose, and
///    that sentence is not decoration (docs/05-file-contracts.md).
///
/// **A line number is never the primary anchor** (CLAUDE.md non-negotiable 5).
/// It may be included as a hint and nothing more.
public enum AnchorResolver {

    /// Characters of context captured either side of the quote
    /// (docs/02-spec.md § S3).
    public static let contextLength = 32

    /// Maximum Levenshtein distance for step 3, as a fraction of the quote's
    /// character count. 15% per docs/03-architecture.md § 3. A quote of 100
    /// characters tolerates 15 edits.
    public static let fuzzyTolerance = 0.15

    /// Below this many characters, fuzzy matching is refused outright: a
    /// four-character quote is within 15% of far too many other four-character
    /// strings, and a confident wrong answer is worse than a rect fallback.
    public static let minimumFuzzyLength = 12

    // MARK: - The ladder

    /// Runs the full four-step ladder.
    ///
    /// - Parameters:
    ///   - anchor: the stored anchor.
    ///   - text: the document text to resolve against. For a markdown document
    ///     this is the contents of `source.md`, and the returned ranges are
    ///     UTF-8 byte offsets into exactly that string. For a PDF-only document
    ///     it is the extracted text, and the caller should treat a resulting
    ///     range as advisory.
    /// - Returns: the highest rung that matched. Always returns something —
    ///   step 4 cannot fail.
    public static func resolve(anchor: Anchor, in text: String) -> AnchorResolution {
        let fallback = AnchorResolution.rectFallback(
            pageIndex: anchor.pageIndex,
            rect: anchor.normalisedRect
        )
        guard !anchor.quoted.isEmpty, !text.isEmpty else { return fallback }

        // Step 1 is only run when there is context to disambiguate with. With
        // both sides empty the needle *is* the quote, so step 1 would answer the
        // same search as step 2 while claiming the stronger `.exact` label and
        // skipping the nearest-occurrence rule — a confident wrong answer where
        // an honest one was available.
        if !anchor.prefix.isEmpty || !anchor.suffix.isEmpty {
            if let range = exactContextualRange(
                prefix: anchor.prefix,
                quoted: anchor.quoted,
                suffix: anchor.suffix,
                in: text
            ) {
                return .exact(range: range)
            }
        }

        if let range = exactQuoteRange(
            quoted: anchor.quoted,
            in: text,
            nearOffset: anchor.sourceRange?.start
        ) {
            return .quoteOnly(range: range)
        }

        if let match = fuzzyQuoteRange(quoted: anchor.quoted, in: text) {
            return .fuzzy(range: match.range, similarity: match.similarity)
        }

        return fallback
    }

    /// Step 1: exact match on `prefix + quoted + suffix`.
    ///
    /// - Returns: the range of the **quoted portion only**, not the context, or
    ///   nil when the contextual quote does not appear verbatim.
    public static func exactContextualRange(
        prefix: String,
        quoted: String,
        suffix: String,
        in text: String
    ) -> SourceRange? {
        guard !quoted.isEmpty else { return nil }
        let needle = prefix + quoted + suffix
        // `.literal` and nothing else: the offsets we return are UTF-8 byte
        // offsets into this exact string, so a canonical-equivalence match that
        // silently accepted a differently-composed accent would hand the caller
        // a range that does not slice where it says it does.
        guard let found = text.range(of: needle, options: [.literal]) else { return nil }
        let start = SourceRange.from(found, in: text).start + prefix.utf8.count
        return SourceRange(start: start, end: start + quoted.utf8.count)
    }

    /// Step 2: exact match on `quoted` alone.
    ///
    /// - Parameter nearOffset: when the quote occurs more than once, the
    ///   occurrence whose start is closest to this offset wins. Pass the
    ///   anchor's stored `sourceRange?.start` when there is one; nil takes the
    ///   first occurrence.
    /// - Returns: nil when the quote does not appear verbatim.
    public static func exactQuoteRange(
        quoted: String,
        in text: String,
        nearOffset: Int? = nil
    ) -> SourceRange? {
        guard !quoted.isEmpty, !text.isEmpty else { return nil }

        var best: SourceRange?
        var bestDistance = Int.max
        var searchStart = text.startIndex

        while searchStart < text.endIndex {
            guard let found = text.range(
                of: quoted,
                options: [.literal],
                range: searchStart..<text.endIndex
            ) else { break }

            let range = SourceRange.from(found, in: text)
            guard let nearOffset else { return range }

            let distance = abs(range.start - nearOffset)
            if distance < bestDistance {
                bestDistance = distance
                best = range
            }
            searchStart = text.index(
                found.lowerBound,
                offsetBy: 1,
                limitedBy: text.endIndex
            ) ?? text.endIndex
        }
        return best
    }

    /// Step 3: fuzzy match on `quoted` with whitespace normalised.
    ///
    /// Compares against candidate windows of `text` of similar length. Refuses
    /// quotes shorter than `minimumFuzzyLength`, and refuses any candidate whose
    /// Levenshtein distance exceeds `tolerance × quoted.count`.
    ///
    /// - Parameter tolerance: defaults to `fuzzyTolerance`. Exposed so tests can
    ///   pin the behaviour at the boundary.
    /// - Returns: the best candidate's range in the **original, un-normalised**
    ///   `text`, together with a similarity of `1 - distance / quoted.count`
    ///   clamped to 0…1. Nil when nothing is close enough.
    public static func fuzzyQuoteRange(
        quoted: String,
        in text: String,
        tolerance: Double = AnchorResolver.fuzzyTolerance
    ) -> (range: SourceRange, similarity: Double)? {
        let needle = Array(normalisedWhitespace(quoted))
        guard needle.count >= minimumFuzzyLength, tolerance >= 0, !text.isEmpty else {
            return nil
        }

        let haystack = NormalisedText(text)
        let hay = haystack.characters
        guard !hay.isEmpty else { return nil }

        let quoteLength = needle.count
        // `+ 1e-9` because 0.15 has no exact binary form: 0.15 * 20 is
        // 3.0000000000000004 and 0.15 * 60 is 8.999999999999998, and a threshold
        // that rounds one of those the wrong way is a boundary that behaves
        // differently on either side of a quote length nobody chose.
        let maxDistance = Int((tolerance * Double(quoteLength) + 1e-9).rounded(.down))
        guard maxDistance < quoteLength else { return nil }

        guard let end = bestMatchEnd(
            needle: needle,
            hay: hay,
            maxDistance: maxDistance
        ) else { return nil }

        // The scan gives the end of the best alignment but not its start, so
        // walk the few starts a match of this length could have had.
        let lowestStart = max(0, end - quoteLength - maxDistance)
        let highestStart = max(0, end - max(1, quoteLength - maxDistance))
        var chosenStart = lowestStart
        var chosenDistance = Int.max
        var start = lowestStart
        while start <= highestStart, start < end {
            let distance = levenshteinDistance(
                String(needle),
                String(hay[start..<end])
            )
            if distance < chosenDistance {
                chosenDistance = distance
                chosenStart = start
            }
            start += 1
        }

        guard chosenDistance <= maxDistance, chosenStart < end else { return nil }
        guard chosenStart < haystack.starts.count, end - 1 < haystack.ends.count else {
            return nil
        }

        let range = SourceRange(
            start: haystack.starts[chosenStart],
            end: haystack.ends[end - 1]
        )
        let similarity = min(1, max(0, 1 - Double(chosenDistance) / Double(quoteLength)))
        return (range: range, similarity: similarity)
    }

    // MARK: - Capture

    /// Builds an anchor at annotation time.
    ///
    /// Captures `contextLength` characters either side of the selection,
    /// clamped at the document's ends. `quoted` is stored verbatim — no
    /// trimming, no whitespace collapsing. Normalisation belongs to step 3 and
    /// nowhere else, because a quote that was trimmed at capture will not match
    /// exactly at step 1.
    ///
    /// - Parameters:
    ///   - text: the document text the selection indexes into.
    ///   - selection: the selected byte range, half-open.
    ///   - pageIndex: zero-based page the touch landed on.
    ///   - normalisedRect: where the selection sits on that page, top-left
    ///     origin.
    ///   - sourceRange: the range in `source.md` when a source map resolved one;
    ///     nil for a PDF-only document.
    public static func captureAnchor(
        in text: String,
        selection: SourceRange,
        pageIndex: Int,
        normalisedRect: NormalisedRect,
        sourceRange: SourceRange?
    ) -> Anchor {
        // The selection arrives from a touch point, and docs/02-spec.md § S3
        // says the anchor is that selection *expanded to a sensible unit*. The
        // expansion is idempotent — a range that is already a whole sentence
        // comes back unchanged — so a caller that expanded first loses nothing
        // by us doing it again, while a caller that forgot still gets a usable
        // anchor rather than three words of a sentence.
        let unit = expandToUnit(selection, in: text)

        guard let range = unit.range(in: text) else {
            return Anchor(
                quoted: "",
                prefix: "",
                suffix: "",
                pageIndex: pageIndex,
                normalisedRect: normalisedRect,
                sourceRange: sourceRange
            )
        }

        let prefixStart = text.index(
            range.lowerBound,
            offsetBy: -contextLength,
            limitedBy: text.startIndex
        ) ?? text.startIndex
        let suffixEnd = text.index(
            range.upperBound,
            offsetBy: contextLength,
            limitedBy: text.endIndex
        ) ?? text.endIndex

        return Anchor(
            quoted: String(text[range]),
            prefix: String(text[prefixStart..<range.lowerBound]),
            suffix: String(text[range.upperBound..<suffixEnd]),
            pageIndex: pageIndex,
            normalisedRect: normalisedRect,
            sourceRange: sourceRange
        )
    }

    /// Expands a raw touch-point selection to a sensible unit: the enclosing
    /// sentence when one can be identified, otherwise the enclosing line
    /// (docs/02-spec.md § S3).
    ///
    /// - Returns: the expanded range, or `selection` unchanged when it is
    ///   already a whole unit or nothing sensible can be found.
    public static func expandToUnit(_ selection: SourceRange, in text: String) -> SourceRange {
        guard selection.isValid, !text.isEmpty,
              let selected = selection.range(in: text) else { return selection }

        // The line first. A unit never begins on one line and ends on another
        // unless the selection already did.
        var lineStart = selected.lowerBound
        while lineStart > text.startIndex {
            let previous = text.index(before: lineStart)
            if text[previous].isNewline { break }
            lineStart = previous
        }
        var lineEnd = selected.upperBound
        while lineEnd < text.endIndex, !text[lineEnd].isNewline {
            lineEnd = text.index(after: lineEnd)
        }
        guard lineStart < lineEnd else { return selection }

        let sentence = sentenceRange(
            containing: selected,
            lineStart: lineStart,
            lineEnd: lineEnd,
            in: text
        )
        let unit = trimmingWhitespace(sentence ?? lineStart..<lineEnd, in: text)
        guard unit.lowerBound < unit.upperBound else { return selection }
        return SourceRange.from(unit, in: text)
    }

    // MARK: - Primitives

    /// Collapses every run of whitespace and newlines to a single space and
    /// trims the ends.
    ///
    /// Used by step 3 only. Deterministic and shared so that the resolver on
    /// this device and any re-implementation on the agent's side normalise
    /// identically.
    public static func normalisedWhitespace(_ text: String) -> String {
        text
            .split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .joined(separator: " ")
    }

    /// Levenshtein edit distance between two strings, counting insertions,
    /// deletions and substitutions at cost 1.
    ///
    /// Compare `Character`s, not bytes: an accented letter is one edit, not
    /// two. Implementations should use the two-row form — quotes are short but
    /// this runs once per candidate window.
    public static func levenshteinDistance(_ lhs: String, _ rhs: String) -> Int {
        let left = Array(lhs)
        let right = Array(rhs)
        guard !left.isEmpty else { return right.count }
        guard !right.isEmpty else { return left.count }

        var previous = Array(0...right.count)
        var current = [Int](repeating: 0, count: right.count + 1)

        for i in 1...left.count {
            current[0] = i
            for j in 1...right.count {
                let substitution = previous[j - 1] + (left[i - 1] == right[j - 1] ? 0 : 1)
                current[j] = min(previous[j] + 1, min(current[j - 1] + 1, substitution))
            }
            swap(&previous, &current)
        }
        return previous[right.count]
    }

    // MARK: - Internals

    /// The end offset, in normalised characters, of the closest alignment of
    /// `needle` to any substring of `hay`.
    ///
    /// Sellers' variant of Levenshtein with Ukkonen's cutoff: row 0 of the
    /// matrix is zeroed so a match may start anywhere, and only the rows that
    /// can still reach `maxDistance` are computed. That makes the scan cost
    /// proportional to `maxDistance × hay.count` rather than
    /// `needle.count × hay.count`, which is what keeps a fuzzy miss on a
    /// 50-page document inside the bundle's two-second budget.
    ///
    /// - Returns: nil when nothing came within `maxDistance`.
    private static func bestMatchEnd(
        needle: [Character],
        hay: [Character],
        maxDistance: Int
    ) -> Int? {
        let quoteLength = needle.count
        var column = Array(0...quoteLength)
        var lastActive = min(maxDistance + 1, quoteLength)
        var bestDistance = maxDistance + 1
        var bestEnd: Int?

        for position in 0..<hay.count {
            let character = hay[position]
            var diagonal = column[0]
            column[0] = 0

            var row = 1
            while row <= lastActive {
                let substitution = diagonal + (needle[row - 1] == character ? 0 : 1)
                let deletion = column[row] + 1
                let insertion = column[row - 1] + 1
                diagonal = column[row]
                column[row] = min(substitution, min(deletion, insertion))
                row += 1
            }

            while lastActive > 0, column[lastActive] > maxDistance {
                lastActive -= 1
            }
            if lastActive < quoteLength {
                lastActive += 1
            } else if column[quoteLength] < bestDistance {
                bestDistance = column[quoteLength]
                bestEnd = position + 1
            }
        }
        return bestEnd
    }

    /// The sentence enclosing `selected` within one line, or nil when the line
    /// carries no sentence boundary that brackets the selection — in which case
    /// the caller falls back to the line, per docs/02-spec.md § S3.
    private static func sentenceRange(
        containing selected: Range<String.Index>,
        lineStart: String.Index,
        lineEnd: String.Index,
        in text: String
    ) -> Range<String.Index>? {
        var boundaries: [String.Index] = []
        var index = lineStart

        while index < lineEnd {
            if isSentenceTerminator(text[index]) {
                var after = text.index(after: index)
                while after < lineEnd, isSentenceCloser(text[after]) {
                    after = text.index(after: after)
                }
                // A full stop only ends a sentence when whitespace or the end of
                // the line follows it. Otherwise it is a decimal point, a
                // version number, or a file extension.
                if after >= lineEnd || text[after].isWhitespace {
                    boundaries.append(after)
                    index = after
                    continue
                }
            }
            index = text.index(after: index)
        }

        guard !boundaries.isEmpty else { return nil }

        var start = lineStart
        for boundary in boundaries where boundary <= selected.lowerBound {
            start = boundary
        }
        var end: String.Index?
        for boundary in boundaries where boundary >= selected.upperBound {
            end = boundary
            break
        }

        // A selection past the last full stop on the line is a sentence still
        // being written; the line's end is its end. Falling back to the whole
        // line here would swallow the finished sentences before it.
        let sentenceEnd = end ?? lineEnd
        guard start < sentenceEnd else { return nil }
        return start..<sentenceEnd
    }

    private static func isSentenceTerminator(_ character: Character) -> Bool {
        character == "." || character == "!" || character == "?"
    }

    private static func isSentenceCloser(_ character: Character) -> Bool {
        character == ")" || character == "]" || character == "\""
            || character == "'" || character == "\u{201D}" || character == "\u{2019}"
            || character == "\u{00BB}"
    }

    private static func trimmingWhitespace(
        _ range: Range<String.Index>,
        in text: String
    ) -> Range<String.Index> {
        var lower = range.lowerBound
        var upper = range.upperBound
        while lower < upper, text[lower].isWhitespace {
            lower = text.index(after: lower)
        }
        while upper > lower {
            let previous = text.index(before: upper)
            if !text[previous].isWhitespace { break }
            upper = previous
        }
        return lower..<upper
    }

    /// `text` with every run of whitespace collapsed to one space, alongside the
    /// UTF-8 byte offsets each surviving character came from.
    ///
    /// Step 3 compares normalised characters but has to answer in offsets into
    /// the original string, so the two maps are built in the same pass. Leading
    /// and trailing whitespace is dropped, which is what
    /// `normalisedWhitespace(_:)` does to the quote.
    private struct NormalisedText {

        /// The normalised characters.
        var characters: [Character] = []

        /// `starts[i]` is the UTF-8 offset in the original text at which
        /// `characters[i]` begins.
        var starts: [Int] = []

        /// `ends[i]` is one past the last UTF-8 byte `characters[i]` came from.
        /// For a collapsed run of whitespace that is the end of the whole run.
        var ends: [Int] = []

        init(_ text: String) {
            var index = text.startIndex
            var offset = 0
            var pendingStart: Int?
            var pendingEnd = 0

            while index < text.endIndex {
                let next = text.index(after: index)
                let width = text.utf8.distance(from: index, to: next)
                let character = text[index]

                if character.isWhitespace || character.isNewline {
                    if pendingStart == nil { pendingStart = offset }
                    pendingEnd = offset + width
                } else {
                    if let whitespaceStart = pendingStart {
                        if !characters.isEmpty {
                            characters.append(" ")
                            starts.append(whitespaceStart)
                            ends.append(pendingEnd)
                        }
                        pendingStart = nil
                    }
                    characters.append(character)
                    starts.append(offset)
                    ends.append(offset + width)
                }

                offset += width
                index = next
            }
        }
    }
}
