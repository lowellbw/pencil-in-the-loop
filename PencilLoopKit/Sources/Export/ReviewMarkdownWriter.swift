//
//  ReviewMarkdownWriter.swift
//  Export
//
//  `review.md`, the primary payload. Written for a model to read: prose, not a
//  data structure (docs/05-file-contracts.md § review.md).
//
//  The golden target is contracts/fixtures/review.md, transcribed byte for byte
//  from the fenced block in docs/05. Every structural decision below — the title
//  line, the reviewed-at line and its counts, the origin line, the numbered
//  comments with a blockquoted excerpt and an italic source line, the
//  handwritten-pages paragraph, the closing paragraph — is that fixture's, not
//  this unit's.
//
//  Prose is hard-wrapped at 85 characters, which is the width the fixture wraps
//  at and the only width that reproduces all four of its wrapped paragraphs.
//

import Foundation
import Core

/// Renders a `ReviewDraft` as `review.md`.
///
/// Pure and synchronous: the same draft always produces the same bytes, which
/// is what lets the output be diffed against contracts/fixtures/review.md.
///
/// **On failure:** there is none. Every field degrades — an empty closing
/// instruction drops its section, no comments drops the comment section, no ink
/// drops the handwritten-pages section — and the closing paragraph is always
/// written, because it is the sentence that tells the reader how to resolve an
/// anchor and docs/05 says it measurably improves how reliably edits land.
public struct ReviewMarkdownWriter: Sendable {

    /// Hard-wrap column for generated prose.
    ///
    /// 85 is not arbitrary: it is the only width at which greedy wrapping
    /// reproduces every wrapped paragraph in contracts/fixtures/review.md.
    public static let wrapWidth = 85

    /// The closing paragraph, verbatim from docs/05-file-contracts.md.
    ///
    /// Not decoration. It tells the model to match on the quote rather than on a
    /// line number, which is the whole reason anchors are quoted text
    /// (CLAUDE.md non-negotiable 5).
    public static let anchorInstruction = """
        Each quoted excerpt is exact text from the document you produced. Match on the \
        quote, not on a line number — the document may have changed since.
        """

    /// The paragraph that explains what the ink images mean, minus the sentence
    /// naming the pages, which is generated.
    static let inkGuidance = """
        Position carries meaning — arrows and circles refer to the text they point at, \
        and a strikethrough means delete. Read them alongside the comments above rather \
        than instead of them.
        """

    /// Fixed-format dates need a fixed locale, or a reader whose device is set
    /// to 12-hour time gets `9:14 pm` out of `HH:mm`.
    public static let formattingLocale = Locale(identifier: "en_US_POSIX")

    /// `18 Aug 2026, 21:14`.
    public static let dateFormat = "d MMM yyyy, HH:mm"

    private let timeZone: TimeZone
    private let locale: Locale

    /// - Parameters:
    ///   - timeZone: the zone the reviewed-at line is rendered in. Defaults to
    ///     the device's, because the line is read by a person as often as by a
    ///     model and "21:14" should mean the time they pressed Send.
    ///   - locale: fixed-format formatting locale. Change it only in a test.
    public init(
        timeZone: TimeZone = .current,
        locale: Locale = ReviewMarkdownWriter.formattingLocale
    ) {
        self.timeZone = timeZone
        self.locale = locale
    }

    // MARK: - Rendering

    /// The whole of `review.md`.
    ///
    /// - Parameters:
    ///   - draft: what the review sheet collected.
    ///   - comments: the numbered comments, already in document order with their
    ///     anchors re-resolved. Empty when the user turned Comments off.
    ///   - inkPages: the pages that actually produced an image. Passing the
    ///     rendered pages rather than the draft's inked pages is what keeps
    ///     `review.md` and `review.json` naming the same files when one page
    ///     failed to crop.
    ///   - resolutions: which rung of the ladder resolved each comment, keyed by
    ///     `ReviewComment.id`. A `.rectFallback` earns an "approximate" note on
    ///     that comment's source line; every other rung is silent.
    /// - Returns: markdown text ending in a single newline.
    public func markdown(
        for draft: ReviewDraft,
        comments: [ReviewComment] = [],
        inkPages: [ReviewInkPage] = [],
        resolutions: [String: AnchorResolution] = [:]
    ) -> String {
        var lines: [String] = []

        lines.append("# Review — " + Prose.singleLine(draft.documentTitle))
        lines.append("")
        lines.append(reviewedLine(for: draft, comments: comments, inkPages: inkPages))
        lines.append(originLine(for: draft.origin))

        let closing = draft.closingInstruction.trimmingCharacters(in: .whitespacesAndNewlines)
        if !closing.isEmpty {
            lines.append("")
            lines.append("## What I want done")
            lines.append("")
            lines.append(Prose.wrap(closing))
        }

        if !comments.isEmpty {
            lines.append("")
            lines.append("## Comments")
            for comment in comments {
                lines.append(contentsOf: section(for: comment, resolution: resolutions[comment.id]))
            }
        }

        if !inkPages.isEmpty {
            lines.append(contentsOf: handwrittenSection(for: inkPages))
        }

        lines.append("")
        lines.append("## How to locate these passages")
        lines.append("")
        lines.append(Prose.wrap(ReviewMarkdownWriter.anchorInstruction))

        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: - The header

    /// `Reviewed 18 Aug 2026, 21:14 · 3 comments · 2 inked pages`.
    ///
    /// The counts describe what is in this file: a review sent with Comments
    /// turned off does not claim comments it did not send.
    func reviewedLine(
        for draft: ReviewDraft,
        comments: [ReviewComment],
        inkPages: [ReviewInkPage]
    ) -> String {
        var parts = ["Reviewed " + formatted(draft.reviewedAt)]
        if draft.include.comments {
            parts.append(Prose.count(comments.count, one: "comment", many: "comments"))
        }
        if !inkPages.isEmpty {
            parts.append(Prose.count(inkPages.count, one: "inked page", many: "inked pages"))
        }
        return parts.joined(separator: " · ")
    }

    /// `Origin: Cowork · "Q3 platform planning" · session 8f3c1d`.
    ///
    /// Always written, even for a manually added document, because a reader who
    /// cannot see where a review came from cannot tell whether replying to it
    /// will reach anyone.
    func originLine(for origin: Origin) -> String {
        var parts = [origin.kind.displayName]
        if let title = origin.threadTitle, !title.isEmpty {
            parts.append("\"" + Prose.singleLine(title) + "\"")
        }
        if let session = Prose.shortIdentifier(origin.sessionId) {
            parts.append("session " + session)
        }
        return "Origin: " + parts.joined(separator: " · ")
    }

    private func formatted(_ date: Date) -> String {
        // A fresh formatter per call: DateFormatter is not Sendable, and a
        // review is written once, not once per frame.
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.dateFormat = ReviewMarkdownWriter.dateFormat
        return formatter.string(from: date)
    }

    // MARK: - Sections

    /// One numbered comment: heading, blockquoted excerpt, the comment itself,
    /// and the italic source line.
    private func section(for comment: ReviewComment, resolution: AnchorResolution?) -> [String] {
        var lines: [String] = []

        lines.append("")
        lines.append("### \(comment.index) — page \(comment.anchor.pageIndex + 1)")

        let quoted = comment.anchor.quoted
        if !quoted.isEmpty {
            lines.append("")
            lines.append(contentsOf: Prose.blockquote(quoted))
        }

        let text = comment.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty {
            lines.append("")
            lines.append(Prose.wrap(text))
        }

        lines.append("")
        lines.append(Prose.wrap("*" + attribution(for: comment, resolution: resolution) + "*"))
        return lines
    }

    /// The italic line under a comment. `CommentSource.attribution` is frozen in
    /// Core so the exported prose cannot drift; the approximate note is appended
    /// only for a rect fallback, which every consumer has to describe as
    /// approximate (docs/05-file-contracts.md).
    private func attribution(for comment: ReviewComment, resolution: AnchorResolution?) -> String {
        var text = comment.source.attribution
        if let resolution, case .rectFallback = resolution {
            text += " · position approximate — this passage no longer matches the document, "
            text += "so the mark is placed by where it sits on the page"
        }
        return text
    }

    /// The handwritten-pages section, including any recognised text.
    private func handwrittenSection(for inkPages: [ReviewInkPage]) -> [String] {
        var lines: [String] = []
        lines.append("")
        lines.append("## Handwritten pages")
        lines.append("")

        let numbers = inkPages.map { String($0.pageIndex + 1) }
        let files = inkPages.map { "`" + $0.image + "`" }.joined(separator: ", ")
        let lead = numbers.count == 1
            ? "Page " + Prose.list(numbers) + " has"
            : "Pages " + Prose.list(numbers) + " have"

        lines.append(Prose.wrap(
            lead + " handwritten marks attached as images: " + files + ". "
                + ReviewMarkdownWriter.inkGuidance
        ))

        // Recognition is an enhancement, never a replacement: the images are
        // authoritative and the text is offered underneath them.
        for page in inkPages {
            let recognised = (page.recognisedText ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !recognised.isEmpty else { continue }
            lines.append("")
            lines.append("Recognised handwriting, page \(page.pageIndex + 1):")
            lines.append("")
            lines.append(contentsOf: Prose.blockquote(recognised))
        }
        return lines
    }

    // MARK: - Prose

    /// Text shaping. Nested because nothing outside this file should be tempted
    /// to re-wrap a review.
    enum Prose {

        /// Greedy wrap at `ReviewMarkdownWriter.wrapWidth`, preserving blank-line
        /// paragraph breaks and collapsing every other run of whitespace.
        ///
        /// Collapsing is safe here and only here: this is generated prose, not a
        /// quoted excerpt. Excerpts go through `blockquote(_:)`, which changes
        /// nothing.
        static func wrap(_ text: String, width: Int = ReviewMarkdownWriter.wrapWidth) -> String {
            let paragraphs = text
                .replacingOccurrences(of: "\r\n", with: "\n")
                .components(separatedBy: "\n\n")
            var rendered: [String] = []

            for paragraph in paragraphs {
                let words = paragraph.split(whereSeparator: { $0.isWhitespace || $0.isNewline })
                guard !words.isEmpty else { continue }

                var lines: [String] = []
                var current = ""
                for word in words {
                    if current.isEmpty {
                        current = String(word)
                    } else if current.count + 1 + word.count <= width {
                        current += " " + word
                    } else {
                        lines.append(current)
                        current = String(word)
                    }
                }
                lines.append(current)
                rendered.append(lines.joined(separator: "\n"))
            }
            return rendered.joined(separator: "\n\n")
        }

        /// A quoted excerpt as a markdown blockquote, verbatim.
        ///
        /// One `> ` per line and no re-wrapping: docs/05 promises the reader that
        /// "each quoted excerpt is exact text from the document you produced",
        /// and a quote this writer reflowed is not that. The run of spaces in the
        /// fixture's `await refresh(session)   // no backoff` is the test of it.
        static func blockquote(_ text: String) -> [String] {
            text
                .replacingOccurrences(of: "\r\n", with: "\n")
                .components(separatedBy: "\n")
                .map { $0.isEmpty ? ">" : "> " + $0 }
        }

        /// `3 comments`, `1 comment`.
        static func count(_ value: Int, one: String, many: String) -> String {
            "\(value) " + (value == 1 ? one : many)
        }

        /// `1`, `1 and 3`, `1, 3 and 7`.
        static func list(_ items: [String]) -> String {
            guard let last = items.last else { return "" }
            guard items.count > 1 else { return last }
            let leading = items.dropLast()
            return leading.joined(separator: ", ") + " and " + last
        }

        /// Whitespace collapsed onto one line, for anything that has to sit
        /// inside a heading or between quotation marks.
        static func singleLine(_ text: String) -> String {
            AnchorResolver.normalisedWhitespace(text)
        }

        /// A session id, abbreviated for display.
        ///
        /// The authoritative value stays in `meta.json`; this is a hint that
        /// lets a reader tell one thread from another. A trailing ellipsis is
        /// dropped first because the ids in docs/05 and its fixtures carry one —
        /// no real session id ends in a character that means "and so on".
        static func shortIdentifier(_ identifier: String?, maxLength: Int = 12) -> String? {
            guard let identifier else { return nil }
            var trimmed = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
            while trimmed.hasSuffix("\u{2026}") || trimmed.hasSuffix(".") {
                trimmed = String(trimmed.dropLast())
            }
            guard !trimmed.isEmpty else { return nil }
            guard trimmed.count > maxLength else { return trimmed }
            return String(trimmed.prefix(maxLength)) + "\u{2026}"
        }
    }
}
