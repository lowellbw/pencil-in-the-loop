//
//  MetadataExtractor.swift
//  Ingest · Import
//
//  Title and page count.
//
//  This file used to build the speech term list too — the same signature as
//  `TranscriptCorrecting.terms(forDocumentText:title:)`, with a second
//  implementation behind it. There is one implementation now, `TermListCorrector`
//  in Annotate, which is the type that actually conforms to that protocol. The
//  terms are derived when the popover opens, from `DocumentDetail.extractedText`
//  and the title, rather than carried on a DTO: they are cheap, they are wanted
//  for the length of one recording, and a copy computed at ingest would be stale
//  the moment the document was re-sent.
//
//  All of it pure: no file handles, no PDFKit, nothing that needs a document on
//  disk. The inputs come from `PDFImporter`, `SwiftMarkdownAdapter` and
//  `meta.json`; the decisions live here so there is one place that knows what
//  the title precedence actually is, and one place to test it.
//

import Foundation
import Core

/// Decides a document's title and page count.
public struct MetadataExtractor: Sendable {

    public init() {}

    // MARK: - meta.json

    /// Reads `meta.json` bytes.
    ///
    /// **Never throws.** A truncated file, a file that is not JSON at all, or
    /// one written by a tool that got the schema wrong all yield
    /// `DocumentMetadata.empty`, and ingest carries on with the documented
    /// fallbacks (docs/04-flows.md § F1).
    public func metadata(fromMetaJSON data: Data) -> DocumentMetadata {
        guard let decoded = try? ContractCoding.decoder().decode(DocumentMetadata.self, from: data) else {
            return .empty
        }
        return decoded
    }

    // MARK: - Title

    /// The title, in the frozen order of preference.
    ///
    /// `meta.json` first, because a writing tool that bothered to name the
    /// document knows best. Then the PDF's own `Title` attribute, then the
    /// markdown H1, then the filename (DocumentMetadata.swift § title,
    /// docs/02-spec.md § S1). Every candidate is trimmed, and an empty one is
    /// skipped rather than winning.
    ///
    /// - Returns: never an empty string. A document with no usable name
    ///   anywhere is called "Document", because a library row with no title is
    ///   a row nobody can tap with confidence.
    public func title(
        metadataTitle: String?,
        pdfTitle: String?,
        markdownTitle: String?,
        fileName: String
    ) -> String {
        for candidate in [metadataTitle, pdfTitle, markdownTitle] {
            if let usable = usable(candidate) { return usable }
        }
        if let usable = usable(readableName(fromFileName: fileName)) { return usable }
        return "Document"
    }

    /// Turns `2026-08-18-auth-refactor-plan` or `auth_refactor_plan.pdf` into
    /// "Auth refactor plan".
    public func readableName(fromFileName fileName: String) -> String {
        var stem = fileName
        if let dot = stem.lastIndex(of: "."), dot != stem.startIndex {
            stem = String(stem[stem.startIndex ..< dot])
        }
        if let split = Slug.split(folderName: stem) {
            stem = split.slug
        }
        let words = stem
            .split(whereSeparator: { $0 == "-" || $0 == "_" || $0.isWhitespace })
            .map(String.init)
        guard let first = words.first else { return "" }
        let capitalised = first.prefix(1).uppercased() + first.dropFirst()
        return ([capitalised] + words.dropFirst()).joined(separator: " ")
    }

    // MARK: - Page count

    /// The page count to store.
    ///
    /// The rendered or imported document wins; `meta.json`'s value is a claim by
    /// the writing tool and the two are allowed to disagree
    /// (DocumentMetadata.swift § pageCount). The claim is only used when the
    /// real count is missing, which should not happen.
    public func pageCount(measured: Int, claimed: Int?) -> Int {
        if measured > 0 { return measured }
        guard let claimed, claimed > 0 else { return 0 }
        return claimed
    }

    // MARK: - Private

    private func usable(_ candidate: String?) -> String? {
        guard let candidate else { return nil }
        let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
