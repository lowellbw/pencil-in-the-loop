//
//  ReviewBundle.swift
//  Core · Contracts
//
//  `review.json`, exactly. Four types in one file because they are one
//  document; listed in tooling/lint/style_allowlist.txt.
//
//  This is the structured half of the payload. The prose half is `review.md`,
//  which is what a model actually reads — see docs/05-file-contracts.md and the
//  golden fixture at contracts/fixtures/review.md. The two must agree: the same
//  comments, in the same order, with the same numbering.
//
//  Encode with `ContractCoding.encoder()`. Nothing else.
//

import Foundation

/// The whole of `review.json`.
///
/// ```json
/// {
///   "documentId": "F7A1…",
///   "reviewedAt": "2026-08-18T21:14:00Z",
///   "closingInstruction": "…",
///   "comments": [ … ],
///   "inkPages": [ … ],
///   "included": { "comments": true, "inkImages": true,
///                 "recognisedText": true, "fullDocument": false }
/// }
/// ```
public struct ReviewBundle: Codable, Sendable, Hashable {

    /// The document's id as it appeared in `meta.json`, verbatim. A string, not
    /// a UUID: whoever sent the document chose this value and we hand it back
    /// unchanged so they can match on it.
    public var documentId: String

    /// When Send was pressed.
    public var reviewedAt: Date

    /// The closing instruction, verbatim. Empty string when the user left it
    /// blank — the key is always present.
    public var closingInstruction: String

    /// In document order, numbered from 1. Order here is the order in
    /// `review.md`.
    public var comments: [ReviewComment]

    /// Only inked pages appear (docs/05-file-contracts.md § Ink images).
    public var inkPages: [ReviewInkPage]

    /// What the user chose to send.
    public var included: ReviewIncludeOptions

    public init(
        documentId: String,
        reviewedAt: Date,
        closingInstruction: String,
        comments: [ReviewComment],
        inkPages: [ReviewInkPage],
        included: ReviewIncludeOptions
    ) {
        self.documentId = documentId
        self.reviewedAt = reviewedAt
        self.closingInstruction = closingInstruction
        self.comments = comments
        self.inkPages = inkPages
        self.included = included
    }

    /// The bundle-relative filename this type is written to.
    public static let fileName = "review.json"
}

/// One entry in `review.json`'s `comments` array.
public struct ReviewComment: Codable, Sendable, Hashable, Identifiable {

    /// Short, human-readable, stable within one bundle: `C1`, `C2`, … The full
    /// UUID stays inside the app; a model quoting "C2" back at us is far more
    /// use than one quoting a UUID.
    public var id: String

    /// 1-based position, matching the `### n — page m` heading in `review.md`.
    public var index: Int

    public var text: String
    public var source: CommentSource
    public var anchor: Anchor

    public init(id: String, index: Int, text: String, source: CommentSource, anchor: Anchor) {
        self.id = id
        self.index = index
        self.text = text
        self.source = source
        self.anchor = anchor
    }

    /// `C1` for index 1. The only place the id format is spelled.
    public static func identifier(forIndex index: Int) -> String { "C\(index)" }
}

/// One entry in `review.json`'s `inkPages` array.
public struct ReviewInkPage: Codable, Sendable, Hashable {

    /// Zero-based, matching `Anchor.pageIndex`. The filename is one-based —
    /// `pageIndex` 0 is `ink/page-01.png` — because that is what a human
    /// opening the folder expects.
    public var pageIndex: Int

    /// Bundle-relative path to the PNG.
    public var image: String

    /// Recognised handwriting for the page, when there is any and the user left
    /// the "Recognised text" toggle on.
    public var recognisedText: String?

    public init(pageIndex: Int, image: String, recognisedText: String? = nil) {
        self.pageIndex = pageIndex
        self.image = image
        self.recognisedText = recognisedText
    }

    enum CodingKeys: String, CodingKey {
        case pageIndex
        case image
        case recognisedText
    }

    /// Omits `recognisedText` rather than writing null.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(pageIndex, forKey: .pageIndex)
        try container.encode(image, forKey: .image)
        try container.encodeIfPresent(recognisedText, forKey: .recognisedText)
    }
}

/// The four Include toggles from the review sheet (docs/02-spec.md § S4).
///
/// The first three default on, `fullDocument` off — a review is a reply to a
/// document the other side already has, and re-sending it wastes the context
/// window that makes the reply good.
public struct ReviewIncludeOptions: Codable, Sendable, Hashable {

    /// The comment list. Off means the bundle is a closing instruction only.
    public var comments: Bool

    /// The cropped ink PNGs.
    public var inkImages: Bool

    /// `PKStrokeRecognizer` text, both in `review.md` and in `review.json`.
    public var recognisedText: Bool

    /// Attach the whole document alongside the review.
    public var fullDocument: Bool

    public init(
        comments: Bool = true,
        inkImages: Bool = true,
        recognisedText: Bool = true,
        fullDocument: Bool = false
    ) {
        self.comments = comments
        self.inkImages = inkImages
        self.recognisedText = recognisedText
        self.fullDocument = fullDocument
    }

    /// The state the review sheet opens in.
    public static let standard = ReviewIncludeOptions()
}
