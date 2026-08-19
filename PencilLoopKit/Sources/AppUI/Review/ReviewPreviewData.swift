//
//  ReviewPreviewData.swift
//  AppUI · Review
//
//  Sample values for the Review unit's previews.
//
//  `PreviewEnvironment` supplies inert dependencies but no content, and the
//  review sheet is mostly content: comments in document order, inked pages, and
//  an origin whose return path the resolver has something to say about. This is
//  that content, and nothing here is used outside a `#Preview`.
//

import Foundation
import Core

/// Sample documents, comments and outcomes for the review previews.
enum ReviewPreviewData {

    // MARK: - Identity

    static let documentId = UUID(uuidString: "F7A1C0DE-0000-4000-8000-000000000001") ?? UUID()

    static let folderName = "2026-08-18-auth-refactor-plan"

    static let title = "Auth refactor plan"

    // MARK: - Origins

    /// An origin of the given return-path type, with a session and a thread —
    /// the shape `send-to-reader` writes (docs/06-integrations.md).
    static func origin(_ type: ReturnPathType) -> Origin {
        Origin(
            kind: type == .resume ? .claudeCode : .cowork,
            sessionId: "8f3c1d2a4b",
            threadTitle: "Q3 platform planning",
            returnPath: ReturnPath(type: type, triggerId: "trig_9f2c41")
        )
    }

    /// A document that arrived through the share extension: no conversation to
    /// return to, which is a supported outcome and not a failure.
    static let shareOrigin = Origin(kind: .share)

    /// What the resolver makes of `origin(_:)`.
    static func resolved(_ type: ReturnPathType) -> ResolvedReturnPath {
        PreviewReturnPathResolver().resolve(origin(type))
    }

    /// The awkward case the badge exists for: a resume path whose session id
    /// was never recorded, so context cannot be preserved even though the type
    /// says it can.
    static let resumeWithoutSession = ResolvedReturnPath(
        type: .resume,
        displayName: OriginKind.claudeCode.displayName,
        threadTitle: "Q3 platform planning",
        sessionId: nil,
        triggerId: nil,
        sameThread: false
    )

    // MARK: - Content

    static let comments: [CommentSnapshot] = [
        comment(
            index: 1,
            page: 0,
            y: 0.22,
            quoted: "The migration runs in a single deploy with no dual-write window.",
            text: "No dual-write window means we cannot roll back after cutover — I want a shadow read for a day.",
            source: .voice
        ),
        comment(
            index: 2,
            page: 1,
            y: 0.41,
            quoted: "await refresh(session) // no backoff",
            text: "Infinite retry loop? Needs exponential backoff and a cap.",
            source: .handwriting
        ),
        comment(
            index: 3,
            page: 2,
            y: 0.63,
            quoted: "Estimated at four days of work across the two services.",
            text: "Does not include the mobile SDK check — closer to a week.",
            source: .typed
        )
    ]

    static let pages: [PageSnapshot] = [
        PageSnapshot(pageIndex: 0, drawingData: Data(), recognisedInk: nil, hasInk: false),
        PageSnapshot(
            pageIndex: 1,
            drawingData: Data("ink".utf8),
            recognisedInk: "needs backoff",
            hasInk: true
        ),
        PageSnapshot(
            pageIndex: 2,
            drawingData: Data("ink".utf8),
            recognisedInk: "closer to a week",
            hasInk: true
        ),
        PageSnapshot(pageIndex: 3, drawingData: nil, recognisedInk: nil, hasInk: false)
    ]

    static func detail(origin: Origin, comments: [CommentSnapshot] = ReviewPreviewData.comments) -> DocumentDetail {
        DocumentDetail(
            id: documentId,
            title: title,
            folderName: folderName,
            pdfURL: URL(fileURLWithPath: "/dev/null"),
            sourceMarkdownURL: nil,
            sourceMap: nil,
            pageCount: pages.count,
            state: .reviewing,
            origin: origin,
            addedAt: Date(timeIntervalSince1970: 1_787_000_000),
            lastReadPage: 1,
            extractedText: "",
            pages: pages,
            comments: comments
        )
    }

    // MARK: - Models

    /// A sheet in its composing state.
    static func model(
        origin: Origin,
        comments: [CommentSnapshot] = ReviewPreviewData.comments,
        readingSeconds: TimeInterval? = nil
    ) -> ReviewSheetModel {
        ReviewSheetModel(
            document: detail(origin: origin, comments: comments),
            previewReadingSeconds: readingSeconds
        )
    }

    /// A sheet already showing the Sent screen.
    static func sentModel(
        pathType: ReturnPathType,
        delivery: ReviewSentOutcome.Delivery,
        reply: ReviewSentOutcome.Reply? = nil
    ) -> ReviewSheetModel {
        let path = pathType == .none ? ResolvedReturnPath.unresolved : resolved(pathType)
        let outcome = ReviewSentOutcome(
            documentId: documentId,
            documentTitle: title,
            path: path,
            directoryName: OutboxPayload.directoryName(forDocumentFolder: folderName),
            payload: payload,
            builtAt: Date(),
            delivery: delivery,
            reply: reply
        )
        return ReviewSheetModel(
            document: detail(origin: pathType == .none ? shareOrigin : origin(pathType)),
            previewOutcome: outcome
        )
    }

    /// A bundle with the right shape and a readable `review.md`, so "Copy
    /// review" and the share sheet have something to hand over in a preview.
    static let payload = OutboxPayload(
        directoryName: OutboxPayload.directoryName(forDocumentFolder: folderName),
        documentId: documentId,
        files: [
            BundleFile(relativePath: DocumentFileNames.reviewMarkdown, data: Data(markdown.utf8)),
            BundleFile(relativePath: ReviewBundle.fileName, data: Data("{}".utf8)),
            BundleFile(relativePath: InkImage.fileName(forPageIndex: 1), data: Data()),
            BundleFile(relativePath: InkImage.fileName(forPageIndex: 2), data: Data()),
            BundleFile(relativePath: BundleManifest.fileName, data: Data("{}".utf8))
        ]
    )

    private static let markdown = """
    # Review — Auth refactor plan

    ## What I want done

    Rework phase 2 with the shadow read, then re-scope the estimate.
    """

    // MARK: - Helpers

    private static func comment(
        index: Int,
        page: Int,
        y: Double,
        quoted: String,
        text: String,
        source: CommentSource
    ) -> CommentSnapshot {
        CommentSnapshot(
            id: UUID(uuidString: "C0FFEE00-0000-4000-8000-00000000000\(index)") ?? UUID(),
            createdAt: Date(timeIntervalSince1970: 1_787_000_000 + Double(index * 60)),
            text: text,
            source: source,
            anchor: Anchor(
                quoted: quoted,
                prefix: "",
                suffix: "",
                pageIndex: page,
                normalisedRect: NormalisedRect(x: 0.12, y: y, width: 0.7, height: 0.03),
                sourceRange: nil
            ),
            resolvedOnPage: page
        )
    }
}
