//
//  TermListCorrector.swift
//  Annotate · Speech
//
//  Jargon repair by post-processing, because `SpeechAnalyzer` has no
//  vocabulary-biasing API (docs/03-architecture.md § 4). Engine-independent on
//  purpose: the same corrector runs behind either engine, and the term list it
//  builds is also what the fallback engine takes as `contextualStrings`.
//

import Foundation
import Core

/// Builds a document's term list and fuzzy-corrects a transcript against it.
///
/// **Conservative by design.** An over-eager corrector is worse than none: a
/// missed piece of jargon is a typo a reader forgives, a rewritten correct word
/// is a sentence that means something else. So every rule here exists to
/// *refuse* a correction, and a token is only rewritten when all of them agree:
///
/// 1. It is at least `minimumFuzzyLength` characters and entirely letters.
/// 2. It is not a common English word (`isCommonWord(_:)`).
/// 3. Its edit distance to the term is within
///    `maximumEditDistance(forTokenLength:)` — one edit from five characters,
///    two from ten, none below five. That caps a correction at a fifth of the
///    token, the same neighbourhood as `AnchorResolver.fuzzyTolerance`.
/// 4. It shares the term's first letter. Recognisers mangle word endings far
///    more often than beginnings, and this one rule removes most false matches.
/// 5. Exactly one term is that close. A tie is an admission that we do not know
///    which was meant, and the answer to that is to change nothing.
///
/// **On failure:** there is none. Both members are pure and total; an empty
/// document yields an empty term list, and a transcript that matches nothing
/// comes back unchanged (Protocols.swift § TranscriptCorrecting).
///
/// **The only implementation.** Ingest had a second one with the same signature
/// and no protocol behind it; it was deleted rather than promoted, because the
/// terms are wanted while a comment popover is open and are derived then, from
/// `DocumentDetail.extractedText` and the title. AppUI reaches this through
/// `AppEnvironment.corrector`.
public struct TermListCorrector: TranscriptCorrecting {

    // MARK: Thresholds

    /// The list is capped here because that is roughly what
    /// `SFSpeechRecognitionRequest.contextualStrings` accepts, and the same
    /// list feeds both engines (Protocols.swift § TranscriptCorrecting.terms).
    public static let maximumTerms = 100

    /// Terms shorter than this are never collected: a three-letter term is a
    /// correction waiting to happen.
    public static let minimumTermLength = 4

    /// Below this length a token is only ever re-cased against an exact match,
    /// never fuzzy-corrected. Four-letter words are too close to each other for
    /// edit distance to mean anything.
    public static let minimumFuzzyLength = 5

    /// How many edits may separate a transcript token from a term before the
    /// correction is refused.
    ///
    /// One edit from five characters, two from ten, none below five — at most a
    /// fifth of the token, falling to a tenth for long identifiers, which are
    /// exactly the words a recogniser gets nearly-right.
    public static func maximumEditDistance(forTokenLength length: Int) -> Int {
        switch length {
        case ..<minimumFuzzyLength: return 0
        case minimumFuzzyLength..<10: return 1
        default: return 2
        }
    }

    public init() {}

    // MARK: Term list

    /// Identifiers, code spans, capitalised nouns and title words, in
    /// descending order of usefulness and de-duplicated case-insensitively.
    ///
    /// Ranking, best first: words from the title (the reader is most likely to
    /// say them), then identifiers and anything inside a code span, then
    /// capitalised nouns from the prose. Within a rank, more frequent first,
    /// then longer first — a long term is both more distinctive and safer to
    /// correct towards.
    public func terms(forDocumentText text: String, title: String) -> [String] {
        var candidates: [String: Candidate] = [:]

        func note(_ term: String, rank: Int) {
            guard Self.isUsableTerm(term) else { return }
            let key = term.lowercased()
            if var existing = candidates[key] {
                existing.count += 1
                existing.rank = min(existing.rank, rank)
                candidates[key] = existing
            } else {
                candidates[key] = Candidate(term: term, rank: rank, count: 1)
            }
        }

        for word in Self.wordRuns(in: title) {
            note(String(word), rank: 0)
        }

        for span in Self.codeSpans(in: text) {
            for word in Self.wordRuns(in: span) {
                note(String(word), rank: 1)
            }
        }

        for word in Self.wordRuns(in: text) {
            if Self.isIdentifierLike(word) {
                note(String(word), rank: 1)
            } else if Self.isCapitalised(word) {
                note(String(word), rank: 2)
            }
        }

        let ordered = candidates.values.sorted { left, right in
            if left.rank != right.rank { return left.rank < right.rank }
            if left.count != right.count { return left.count > right.count }
            if left.term.count != right.term.count { return left.term.count > right.term.count }
            return left.term < right.term
        }
        return ordered.prefix(Self.maximumTerms).map(\.term)
    }

    // MARK: Correction

    /// Rewrites transcript tokens that are plausibly a mangled term, and leaves
    /// everything else exactly as it was — whitespace, punctuation and casing
    /// included.
    ///
    /// A token that already matches a term case-insensitively is re-cased to the
    /// term's own spelling, which is free and is most of the value: recognisers
    /// return "pencilkit", the document says `PencilKit`.
    public func correct(_ transcript: String, against terms: [String]) -> String {
        guard transcript.isEmpty == false, terms.isEmpty == false else { return transcript }

        var exact: [String: String] = [:]
        var fuzzy: [[Character]] = []
        var fuzzyTerms: [String] = []
        for term in terms {
            guard Self.isUsableTerm(term) else { continue }
            let key = term.lowercased()
            if exact[key] == nil { exact[key] = term }
            if term.count >= Self.minimumFuzzyLength, term.allSatisfy({ $0.isLetter }) {
                fuzzy.append(Array(key))
                fuzzyTerms.append(term)
            }
        }
        guard exact.isEmpty == false else { return transcript }

        var output = ""
        output.reserveCapacity(transcript.count)
        for piece in Self.pieces(of: transcript) {
            switch piece {
            case let .separator(text):
                output += text
            case let .word(text):
                output += Self.corrected(
                    token: text,
                    exact: exact,
                    fuzzy: fuzzy,
                    fuzzyTerms: fuzzyTerms
                )
            }
        }
        return output
    }

    private static func corrected(
        token: String,
        exact: [String: String],
        fuzzy: [[Character]],
        fuzzyTerms: [String]
    ) -> String {
        let lowered = token.lowercased()

        // Free and safe: the same word, spelled the way the document spells it.
        if let canonical = exact[lowered] {
            return canonical == token ? token : canonical
        }

        // Rule 1 and rule 2: long enough, all letters, and not a word of
        // ordinary English that the user plainly meant.
        guard token.count >= minimumFuzzyLength,
              token.allSatisfy({ $0.isLetter }),
              isCommonWord(lowered) == false else { return token }

        let allowance = maximumEditDistance(forTokenLength: token.count)
        guard allowance > 0 else { return token }

        let characters = Array(lowered)
        var bestDistance = allowance + 1
        var bestIndex = -1
        var bestIsTied = false

        for index in fuzzy.indices {
            let candidate = fuzzy[index]

            // Rule 4: same first letter. Cheap, and it is the single most
            // effective filter against nonsense rewrites.
            guard candidate.first == characters.first else { continue }
            guard abs(candidate.count - characters.count) <= allowance else { continue }

            let distance = editDistance(characters, candidate, limit: allowance)
            guard distance <= allowance else { continue }
            if distance < bestDistance {
                bestDistance = distance
                bestIndex = index
                bestIsTied = false
            } else if distance == bestDistance,
                      bestIndex >= 0,
                      fuzzyTerms[index].lowercased() != fuzzyTerms[bestIndex].lowercased() {
                // Rule 5: two terms are equally close, so we do not know which
                // was meant, so we change nothing.
                bestIsTied = true
            }
        }

        guard bestIsTied == false, bestIndex >= 0 else { return token }
        return fuzzyTerms[bestIndex]
    }

    // MARK: Text utilities

    /// Levenshtein distance, abandoned as soon as every cell in a row exceeds
    /// `limit` — the answer past that point is "too far", and the exact value is
    /// of no interest.
    static func editDistance(_ left: [Character], _ right: [Character], limit: Int) -> Int {
        if left.isEmpty { return right.count }
        if right.isEmpty { return left.count }

        var previous = Array(0...right.count)
        var current = [Int](repeating: 0, count: right.count + 1)

        for i in 1...left.count {
            current[0] = i
            var rowBest = current[0]
            for j in 1...right.count {
                let substitution = previous[j - 1] + (left[i - 1] == right[j - 1] ? 0 : 1)
                current[j] = min(substitution, min(previous[j] + 1, current[j - 1] + 1))
                rowBest = min(rowBest, current[j])
            }
            if rowBest > limit { return limit + 1 }
            swap(&previous, &current)
        }
        return previous[right.count]
    }

    /// One term-list candidate, with what it takes to rank it.
    private struct Candidate {
        var term: String
        var rank: Int
        var count: Int
    }

    /// A run of transcript, split so that reassembling the pieces in order
    /// reproduces the input exactly.
    enum Piece: Equatable {
        case word(String)
        case separator(String)
    }

    /// Splits into word runs and everything between them. Apostrophes stay
    /// inside a word so "don't" is one token rather than two.
    static func pieces(of text: String) -> [Piece] {
        var result: [Piece] = []
        var current = ""
        var inWord = false
        for character in text {
            let isWord = character.isLetter || character.isNumber || character == "'" || character == "\u{2019}"
            if isWord != inWord, current.isEmpty == false {
                result.append(inWord ? .word(current) : .separator(current))
                current = ""
            }
            inWord = isWord
            current.append(character)
        }
        if current.isEmpty == false {
            result.append(inWord ? .word(current) : .separator(current))
        }
        return result
    }

    /// Maximal runs of characters that can appear inside an identifier.
    /// Dots and underscores stay inside so `source.md` and `page_index` survive
    /// as single terms.
    static func wordRuns(in text: String) -> [Substring] {
        var runs: [Substring] = []
        var start: String.Index?
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            let isWord = character.isLetter || character.isNumber
                || character == "_" || character == "." || character == "-"
            if isWord {
                if start == nil { start = index }
            } else if let began = start {
                runs.append(text[began..<index])
                start = nil
            }
            index = text.index(after: index)
        }
        if let began = start {
            runs.append(text[began..<text.endIndex])
        }
        return runs.map { run in
            // A trailing full stop is sentence punctuation, not part of a term.
            var trimmed = run
            while let last = trimmed.last, last == "." || last == "-" {
                trimmed = trimmed.dropLast()
            }
            return trimmed
        }
    }

    /// The contents of every backtick span and fenced block, in order.
    static func codeSpans(in text: String) -> [String] {
        var spans: [String] = []
        let characters = Array(text)
        var index = 0
        while index < characters.count {
            guard characters[index] == "`" else {
                index += 1
                continue
            }
            var fence = 0
            while index + fence < characters.count, characters[index + fence] == "`" {
                fence += 1
            }
            let bodyStart = index + fence
            var cursor = bodyStart
            var closed = false
            while cursor < characters.count {
                if characters[cursor] == "`" {
                    var run = 0
                    while cursor + run < characters.count, characters[cursor + run] == "`" {
                        run += 1
                    }
                    if run >= fence {
                        closed = true
                        break
                    }
                    cursor += run
                    continue
                }
                cursor += 1
            }
            if closed, cursor > bodyStart {
                spans.append(String(characters[bodyStart..<cursor]))
                index = cursor + fence
            } else {
                index = bodyStart
            }
        }
        return spans
    }

    /// camelCase, PascalCase, snake_case, dotted — anything shaped like code
    /// rather than like prose.
    static func isIdentifierLike(_ word: some StringProtocol) -> Bool {
        guard word.count >= minimumTermLength else { return false }
        if word.contains("_") || word.contains(".") || word.contains("-") { return true }
        var sawLower = false
        for character in word {
            if character.isUppercase, sawLower { return true }
            if character.isLowercase { sawLower = true }
        }
        // ALLCAPS acronyms are useful too, as long as they are long enough.
        return word.allSatisfy { $0.isUppercase || $0.isNumber }
    }

    /// A capitalised word from the prose — a proper noun, more often than not.
    static func isCapitalised(_ word: some StringProtocol) -> Bool {
        guard let first = word.first, first.isUppercase else { return false }
        guard word.count >= minimumTermLength else { return false }
        return isCommonWord(word.lowercased()) == false
    }

    /// Rejects terms that would be dangerous to correct towards: too short,
    /// numeric, or an ordinary English word the document happens to contain.
    static func isUsableTerm(_ term: String) -> Bool {
        guard term.count >= minimumTermLength else { return false }
        guard term.contains(where: { $0.isLetter }) else { return false }
        guard term.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "." || $0 == "-" }) else {
            return false
        }
        return isCommonWord(term.lowercased()) == false
    }

    /// The words a recogniser gets right and a corrector must never touch.
    ///
    /// Not a dictionary — a blocklist of the ordinary English most likely to sit
    /// one edit away from a piece of jargon. It only has to cover the collisions
    /// that actually happen; anything it misses is still protected by the length,
    /// first-letter and tie rules.
    static func isCommonWord(_ lowered: String) -> Bool {
        commonWords.contains(lowered)
    }

    static let commonWords: Set<String> = [
        "about", "above", "after", "again", "against", "already", "also", "although",
        "always", "among", "another", "any", "anything", "are", "around", "because",
        "been", "before", "being", "below", "best", "better", "between", "both",
        "but", "came", "cannot", "come", "could", "course", "data", "does", "doing",
        "done", "down", "during", "each", "either", "else", "enough", "even", "ever",
        "every", "example", "first", "form", "found", "from", "further", "give",
        "given", "goes", "going", "gone", "good", "great", "have", "having", "here",
        "high", "however", "into", "issue", "just", "keep", "kind", "know", "known",
        "last", "later", "least", "less", "like", "line", "little", "long", "look",
        "made", "make", "many", "maybe", "mean", "means", "might", "more", "most",
        "much", "must", "need", "never", "next", "nothing", "note", "often", "once",
        "only", "other", "others", "over", "part", "people", "perhaps", "place",
        "point", "possible", "problem", "quite", "rather", "read", "really", "right",
        "same", "says", "seem", "seems", "sentence", "several", "should", "show",
        "shown", "side", "since", "small", "some", "something", "sort", "still",
        "such", "sure", "take", "taken", "than", "that", "their", "them", "then",
        "there", "these", "they", "thing", "things", "think", "this", "those",
        "though", "through", "time", "times", "under", "until", "upon", "used",
        "uses", "using", "usually", "very", "want", "well", "were", "what", "when",
        "where", "whether", "which", "while", "with", "within", "without", "word",
        "words", "work", "would", "your"
    ]
}
