//
//  AppUITestSamples.swift
//  AppUITests
//
//  The values every test here builds on. One file so that four test cases do not
//  each invent a slightly different comment.
//

import CoreGraphics
import Foundation
import Core

/// Sample DTOs for the AppUI tests.
enum AppUITestSamples {

    /// A page rect roughly the shape of the only geometry v1 ships: A4 portrait,
    /// laid out somewhere that is not the origin, because a layout that only
    /// works at (0, 0) is a layout that is wrong on screen.
    static let pageRect = CGRect(x: 24, y: 40, width: 420, height: 594)

    /// A comment on `page`, whose anchor sits `y` of the way down it.
    ///
    /// - Parameters:
    ///   - ordinal: makes the id and the creation time, so a test can assert on
    ///     order without depending on UUID's own ordering.
    ///   - y: normalised, top-left origin, y down (NormalisedRect.swift).
    static func comment(
        _ ordinal: Int,
        y: Double,
        page: Int = 0,
        text: String = "A comment.",
        source: CommentSource = .voice,
        createdAtOffset: TimeInterval? = nil
    ) -> CommentSnapshot {
        CommentSnapshot(
            id: id(ordinal),
            createdAt: Date(timeIntervalSince1970: 1_787_000_000 + (createdAtOffset ?? Double(ordinal))),
            text: text,
            source: source,
            anchor: Anchor(
                quoted: text,
                pageIndex: page,
                normalisedRect: NormalisedRect(x: 0.12, y: y, width: 0.7, height: 0.02)
            ),
            resolvedOnPage: page
        )
    }

    /// The document the review tests send.
    ///
    /// It has a `pdfURL` because `ReviewSheetModel.canSend` requires one — a
    /// document with no local file has nothing to build a bundle from — and the
    /// file itself is never opened: `PreviewReviewBundleBuilder` returns an
    /// empty payload without reading anything.
    static func detail(comments: [CommentSnapshot] = []) -> DocumentDetail {
        DocumentDetail(
            id: id(99),
            title: "Auth refactor plan",
            folderName: "2026-08-18-auth-refactor-plan",
            externalId: "doc_9f2c41",
            pdfURL: URL(fileURLWithPath: "/tmp/container/2026-08-18-auth-refactor-plan/document.pdf"),
            pageCount: 4,
            state: .reviewing,
            origin: Origin(kind: .cowork),
            addedAt: Date(timeIntervalSince1970: 1_787_000_000),
            lastReadPage: 0,
            extractedText: "The auth refactor plan.",
            pages: [],
            comments: comments
        )
    }

    /// A stable, readable id per ordinal: `C0FFEE00-…-0000000000NN`.
    static func id(_ ordinal: Int) -> UUID {
        let suffix = String(format: "%012d", ordinal)
        return UUID(uuidString: "C0FFEE00-0000-4000-8000-\(suffix)") ?? UUID()
    }

    /// One library row, with the parts `LibraryFormat` assembles.
    static func summary(
        title: String = "Auth refactor plan",
        originDisplayName: String = "Cowork",
        addedAt: Date,
        pageCount: Int = 4,
        state: DocState = .unread,
        localState: DocumentLocalState = .local,
        commentCount: Int = 0,
        hasInk: Bool = false,
        refreshFailureReason: String? = nil
    ) -> DocumentSummary {
        DocumentSummary(
            id: id(99),
            title: title,
            originDisplayName: originDisplayName,
            addedAt: addedAt,
            pageCount: pageCount,
            state: state,
            localState: localState,
            commentCount: commentCount,
            hasInk: hasInk,
            folderName: "2026-08-18-auth-refactor-plan",
            refreshFailureReason: refreshFailureReason
        )
    }
}
