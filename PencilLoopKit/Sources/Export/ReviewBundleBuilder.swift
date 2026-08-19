//
//  ReviewBundleBuilder.swift
//  Export
//
//  The orchestration: `review.md`, `review.json`, the cropped ink PNGs and
//  `manifest.json`, in that order, as bytes.
//
//  Bytes, not files. `OutboxWriting` does the atomic write (docs/04-flows.md
//  § F5); keeping the two apart is what lets `review.md` be diffed against
//  contracts/fixtures/review.md without a sync folder anywhere near the test.
//
//  Budget: under 2 seconds for a 50-page document with 20 comments
//  (docs/03-architecture.md § Performance targets). The only part of that which
//  is not trivially fast is rasterising ink pages, so those are cropped
//  concurrently and a page that will not render is skipped rather than fatal.
//
//  Not built: `review.docx`. docs/05 describes it as the fallback that always
//  works, and it would be, but it needs a ZIP container that iOS has no system
//  API for. Deferred to a later wave rather than half-built here.
//

import Foundation
import os
import Core

/// Assembles a review bundle.
///
/// **On failure:** throws `PencilLoopError.bundleBuildFailed`. One ink page that
/// will not render is *not* a failure — it is dropped and the review is built
/// without it, with its comment text intact, because losing a review because one
/// PNG would not encode is not an acceptable trade.
public struct ReviewBundleBuilder: ReviewBundleBuilding {

    // The bundle's own file names are frozen in Core: `review.md` and
    // `document.pdf` as `DocumentFileNames.reviewMarkdown` and
    // `DocumentFileNames.document`, `review.json` on `ReviewBundle`,
    // `manifest.json` on `BundleManifest`.

    private let inkCropper: any InkCropping
    private let markdownWriter: ReviewMarkdownWriter
    private let jsonWriter: ReviewJSONWriter
    private let manifestWriter: ManifestWriter
    private let logger: Logger

    public init(
        inkCropper: any InkCropping = InkCropper(),
        markdownWriter: ReviewMarkdownWriter = ReviewMarkdownWriter(),
        jsonWriter: ReviewJSONWriter = ReviewJSONWriter(),
        manifestWriter: ManifestWriter = ManifestWriter(),
        logger: Logger = Logger(subsystem: "co.pencil-loop", category: "Export")
    ) {
        self.inkCropper = inkCropper
        self.markdownWriter = markdownWriter
        self.jsonWriter = jsonWriter
        self.manifestWriter = manifestWriter
        self.logger = logger
    }

    // MARK: - ReviewBundleBuilding

    public func build(_ draft: ReviewDraft) async throws -> OutboxPayload {
        let composition = await compose(draft)
        let directoryName = OutboxPayload.directoryName(forDocumentFolder: draft.folderName)
        var files: [BundleFile] = []

        // review.md first: it is the payload, and everything else is an
        // annotation on it.
        let markdown = markdownWriter.markdown(
            for: draft,
            comments: composition.comments,
            inkPages: composition.inkPages,
            resolutions: composition.resolutions
        )
        guard let markdownData = markdown.data(using: .utf8) else {
            throw PencilLoopError.bundleBuildFailed(
                reason: "review.md could not be encoded as UTF-8."
            )
        }
        files.append(
            BundleFile(
                relativePath: DocumentFileNames.reviewMarkdown,
                data: markdownData
            )
        )

        let bundle = jsonWriter.bundle(
            for: draft,
            comments: composition.comments,
            inkPages: composition.inkPages
        )
        let bundleData = try jsonWriter.data(for: bundle)
        files.append(BundleFile(relativePath: ReviewBundle.fileName, data: bundleData))

        for image in composition.images {
            files.append(BundleFile(relativePath: image.relativePath, data: image.pngData))
        }

        if draft.include.fullDocument {
            if let documentData = try? Data(contentsOf: draft.pdfURL) {
                files.append(
                    BundleFile(
                        relativePath: DocumentFileNames.document,
                        data: documentData
                    )
                )
            } else {
                // The same rule as a failed ink page: the review is worth more
                // than the attachment.
                logger.error("The document could not be attached; the review was sent without it.")
            }
        }

        // The manifest lists everything else and is written last, because it is
        // what the watcher on the other side gates completeness on
        // (integrations/mac-watcher § Completeness).
        let manifest = manifestWriter.manifest(
            files: files,
            documentId: draft.externalDocumentId,
            reviewFolder: directoryName,
            createdAt: draft.reviewedAt,
            origin: draft.origin
        )
        let manifestData = try manifestWriter.data(for: manifest)
        files.append(BundleFile(relativePath: BundleManifest.fileName, data: manifestData))

        return OutboxPayload(
            directoryName: directoryName,
            documentId: draft.documentId,
            files: files
        )
    }

    public func reviewMarkdown(_ draft: ReviewDraft) async throws -> String {
        // Deliberately the same composition `build(_:)` uses, ink cropping
        // included: the contract says this is byte-identical to the review.md
        // inside the payload, and a page that failed to crop changes which
        // images the handwritten-pages section names.
        let composition = await compose(draft)
        return markdownWriter.markdown(
            for: draft,
            comments: composition.comments,
            inkPages: composition.inkPages,
            resolutions: composition.resolutions
        )
    }

    // MARK: - Composition

    /// Everything both halves of the bundle are built from, produced once so
    /// they cannot disagree.
    struct Composition: Sendable {

        /// Numbered 1…n in document order, with anchors re-checked.
        var comments: [ReviewComment] = []

        /// The pages that actually produced an image.
        var inkPages: [ReviewInkPage] = []

        /// The images themselves, in page order.
        var images: [InkImage] = []

        /// Which rung of the ladder resolved each comment, keyed by
        /// `ReviewComment.id`.
        var resolutions: [String: AnchorResolution] = [:]
    }

    func compose(_ draft: ReviewDraft) async -> Composition {
        let resolved = resolvedAnchors(for: draft)
        let images = await inkImages(for: draft)

        var composition = Composition()
        composition.comments = jsonWriter.comments(for: draft, anchors: resolved.anchors)
        composition.images = images
        composition.inkPages = jsonWriter.inkPages(for: draft, images: images)

        // Re-key the resolutions from the store's UUIDs onto the bundle's C1,
        // C2, … so `review.md` can look one up by the id it prints.
        for (offset, snapshot) in draft.comments.enumerated() {
            guard let resolution = resolved.resolutions[snapshot.id] else { continue }
            composition.resolutions[ReviewComment.identifier(forIndex: offset + 1)] = resolution
        }
        return composition
    }

    /// Re-resolves every anchor against `source.md` before writing.
    ///
    /// `ReviewDraft.sourceMarkdownURL` exists so the ranges in `review.json` are
    /// checked rather than assumed: the document may have been regenerated since
    /// the comment was made, and a `sourceRange` that was right last week is
    /// worse than no `sourceRange` at all.
    ///
    /// **A range that could not be checked is dropped, not kept.** There is no
    /// markdown to resolve against for a PDF that was never rendered from any,
    /// and those anchors are used unchanged — that is the one case where a
    /// stored `sourceRange` was never a claim about a file we can read. But
    /// markdown that is *there* and will not read — deleted underneath us,
    /// permission refused, saved in something that is not UTF-8 — is a failure
    /// to verify, and it used to be indistinguishable from the first case: the
    /// captured ranges went into `review.json` looking exactly like checked
    /// ones, and `review.md` said nothing. An agent editing at that offset edits
    /// the wrong bytes.
    ///
    /// - Returns: empty maps when there is no markdown at all. When there is
    ///   markdown that could not be read, every comment comes back with its
    ///   `sourceRange` removed and a `.rectFallback` resolution, so the prose
    ///   describes the position as approximate — which is what it is.
    func resolvedAnchors(
        for draft: ReviewDraft
    ) -> (anchors: [UUID: Anchor], resolutions: [UUID: AnchorResolution]) {
        guard draft.include.comments, !draft.comments.isEmpty else { return ([:], [:]) }
        guard let url = draft.sourceMarkdownURL else { return ([:], [:]) }

        let text: String
        do {
            text = try String(contentsOf: url, encoding: .utf8)
        } catch {
            logger.error(
                "source.md could not be read, so no anchor could be re-checked; the review was sent with positions marked approximate."
            )
            return unverifiedAnchors(for: draft)
        }
        guard !text.isEmpty else { return unverifiedAnchors(for: draft) }

        var anchors: [UUID: Anchor] = [:]
        var resolutions: [UUID: AnchorResolution] = [:]

        for comment in draft.comments {
            let resolution = AnchorResolver.resolve(anchor: comment.anchor, in: text)
            resolutions[comment.id] = resolution

            var anchor = comment.anchor
            // Nil for a rect fallback, and deliberately so: the passage no
            // longer matches, so the byte range it used to sit at is a number
            // nobody has checked. A `sourceRange` that was right last week is
            // worse than no `sourceRange` at all.
            anchor.sourceRange = resolution.range
            anchors[comment.id] = anchor
        }
        return (anchors, resolutions)
    }

    /// Every comment, stripped of the range that could not be verified and
    /// marked as positioned by page and rect alone.
    private func unverifiedAnchors(
        for draft: ReviewDraft
    ) -> (anchors: [UUID: Anchor], resolutions: [UUID: AnchorResolution]) {
        var anchors: [UUID: Anchor] = [:]
        var resolutions: [UUID: AnchorResolution] = [:]
        for comment in draft.comments {
            var anchor = comment.anchor
            anchor.sourceRange = nil
            anchors[comment.id] = anchor
            resolutions[comment.id] = .rectFallback(
                pageIndex: comment.anchor.pageIndex,
                rect: comment.anchor.normalisedRect
            )
        }
        return (anchors, resolutions)
    }

    /// Crops every inked page, concurrently.
    ///
    /// Only inked pages are cropped — `ReviewDraft.inkedPages` does that
    /// filtering — so a 50-page document with marks on two pages does two
    /// crops, not fifty (docs/05-file-contracts.md § Ink images).
    ///
    /// - Returns: the pages that rendered, in page order. A page that threw is
    ///   logged and left out; the contract for `ReviewBundleBuilding` requires
    ///   the rest of the review to survive it.
    func inkImages(for draft: ReviewDraft) async -> [InkImage] {
        guard draft.include.inkImages else { return [] }
        let pages = draft.inkedPages
        guard !pages.isEmpty else { return [] }

        let cropper = inkCropper
        let pdfURL = draft.pdfURL
        let wantsRecognisedText = draft.include.recognisedText
        let logger = self.logger

        return await withTaskGroup(of: InkImage?.self) { group -> [InkImage] in
            for page in pages {
                guard let drawingData = page.drawingData else { continue }
                let pageIndex = page.pageIndex
                let recognisedText = wantsRecognisedText ? page.recognisedInk : nil

                group.addTask {
                    do {
                        return try await cropper.cropInk(
                            pdfURL: pdfURL,
                            pageIndex: pageIndex,
                            drawingData: drawingData,
                            recognisedText: recognisedText
                        )
                    } catch {
                        logger.error(
                            "Ink page \(pageIndex + 1, privacy: .public) could not be cropped and was left out of the bundle."
                        )
                        return nil
                    }
                }
            }

            var images: [InkImage] = []
            for await image in group {
                if let image { images.append(image) }
            }
            return images.sorted { $0.pageIndex < $1.pageIndex }
        }
    }
}
