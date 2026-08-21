//
//  NoteAutoTitle.swift
//  AppUI · Reader
//
//  Naming a note nobody named.
//
//  A new note is made in one tap and has no title, because asking for one
//  before there is anything on the page is asking at the wrong moment. So it is
//  called "Note" until it can name itself, and the thing it names itself after
//  is the first sentence somebody wrote on page one — read back out of the
//  handwriting recogniser (`HandwritingRecognising`, docs/04-flows.md § F3).
//
//  **It is an enhancement and never a dependency.** Recognition ships in
//  iPadOS 27 and is off in a 26 build, declines pages for reasons nobody will
//  ever care about, and returns nothing at all for a page of diagrams. Every
//  one of those leaves the note called "Note", which is why renaming is one tap
//  away on the page itself and is not hidden behind this.
//

import Foundation

/// Turns the first line of recognised handwriting into a title.
///
/// Pure and total, so the rule can be tested without a Pencil, a recogniser or
/// a device — which is the only part of this that can be tested at all
/// (STYLE.md § 10).
enum NoteAutoTitle {

    /// The longest title this produces, in characters.
    ///
    /// A library row shows roughly this much before it truncates, and a title
    /// is a handle rather than a summary. `Slug.maxLength` is the same number
    /// for the same reason.
    static let maximumLength = 60

    /// Below this, a "sentence" is a stray mark or a recogniser having a guess,
    /// and a note called "a" is worse than a note called "Note".
    static let minimumLength = 2

    /// The characters a sentence can end on. A newline counts: handwriting
    /// often has no full stop at all, and the line break is the sentence.
    private static let terminators: Set<Character> = [".", "!", "?", "\n", "\r"]

    /// The first sentence of `text`, as a title, or nil when there is nothing
    /// worth calling it.
    ///
    /// - Everything up to the first terminator, or the whole of a short note
    ///   that has not reached one yet.
    /// - Runs of whitespace — which recognised handwriting is full of — become
    ///   single spaces.
    /// - A trailing full stop is dropped, because a title is not a sentence. A
    ///   question mark is kept, because dropping it changes what the note is
    ///   about.
    /// - Anything longer than `maximumLength` is cut at the last word boundary
    ///   that fits, and at the character otherwise.
    /// - Returns nil for nothing, whitespace, or fewer than `minimumLength`
    ///   characters. Nil means "leave the name alone", never an error.
    static func title(fromRecognisedInk text: String) -> String? {
        var sentence = ""
        for character in text {
            if terminators.contains(character) {
                // A leading full stop, or a first line that is blank: keep
                // looking rather than stopping on nothing.
                if sentence.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    continue
                }
                if character == "?" || character == "!" {
                    sentence.append(character)
                }
                break
            }
            sentence.append(character)
        }

        let collapsed = sentence
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        guard collapsed.count >= minimumLength else { return nil }
        return truncated(collapsed)
    }

    /// Whether a document with this title has ever been named — by the person
    /// who made it, or by an earlier run of this rule.
    ///
    /// The comparison is against `NoteCreator.untitled`, the name every note is
    /// born with. Somebody who deliberately calls a note "Note" will have it
    /// renamed once by its first sentence, which is the one case this is wrong
    /// about and is a good deal cheaper than a flag on the document for it.
    static func isUnnamed(_ title: String, untitled: String) -> Bool {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
            .caseInsensitiveCompare(untitled) == .orderedSame
    }

    private static func truncated(_ title: String) -> String {
        guard title.count > maximumLength else { return title }
        let cut = String(title.prefix(maximumLength))
        guard let lastSpace = cut.lastIndex(of: " "),
              cut.distance(from: cut.startIndex, to: lastSpace) > maximumLength / 2 else {
            return cut
        }
        return String(cut[cut.startIndex..<lastSpace])
    }
}
