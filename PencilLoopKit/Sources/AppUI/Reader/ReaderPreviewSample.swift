//
//  ReaderPreviewSample.swift
//  AppUI · Reader
//
//  A real, tiny PDF for `#Preview`. Without one there is nothing to preview:
//  every other screen in the app can be previewed from a value, but a PDF
//  reader with no PDF is a grey rectangle.
//
//  It renders with `UIGraphicsPDFRenderer` at `PageGeometry.annotationFriendly`
//  — the same geometry Ingest uses — so what a preview shows is the real page
//  shape, including the 140pt right margin that the whole design rests on
//  (docs/03-architecture.md § 1).
//

import CoreGraphics
import Foundation
import UIKit
import Core

/// Sample data for the reader's previews.
///
/// **On failure:** if the temporary file cannot be written, `detail()` comes
/// back with a nil `pdfURL`, and the preview shows the reader's unavailable
/// state — which is itself a state worth looking at.
enum ReaderPreviewSample {

    /// Stable across previews so a restored reading position means something.
    static let documentId = UUID(uuidString: "F7A1C0DE-0000-4000-8000-0000000000A1") ?? UUID()

    /// The sentence the sample pages are built around, so anchor capture has
    /// something recognisable to quote in a preview.
    static let sampleSentence = "The migration runs in a single deploy, with no dual-write window."

    /// A three-page document with one comment on the first page.
    static func detail(pageCount: Int = 3, lastReadPage: Int = 0) -> DocumentDetail {
        let text = ReaderPreviewSample.text(pageCount: pageCount)
        return DocumentDetail(
            id: ReaderPreviewSample.documentId,
            title: "Auth refactor plan",
            folderName: "2026-08-18-auth-refactor-plan",
            pdfURL: ReaderPreviewSample.makeDocument(pageCount: pageCount),
            pageCount: pageCount,
            state: .reviewing,
            origin: .manual,
            addedAt: Date(timeIntervalSince1970: 1_787_000_000),
            lastReadPage: lastReadPage,
            extractedText: text,
            pages: (0..<pageCount).map { PageSnapshot(pageIndex: $0) },
            comments: [ReaderPreviewSample.comment]
        )
    }

    /// One comment, so a preview has a marker in the margin.
    static let comment = CommentSnapshot(
        id: UUID(uuidString: "F7A1C0DE-0000-4000-8000-0000000000B1") ?? UUID(),
        createdAt: Date(timeIntervalSince1970: 1_787_000_100),
        text: "Is a single deploy safe here without a dual-write window?",
        source: .voice,
        anchor: Anchor(
            quoted: ReaderPreviewSample.sampleSentence,
            pageIndex: 0,
            normalisedRect: NormalisedRect(x: 0.09, y: 0.22, width: 0.6, height: 0.02)
        ),
        resolvedOnPage: 0
    )

    // MARK: - Support

    private static func text(pageCount: Int) -> String {
        (0..<pageCount)
            .map { ReaderPreviewSample.pageText(index: $0) }
            .joined(separator: "\n\n")
    }

    private static func pageText(index: Int) -> String {
        """
        Phase \(index + 1) — Session and token handling

        \(ReaderPreviewSample.sampleSentence) We replace the existing \
        cookie-based session with short-lived access tokens and a rotating \
        refresh token stored in the keychain.

        The auth service already exposes a rotate endpoint, and every client is \
        on SDK v4 or later. Older clients fail closed and prompt a reinstall.
        """
    }

    /// Renders the sample and returns where it landed, or nil.
    private static func makeDocument(pageCount: Int) -> URL? {
        let geometry = PageGeometry.annotationFriendly
        let bounds = CGRect(x: 0, y: 0, width: geometry.pageWidth, height: geometry.pageHeight)
        let textFrame = CGRect(
            x: geometry.marginLeft,
            y: geometry.marginTop,
            width: geometry.textColumnWidth,
            height: geometry.textColumnHeight
        )
        let renderer = UIGraphicsPDFRenderer(bounds: bounds)
        let data = renderer.pdfData { context in
            for index in 0..<pageCount {
                context.beginPage()
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: UIFont.systemFont(ofSize: geometry.bodyPointSize),
                    .foregroundColor: UIColor.black
                ]
                NSAttributedString(
                    string: ReaderPreviewSample.pageText(index: index),
                    attributes: attributes
                ).draw(in: textFrame)
            }
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pencil-loop-reader-preview.pdf")
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            return nil
        }
        return url
    }
}
