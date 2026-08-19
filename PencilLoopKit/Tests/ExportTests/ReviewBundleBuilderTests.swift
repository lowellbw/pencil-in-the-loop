//
//  ReviewBundleBuilderTests.swift
//  ExportTests
//
//  The orchestration: which files come out, in what order, and what survives an
//  ink page that will not render.
//
//  Every test here injects a stub cropper. The real one needs PDFKit, PencilKit
//  and a device; what the builder has to get right is everything around it.
//

import XCTest
import Foundation
import Core
@testable import Export

final class ReviewBundleBuilderTests: XCTestCase {

    // MARK: - What comes out

    func testTheBundleCarriesTheContractedFiles() async throws {
        let payload = try await Self.builder().build(Self.draft())
        let paths = payload.files.map { $0.relativePath }

        XCTAssertEqual(
            paths,
            ["review.md", "review.json", "ink/page-01.png", "ink/page-03.png", "manifest.json"]
        )
    }

    /// The manifest is written last, because it is what the watcher on the other
    /// side gates completeness on (integrations/mac-watcher § Completeness).
    func testTheManifestIsLast() async throws {
        let payload = try await Self.builder().build(Self.draft())
        XCTAssertEqual(payload.files.last?.relativePath, BundleManifest.fileName)
    }

    /// docs/05 defers `review.docx` to a later wave. A stub file implying it
    /// exists would be worse than its absence.
    func testNoDocxIsEmitted() async throws {
        let payload = try await Self.builder().build(Self.draft())
        XCTAssertFalse(payload.files.contains { $0.relativePath.hasSuffix(".docx") })
    }

    func testTheDirectoryNameIsTheDocumentFolderPlusDotReview() async throws {
        let payload = try await Self.builder().build(Self.draft())
        XCTAssertEqual(payload.directoryName, "2026-08-18-auth-refactor-plan.review")
        XCTAssertTrue(payload.directoryName.hasSuffix(OutboxPayload.reviewDirectorySuffix))
    }

    func testTheManifestListsEveryOtherFile() async throws {
        let payload = try await Self.builder().build(Self.draft())
        let manifestFile = try XCTUnwrap(payload.files.first { $0.relativePath == BundleManifest.fileName })
        let manifest = try ContractCoding.decoder().decode(BundleManifest.self, from: manifestFile.data)

        let listed = Set(manifest.files.map { $0.path })
        let written = Set(payload.files.map { $0.relativePath }).subtracting([BundleManifest.fileName])
        XCTAssertEqual(listed, written)
        XCTAssertEqual(manifest.reviewFolder, payload.directoryName)
        XCTAssertEqual(manifest.documentId, ExportTestFixtures.externalDocumentId)
    }

    /// Every byte count and hash in the manifest describes the bytes actually in
    /// the payload, or the watcher's completeness check means nothing.
    func testTheManifestHashesTheBytesThatWereWritten() async throws {
        let payload = try await Self.builder().build(Self.draft())
        let manifestFile = try XCTUnwrap(payload.files.first { $0.relativePath == BundleManifest.fileName })
        let manifest = try ContractCoding.decoder().decode(BundleManifest.self, from: manifestFile.data)

        for entry in manifest.files {
            let file = try XCTUnwrap(payload.files.first { $0.relativePath == entry.path })
            XCTAssertEqual(entry.bytes, Int64(file.data.count), entry.path)
            XCTAssertEqual(entry.sha256, ManifestWriter.sha256Hex(file.data), entry.path)
        }
    }

    // MARK: - The two halves agree

    /// `review.md` and `review.json` carry the same comments, in the same order,
    /// with the same numbering, and name the same image files.
    func testTheProseAndTheJsonNameTheSameFilesAndComments() async throws {
        let payload = try await Self.builder().build(Self.draft())
        let markdown = try Self.text(at: DocumentFileNames.reviewMarkdown, in: payload)
        let bundleFile = try XCTUnwrap(payload.files.first { $0.relativePath == ReviewBundle.fileName })
        let bundle = try ContractCoding.decoder().decode(ReviewBundle.self, from: bundleFile.data)

        XCTAssertEqual(bundle.comments.map { $0.index }, [1, 2])
        for comment in bundle.comments {
            XCTAssertTrue(markdown.contains("### \(comment.index) \u{2014} page \(comment.anchor.pageIndex + 1)"))
        }
        for page in bundle.inkPages {
            XCTAssertTrue(markdown.contains("`" + page.image + "`"), page.image)
            XCTAssertTrue(payload.files.contains { $0.relativePath == page.image })
        }
    }

    /// `reviewMarkdown(_:)` is documented as byte-identical to the `review.md`
    /// inside the payload for the same draft. That is why it runs the same
    /// composition rather than a cheaper one.
    func testTheCopyableProseIsByteIdenticalToTheBundledFile() async throws {
        let builder = Self.builder()
        let draft = Self.draft()

        let payload = try await builder.build(draft)
        let copied = try await builder.reviewMarkdown(draft)

        XCTAssertEqual(copied, try Self.text(at: DocumentFileNames.reviewMarkdown, in: payload))
    }

    // MARK: - Ink

    /// Only inked pages. A 50-page document with marks on two pages sends two
    /// images; this is the difference between a cheap review and an absurd one.
    func testOnlyInkedPagesAreCropped() async throws {
        var pages = (0..<50).map { PageSnapshot(pageIndex: $0) }
        pages[0] = ExportTestFixtures.inkedPage(0)
        pages[2] = ExportTestFixtures.inkedPage(2)

        let cropper = StubInkCropper()
        let payload = try await Self.builder(cropper: cropper).build(Self.draft(pages: pages))

        let requested = await cropper.requestedPages()
        XCTAssertEqual(requested, [0, 2])
        XCTAssertEqual(payload.files.filter { $0.relativePath.hasPrefix("ink/") }.count, 2)
    }

    /// "An ink page that will not render is skipped with its comment text kept,
    /// rather than failing the whole bundle."
    func testAPageThatWillNotRenderIsSkippedAndTheReviewSurvives() async throws {
        let cropper = StubInkCropper(failingPages: [2])
        let payload = try await Self.builder(cropper: cropper).build(Self.draft())
        let markdown = try Self.text(at: DocumentFileNames.reviewMarkdown, in: payload)

        XCTAssertEqual(payload.files.map { $0.relativePath }, [
            "review.md", "review.json", "ink/page-01.png", "manifest.json"
        ])
        XCTAssertTrue(markdown.contains("Page 1 has handwritten marks"), markdown)
        XCTAssertFalse(markdown.contains("ink/page-03.png"))
        XCTAssertTrue(markdown.contains("### 1 \u{2014} page 1"))
    }

    func testEveryInkPageFailingStillProducesAReview() async throws {
        let cropper = StubInkCropper(failingPages: [0, 2])
        let payload = try await Self.builder(cropper: cropper).build(Self.draft())
        let markdown = try Self.text(at: DocumentFileNames.reviewMarkdown, in: payload)

        XCTAssertEqual(payload.files.map { $0.relativePath }, ["review.md", "review.json", "manifest.json"])
        XCTAssertFalse(markdown.contains("## Handwritten pages"))
        XCTAssertTrue(markdown.contains("## Comments"))
    }

    func testInkImagesAreOrderedByPage() async throws {
        let pages = [ExportTestFixtures.inkedPage(4), ExportTestFixtures.inkedPage(1), ExportTestFixtures.inkedPage(0)]
        let payload = try await Self.builder().build(Self.draft(pages: pages))
        XCTAssertEqual(
            payload.files.filter { $0.relativePath.hasPrefix("ink/") }.map { $0.relativePath },
            ["ink/page-01.png", "ink/page-02.png", "ink/page-05.png"]
        )
    }

    func testRecognisedInkIsCarriedThroughToBothHalves() async throws {
        let pages = [ExportTestFixtures.inkedPage(0, recognisedInk: "do we? check the mobile SDK")]
        let payload = try await Self.builder().build(Self.draft(pages: pages))
        let markdown = try Self.text(at: DocumentFileNames.reviewMarkdown, in: payload)
        let bundleFile = try XCTUnwrap(payload.files.first { $0.relativePath == ReviewBundle.fileName })
        let bundle = try ContractCoding.decoder().decode(ReviewBundle.self, from: bundleFile.data)

        XCTAssertEqual(bundle.inkPages.first?.recognisedText, "do we? check the mobile SDK")
        XCTAssertTrue(markdown.contains("> do we? check the mobile SDK"), markdown)
    }

    func testInkImagesToggledOffCropsNothingAtAll() async throws {
        let cropper = StubInkCropper()
        let payload = try await Self.builder(cropper: cropper).build(
            Self.draft(include: ReviewIncludeOptions(inkImages: false))
        )
        let requested = await cropper.requestedPages()
        XCTAssertTrue(requested.isEmpty)
        XCTAssertFalse(payload.files.contains { $0.relativePath.hasPrefix("ink/") })
    }

    // MARK: - Anchors are re-checked, not assumed

    /// `ReviewDraft.sourceMarkdownURL` exists so the ranges in `review.json` are
    /// checked against the markdown as it is now, not as it was when the comment
    /// was made.
    func testSourceRangesAreReResolvedAgainstTheMarkdown() async throws {
        let markdownURL = try Self.writeTemporary(Self.sourceMarkdown, named: "source.md")
        defer { try? FileManager.default.removeItem(at: markdownURL) }

        let payload = try await Self.builder().build(Self.draft(sourceMarkdownURL: markdownURL))
        let bundleFile = try XCTUnwrap(payload.files.first { $0.relativePath == ReviewBundle.fileName })
        let bundle = try ContractCoding.decoder().decode(ReviewBundle.self, from: bundleFile.data)

        let resolved = try XCTUnwrap(bundle.comments.first?.anchor.sourceRange)
        XCTAssertNotEqual(resolved, SourceRange(start: 1204, end: 1268), "the stale range was kept")
        XCTAssertEqual(resolved.substring(of: Self.sourceMarkdown), bundle.comments.first?.anchor.quoted)
    }

    /// A comment whose passage is gone is described as approximate in the prose,
    /// and keeps no range it can no longer justify.
    func testAVanishedPassageIsDescribedAsApproximate() async throws {
        let markdownURL = try Self.writeTemporary("Nothing here resembles the review at all.\n", named: "source.md")
        defer { try? FileManager.default.removeItem(at: markdownURL) }

        let payload = try await Self.builder().build(Self.draft(sourceMarkdownURL: markdownURL))
        let markdown = try Self.text(at: DocumentFileNames.reviewMarkdown, in: payload)

        XCTAssertTrue(markdown.contains("position approximate"), markdown)
    }

    /// A `source.md` that is *there* and will not read is not the same thing as
    /// no markdown at all: nothing was checked, so nothing may be presented as
    /// checked. The captured ranges used to flow into `review.json` looking
    /// exactly like re-resolved ones, and `review.md` said nothing — an agent
    /// editing at that offset edits the wrong bytes.
    func testAnUnreadableSourceMarkdownDropsTheRangesItCouldNotCheck() async throws {
        // Valid markdown apart from one byte that cannot be UTF-8.
        let markdownURL = try Self.writeTemporaryBytes(
            Data("# Auth refactor plan\n\n".utf8) + Data([0xFF, 0xFE]) + Data("\ntext\n".utf8),
            named: "source.md"
        )
        defer { try? FileManager.default.removeItem(at: markdownURL) }

        let payload = try await Self.builder().build(Self.draft(sourceMarkdownURL: markdownURL))
        let bundleFile = try XCTUnwrap(payload.files.first { $0.relativePath == ReviewBundle.fileName })
        let bundle = try ContractCoding.decoder().decode(ReviewBundle.self, from: bundleFile.data)
        let markdown = try Self.text(at: DocumentFileNames.reviewMarkdown, in: payload)

        for comment in bundle.comments {
            XCTAssertNil(
                comment.anchor.sourceRange,
                "An unverified byte range must not be shipped as though it had been checked."
            )
        }
        XCTAssertTrue(markdown.contains("position approximate"), markdown)
    }

    /// The same rule for markdown that has been deleted from under the review.
    func testAMissingSourceMarkdownDropsTheRangesItCouldNotCheck() async throws {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("source.md")

        let payload = try await Self.builder().build(Self.draft(sourceMarkdownURL: missing))
        let bundleFile = try XCTUnwrap(payload.files.first { $0.relativePath == ReviewBundle.fileName })
        let bundle = try ContractCoding.decoder().decode(ReviewBundle.self, from: bundleFile.data)

        XCTAssertFalse(bundle.comments.isEmpty)
        XCTAssertNil(bundle.comments.first?.anchor.sourceRange)
    }

    /// A passage that no longer matches keeps no range either — the rung that
    /// resolved it is the rect, and the range it used to sit at is a number
    /// nobody has checked.
    func testAVanishedPassageKeepsNoSourceRange() async throws {
        let markdownURL = try Self.writeTemporary("Nothing here resembles the review at all.\n", named: "source.md")
        defer { try? FileManager.default.removeItem(at: markdownURL) }

        let payload = try await Self.builder().build(Self.draft(sourceMarkdownURL: markdownURL))
        let bundleFile = try XCTUnwrap(payload.files.first { $0.relativePath == ReviewBundle.fileName })
        let bundle = try ContractCoding.decoder().decode(ReviewBundle.self, from: bundleFile.data)

        XCTAssertNil(bundle.comments.first?.anchor.sourceRange)
    }

    /// A PDF that was never rendered from markdown has nothing to re-resolve
    /// against, and the captured anchors are used unchanged.
    func testWithoutMarkdownTheCapturedAnchorsAreKept() async throws {
        let payload = try await Self.builder().build(Self.draft())
        let bundleFile = try XCTUnwrap(payload.files.first { $0.relativePath == ReviewBundle.fileName })
        let bundle = try ContractCoding.decoder().decode(ReviewBundle.self, from: bundleFile.data)
        XCTAssertEqual(bundle.comments.first?.anchor.sourceRange, SourceRange(start: 1204, end: 1268))
    }

    // MARK: - The whole document

    func testTheFullDocumentIsAttachedOnlyWhenAskedFor() async throws {
        let pdfURL = try Self.writeTemporary("%PDF-1.7 not really\n", named: "document.pdf")
        defer { try? FileManager.default.removeItem(at: pdfURL) }

        let without = try await Self.builder().build(Self.draft(pdfURL: pdfURL))
        XCTAssertFalse(without.files.contains { $0.relativePath == DocumentFileNames.document })

        let include = ReviewIncludeOptions(fullDocument: true)
        let with = try await Self.builder().build(Self.draft(include: include, pdfURL: pdfURL))
        XCTAssertTrue(with.files.contains { $0.relativePath == DocumentFileNames.document })
        XCTAssertEqual(with.files.last?.relativePath, BundleManifest.fileName)
    }

    /// An unreadable document is not a failed review.
    func testAnUnattachableDocumentDoesNotFailTheBundle() async throws {
        let include = ReviewIncludeOptions(fullDocument: true)
        let payload = try await Self.builder().build(
            Self.draft(include: include, pdfURL: URL(fileURLWithPath: "/no/such/document.pdf"))
        )
        XCTAssertTrue(payload.files.contains { $0.relativePath == DocumentFileNames.reviewMarkdown })
        XCTAssertFalse(payload.files.contains { $0.relativePath == DocumentFileNames.document })
    }

    // MARK: - Support

    /// Stands in for the real cropper, which needs PDFKit, PencilKit and a
    /// device. An actor because the tests read back what it was asked for.
    actor StubInkCropper: InkCropping {

        private let failingPages: Set<Int>
        private var requested: [Int] = []

        init(failingPages: Set<Int> = []) {
            self.failingPages = failingPages
        }

        func requestedPages() -> [Int] {
            requested.sorted()
        }

        func cropInk(
            pdfURL: URL,
            pageIndex: Int,
            drawingData: Data,
            recognisedText: String?
        ) async throws -> InkImage {
            requested.append(pageIndex)
            guard !failingPages.contains(pageIndex) else {
                throw PencilLoopError.bundleBuildFailed(reason: "stubbed failure for page \(pageIndex)")
            }
            return InkImage(
                pageIndex: pageIndex,
                relativePath: InkImage.fileName(forPageIndex: pageIndex),
                pngData: Data([0x89, 0x50, 0x4E, 0x47, UInt8(pageIndex & 0xFF)]),
                recognisedText: recognisedText
            )
        }
    }

    static let sourceMarkdown = """
        # Auth refactor plan

        Phase 1 introduces the refresh token stored in the keychain. \
        The migration runs in a single deploy, with no dual-write window. \
        Rollout is gated behind auth_v2 for the first week.

        await refresh(session)   // no backoff
        """

    static func builder(cropper: any InkCropping = StubInkCropper()) -> ReviewBundleBuilder {
        ReviewBundleBuilder(
            inkCropper: cropper,
            markdownWriter: ExportTestFixtures.markdownWriter(),
            jsonWriter: ReviewJSONWriter(),
            manifestWriter: ManifestWriter(generator: GeneratorInfo(version: "1.0", build: "1"))
        )
    }

    /// The fixture draft with ink on pages 1 and 3, one-based.
    static func draft(
        pages: [PageSnapshot]? = nil,
        include: ReviewIncludeOptions = .standard,
        sourceMarkdownURL: URL? = nil,
        pdfURL: URL = URL(fileURLWithPath: "/dev/null")
    ) -> ReviewDraft {
        ExportTestFixtures.draft(
            pages: pages ?? [ExportTestFixtures.inkedPage(0), ExportTestFixtures.inkedPage(2)],
            include: include,
            sourceMarkdownURL: sourceMarkdownURL,
            pdfURL: pdfURL
        )
    }

    static func text(at path: String, in payload: OutboxPayload) throws -> String {
        let file = try XCTUnwrap(payload.files.first { $0.relativePath == path })
        return try XCTUnwrap(String(data: file.data, encoding: .utf8))
    }

    static func writeTemporary(_ contents: String, named name: String) throws -> URL {
        try writeTemporaryBytes(Data(contents.utf8), named: name)
    }

    /// Bytes rather than a `String`, so a test can write a file that is not
    /// UTF-8 at all — which a `String` cannot express.
    static func writeTemporaryBytes(_ contents: Data, named name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent(name)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try contents.write(to: url, options: .atomic)
        return url
    }
}
