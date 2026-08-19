//
//  ReviewJSONWriter.swift
//  Export
//
//  `review.json` — the structured half of the payload, for tools rather than for
//  models. Schema at contracts/schema/review.schema.json, fixture at
//  contracts/fixtures/review.json.
//
//  The shape is entirely Core's: `ReviewBundle` and friends encode exactly as
//  the file, `NormalisedRect` as `[x, y, w, h]` and `SourceRange` as
//  `[start, end]`, and `ContractCoding.encoder()` fixes the date format, the key
//  order and the escaping. This file assembles; it does not decide.
//

import Foundation
import Core

/// Builds and encodes `review.json`.
///
/// **On failure:** `data(for:)` throws `PencilLoopError.bundleBuildFailed`.
/// Assembly itself cannot fail — every field has a total mapping from the draft.
public struct ReviewJSONWriter: Sendable {

    public init() {}

    /// The comment list for both halves of the bundle.
    ///
    /// Numbered 1…n in the draft's order, which is document order — page, then
    /// vertical position — and which is therefore also the order of the
    /// `### n — page m` headings in `review.md`. The two must agree; producing
    /// them from one call is how that is guaranteed rather than hoped for.
    ///
    /// - Parameters:
    ///   - draft: the review sheet's collection.
    ///   - anchors: anchors whose `sourceRange` was re-checked against
    ///     `source.md`, keyed by comment id. A comment missing from the map
    ///     keeps the anchor it was captured with.
    /// - Returns: an empty array when the user turned Comments off — a bundle
    ///   with `included.comments == false` must not carry comments anyway.
    public func comments(for draft: ReviewDraft, anchors: [UUID: Anchor] = [:]) -> [ReviewComment] {
        guard draft.include.comments else { return [] }
        return draft.comments.enumerated().map { offset, snapshot in
            let index = offset + 1
            return ReviewComment(
                id: ReviewComment.identifier(forIndex: index),
                index: index,
                text: snapshot.text,
                source: snapshot.source,
                anchor: anchors[snapshot.id] ?? snapshot.anchor
            )
        }
    }

    /// The `inkPages` array, from the pages that actually produced an image.
    ///
    /// Only inked pages appear, because a 50-page document with marks on two
    /// pages sends two images (docs/05-file-contracts.md § Ink images).
    /// `recognisedText` is dropped — not emptied — when the user turned the
    /// Recognised text toggle off, so the key is simply absent.
    public func inkPages(for draft: ReviewDraft, images: [InkImage]) -> [ReviewInkPage] {
        guard draft.include.inkImages else { return [] }
        return images
            .sorted { $0.pageIndex < $1.pageIndex }
            .map { image in
                let recognised = draft.include.recognisedText ? image.recognisedText : nil
                let usable: String? = (recognised?.isEmpty ?? true) ? nil : recognised
                return ReviewInkPage(
                    pageIndex: image.pageIndex,
                    image: image.relativePath,
                    recognisedText: usable
                )
            }
    }

    /// The whole of `review.json` as a value.
    public func bundle(
        for draft: ReviewDraft,
        comments: [ReviewComment],
        inkPages: [ReviewInkPage]
    ) -> ReviewBundle {
        ReviewBundle(
            documentId: draft.externalDocumentId,
            reviewedAt: draft.reviewedAt,
            closingInstruction: draft.closingInstruction,
            comments: comments,
            inkPages: inkPages,
            included: draft.include
        )
    }

    /// The bytes, through the one frozen encoder.
    ///
    /// - Throws: `PencilLoopError.bundleBuildFailed` when encoding fails, which
    ///   in practice means a `Date` no formatter would accept.
    public func data(for bundle: ReviewBundle) throws -> Data {
        do {
            return try ContractCoding.encoder().encode(bundle)
        } catch {
            throw PencilLoopError.bundleBuildFailed(
                reason: "review.json could not be encoded. \(error.localizedDescription)"
            )
        }
    }
}
