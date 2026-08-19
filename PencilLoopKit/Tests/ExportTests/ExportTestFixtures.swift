//
//  ExportTestFixtures.swift
//  ExportTests
//
//  Shared inputs. One namespace rather than a helper on each test case, so that
//  the draft the golden-fixture test uses is visibly the same draft the bundle
//  builder test uses.
//

import Foundation
import Core
@testable import Export

/// Inputs for the Export tests, including a reconstruction of the document
/// behind contracts/fixtures/review.md.
enum ExportTestFixtures {

    // MARK: - The repo

    /// The repository root, found from this file rather than from a bundle
    /// resource: `Package.swift` declares no resources for `ExportTests`, and
    /// copying the golden fixture into the test would create the second copy
    /// this project exists to avoid.
    static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)          // …/Tests/ExportTests/ExportTestFixtures.swift
            .deletingLastPathComponent()         // …/Tests/ExportTests
            .deletingLastPathComponent()         // …/Tests
            .deletingLastPathComponent()         // …/PencilLoopKit
            .deletingLastPathComponent()         // repo root
    }

    static var goldenReviewMarkdown: URL {
        repositoryRoot
            .appendingPathComponent("contracts")
            .appendingPathComponent("fixtures")
            .appendingPathComponent("review.md")
    }

    // MARK: - The document behind the fixture

    /// `2026-08-18T21:14:00Z`, the `reviewedAt` in contracts/fixtures/review.json.
    static let reviewedAt = Date(timeIntervalSince1970: 1_787_087_640)

    static let folderName = "2026-08-18-auth-refactor-plan"
    static let documentTitle = "Auth refactor plan"
    static let externalDocumentId = "F7A1\u{2026}"

    static let coworkOrigin = Origin(
        kind: .cowork,
        sessionId: "8f3c1d\u{2026}",
        threadTitle: "Q3 platform planning",
        returnPath: ReturnPath(type: .poke, triggerId: "trig_\u{2026}")
    )

    static let closingInstruction = "Rework phase 2 with the shadow read, then re-scope the estimate."

    /// The first comment from contracts/fixtures/review.json, with the full
    /// text `review.md` shows rather than the elided text `review.json` shows.
    static func firstComment() -> CommentSnapshot {
        CommentSnapshot(
            id: uuid(1),
            createdAt: reviewedAt,
            text: "No dual-write window means we can't roll back after cutover \u{2014} "
                + "I want a shadow read for at least a day.",
            source: .voice,
            anchor: Anchor(
                quoted: "The migration runs in a single deploy, with no dual-write window.",
                prefix: "\u{2026}refresh token stored in the keychain. ",
                suffix: " Rollout is gated behind auth_v2\u{2026}",
                pageIndex: 0,
                normalisedRect: NormalisedRect(x: 0.12, y: 0.34, width: 0.76, height: 0.04),
                sourceRange: SourceRange(start: 1204, end: 1268)
            ),
            resolvedOnPage: 0
        )
    }

    static func secondComment() -> CommentSnapshot {
        CommentSnapshot(
            id: uuid(2),
            createdAt: reviewedAt,
            text: "Infinite retry loop? Needs exponential backoff and a cap.",
            source: .handwriting,
            anchor: Anchor(
                quoted: "await refresh(session)   // no backoff",
                prefix: "",
                suffix: "",
                pageIndex: 1,
                normalisedRect: NormalisedRect(x: 0.14, y: 0.51, width: 0.6, height: 0.03)
            ),
            resolvedOnPage: 1
        )
    }

    /// Ink on pages 1 and 3, one-based — `pageIndex` 0 and 2.
    static func inkPages() -> [ReviewInkPage] {
        [
            ReviewInkPage(pageIndex: 0, image: InkImage.fileName(forPageIndex: 0)),
            ReviewInkPage(pageIndex: 2, image: InkImage.fileName(forPageIndex: 2))
        ]
    }

    /// The comments as `review.json` numbers them.
    static func reviewComments() -> [ReviewComment] {
        ReviewJSONWriter().comments(for: draft())
    }

    /// A draft matching contracts/fixtures/review.md as closely as the fixture
    /// allows. See `ReviewMarkdownWriterTests` for the one place it cannot.
    static func draft(
        comments: [CommentSnapshot]? = nil,
        pages: [PageSnapshot] = [],
        include: ReviewIncludeOptions = .standard,
        closingInstruction: String = ExportTestFixtures.closingInstruction,
        origin: Origin = ExportTestFixtures.coworkOrigin,
        sourceMarkdownURL: URL? = nil,
        pdfURL: URL = URL(fileURLWithPath: "/dev/null")
    ) -> ReviewDraft {
        ReviewDraft(
            documentId: uuid(9),
            externalDocumentId: externalDocumentId,
            documentTitle: documentTitle,
            folderName: folderName,
            pdfURL: pdfURL,
            sourceMarkdownURL: sourceMarkdownURL,
            sourceMap: nil,
            reviewedAt: reviewedAt,
            timeSpent: 22 * 60,
            closingInstruction: closingInstruction,
            comments: comments ?? [firstComment(), secondComment()],
            pages: pages,
            include: include,
            origin: origin,
            returnPath: ReturnPathResolver().resolve(origin)
        )
    }

    /// A page carrying ink, for the builder tests. The bytes are not a real
    /// `PKDrawing` — every test that uses them injects a stub cropper, because
    /// PencilKit cannot be exercised anywhere but a device (STYLE.md § 10).
    static func inkedPage(_ pageIndex: Int, recognisedInk: String? = nil) -> PageSnapshot {
        PageSnapshot(
            pageIndex: pageIndex,
            drawingData: Data([0x50, 0x4B, 0x00, 0x01]),
            recognisedInk: recognisedInk,
            hasInk: true
        )
    }

    // MARK: - Helpers

    /// A stable UUID per number, so a failure names the same comment every run.
    static func uuid(_ number: Int) -> UUID {
        let suffix = String(format: "%012d", number)
        return UUID(uuidString: "00000000-0000-4000-8000-" + suffix) ?? UUID()
    }

    /// UTC, so a machine in another zone does not rewrite the reviewed-at line.
    static func markdownWriter() -> ReviewMarkdownWriter {
        ReviewMarkdownWriter(timeZone: TimeZone(secondsFromGMT: 0) ?? .current)
    }
}
