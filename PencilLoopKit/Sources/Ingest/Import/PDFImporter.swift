//
//  PDFImporter.swift
//  Ingest · Import
//
//  The other half of ingest: documents that arrive already as PDF — a paper
//  from arXiv, a report from the share extension, anything a person dropped in
//  the folder (docs/04-flows.md § F1, docs/06-integrations.md § Share
//  extension).
//
//  There is nothing to render and no source map to build. What is left is the
//  three facts the library and the search index need: how many pages, what it
//  says, and what it is called.
//

import Foundation
import PDFKit
import Core

/// Reads an already-rendered PDF.
public struct PDFImporter: Sendable {

    public init() {}

    /// Opens the PDF and extracts its page count, text and title.
    ///
    /// - Parameters:
    ///   - url: a file already inside the app container. Reading a
    ///     file-provider placeholder is not this type's job — materialise
    ///     first (CLAUDE.md non-negotiable 2).
    ///   - folderName: only used to name the folder in the error, so the
    ///     library's error row can say which document failed.
    /// - Throws: `PencilLoopError.unreadableDocument` when PDFKit will not open
    ///   the file, when it is encrypted and locked, or when it has no pages. A
    ///   PDF with pages but no text layer is *not* an error: it returns an empty
    ///   `extractedText` and stays perfectly readable.
    public func read(pdfAt url: URL, folderName: String) throws -> ImportedPDF {
        guard let document = PDFDocument(url: url) else {
            throw PencilLoopError.unreadableDocument(
                folderName: folderName,
                reason: "The file is not a PDF this device can open."
            )
        }
        if document.isEncrypted, document.isLocked {
            throw PencilLoopError.unreadableDocument(
                folderName: folderName,
                reason: "The PDF is password protected."
            )
        }
        guard document.pageCount > 0 else {
            throw PencilLoopError.unreadableDocument(
                folderName: folderName,
                reason: "The PDF contains no pages."
            )
        }

        return ImportedPDF(
            pageCount: document.pageCount,
            extractedText: text(of: document),
            metadataTitle: title(of: document)
        )
    }

    /// Reading order, one page per paragraph. Page by page rather than
    /// `PDFDocument.string` so a single unreadable page costs one page of the
    /// search index instead of all of them.
    private func text(of document: PDFDocument) -> String {
        var pages: [String] = []
        for index in 0 ..< document.pageCount {
            guard let page = document.page(at: index), let text = page.string else { continue }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { pages.append(trimmed) }
        }
        return pages.joined(separator: "\n\n")
    }

    private func title(of document: PDFDocument) -> String? {
        let attributes = document.documentAttributes ?? [:]
        guard let raw = attributes[PDFDocumentAttribute.titleAttribute] as? String else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Writers leave "untitled" and the source filename in here constantly;
        // an empty title is better than a wrong one, because the fallback chain
        // has a real answer waiting behind it.
        guard !trimmed.isEmpty, trimmed.lowercased() != "untitled" else { return nil }
        return trimmed
    }
}
