//
//  MarkdownFallback.swift
//  Ingest · Adapters
//
//  What to render when the parser will not.
//
//  docs/04-flows.md § F1: "a document that can't be rendered shows in the
//  library with an error row rather than vanishing." The strongest form of that
//  promise is not to need the error row at all — a document whose markdown
//  cannot be parsed is still a document full of text, and showing that text
//  verbatim is better than showing a failure. `MarkdownParsing`'s contract says
//  the same thing: "fall back to rendering the raw text as a single
//  preformatted block."
//

import Foundation
import Core

/// Builds a renderable document out of text the parser could not handle.
public enum MarkdownFallback {

    /// The whole source as one preformatted block.
    ///
    /// The block's `sourceRange` covers the entire file — and so does its
    /// `contentRange`, because there are no fences to exclude when the whole
    /// file *is* the content. The source map is
    /// coarse but never wrong: every comment anchored on the page resolves to
    /// the document rather than to a passage. That is the honest answer when
    /// nothing finer is known.
    public static func preformatted(_ markdown: String) -> MarkdownDocument {
        guard !markdown.isEmpty else {
            return MarkdownDocument(source: markdown, blocks: [], title: nil)
        }
        let block = MarkdownBlock.codeBlock(
            language: nil,
            code: markdown,
            contentRange: SourceRange.whole(of: markdown),
            sourceRange: SourceRange.whole(of: markdown)
        )
        return MarkdownDocument(source: markdown, blocks: [block], title: headingLine(in: markdown))
    }

    /// The first `# ` line, if the file starts like a document with a title.
    /// Cheap enough to be worth trying even when the parse failed, because the
    /// library row is nicer with a real title than with a filename.
    static func headingLine(in markdown: String) -> String? {
        for line in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("# ") else {
                if trimmed.isEmpty { continue }
                return nil
            }
            let title = trimmed.dropFirst(2).trimmingCharacters(in: .whitespaces)
            return title.isEmpty ? nil : title
        }
        return nil
    }
}
