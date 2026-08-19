//
//  ImportedPDF.swift
//  Ingest · Import
//
//  What reading an already-rendered PDF tells us. Deliberately not a Core
//  contract type: nothing outside Ingest needs it, and the values it carries
//  end up in `IngestedDocument`, which is the contract.
//

import Foundation

/// Facts extracted from a PDF that arrived already rendered.
public struct ImportedPDF: Sendable, Hashable {

    /// The real page count, from the document itself. `meta.json`'s `pageCount`
    /// is advisory and the two are allowed to disagree
    /// (DocumentMetadata.swift § pageCount).
    public var pageCount: Int

    /// Full text for the search index. Empty for a scanned PDF with no text
    /// layer, which is a normal outcome and not an error.
    public var extractedText: String

    /// The PDF's own `Title` attribute, when it has a usable one. First choice
    /// for the library row (docs/02-spec.md § S1).
    public var metadataTitle: String?

    public init(pageCount: Int, extractedText: String, metadataTitle: String? = nil) {
        self.pageCount = pageCount
        self.extractedText = extractedText
        self.metadataTitle = metadataTitle
    }
}
