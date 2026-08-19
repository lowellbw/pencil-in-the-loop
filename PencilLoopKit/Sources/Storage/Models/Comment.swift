//
//  Comment.swift
//  Storage · Models
//
//  One anchored comment.
//
//  ─── HOW `Anchor` IS STORED ──────────────────────────────────────────────────
//  As a composite of stored columns, not as an encoded blob.
//
//  `Anchor` is `Codable`, so SwiftData would accept it as an attribute — but it
//  has a hand-written `init(from:)` that swallows malformed fields, and it
//  contains a `NormalisedRect` that encodes as a four-element JSON *array*.
//  SwiftData's composite-attribute machinery reflects over Codable conformances
//  and is at its least predictable exactly there: custom coding, unkeyed
//  containers, nested optionals. A blob would also make the quoted text
//  unqueryable, and quoted text is the anchor's primary key
//  (CLAUDE.md non-negotiable 5).
//
//  So: nine flat columns and one computed `anchor` accessor. Costs a few lines,
//  buys a schema that a migration can see into and a column a `#Predicate` can
//  reach.
//  ─────────────────────────────────────────────────────────────────────────────
//
//  Deletion is soft. `deletedAt` marks a comment gone; `DocumentStore` keeps a
//  session-scoped stack of what it hid so the deletion can be undone
//  (docs/02-spec.md § Cross-cutting: "Nothing is destructive without undo").
//

import Foundation
import SwiftData
import Core

/// A comment, its anchor, and whether it is still visible.
@Model
final class Comment {

    @Attribute(.unique) var id: UUID

    var createdAt: Date

    /// The text as it will be sent — already post-corrected against the document
    /// term list (docs/04-flows.md § F4).
    var text: String

    /// `CommentSource.rawValue`.
    var sourceRaw: String

    /// The page the marker is drawn on. Normally `anchorPageIndex`.
    var resolvedOnPage: Int

    // MARK: Anchor columns

    /// The selected text, untrimmed and un-collapsed.
    var anchorQuoted: String
    var anchorPrefix: String
    var anchorSuffix: String
    var anchorPageIndex: Int

    /// `NormalisedRect`, flattened. Top-left origin, y increasing downwards.
    var anchorRectX: Double
    var anchorRectY: Double
    var anchorRectWidth: Double
    var anchorRectHeight: Double

    /// `SourceRange`, flattened. Both nil together, and only non-nil when the
    /// document came from markdown and a source map was generated.
    var anchorSourceStart: Int?
    var anchorSourceEnd: Int?

    // MARK: Soft deletion

    /// When the user deleted this comment. Nil means visible. A soft-deleted
    /// comment is excluded from every read and can be restored by
    /// `DocumentStore.undoLastCommentDeletion()` for as long as the process
    /// lives.
    var deletedAt: Date?

    /// The owning document. The inverse is declared on `Document.comments`.
    var document: Document?

    init(
        id: UUID,
        createdAt: Date,
        text: String,
        sourceRaw: String,
        resolvedOnPage: Int,
        anchorQuoted: String,
        anchorPrefix: String,
        anchorSuffix: String,
        anchorPageIndex: Int,
        anchorRectX: Double,
        anchorRectY: Double,
        anchorRectWidth: Double,
        anchorRectHeight: Double,
        anchorSourceStart: Int? = nil,
        anchorSourceEnd: Int? = nil,
        deletedAt: Date? = nil,
        document: Document? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.text = text
        self.sourceRaw = sourceRaw
        self.resolvedOnPage = resolvedOnPage
        self.anchorQuoted = anchorQuoted
        self.anchorPrefix = anchorPrefix
        self.anchorSuffix = anchorSuffix
        self.anchorPageIndex = anchorPageIndex
        self.anchorRectX = anchorRectX
        self.anchorRectY = anchorRectY
        self.anchorRectWidth = anchorRectWidth
        self.anchorRectHeight = anchorRectHeight
        self.anchorSourceStart = anchorSourceStart
        self.anchorSourceEnd = anchorSourceEnd
        self.deletedAt = deletedAt
        self.document = document
    }

    /// Builds a row from a draft. The store mints `id` and `createdAt` so that
    /// two callers cannot disagree about them (DTOs.swift, `CommentDraft`).
    convenience init(draft: CommentDraft, id: UUID, createdAt: Date, document: Document?) {
        self.init(
            id: id,
            createdAt: createdAt,
            text: draft.text,
            sourceRaw: draft.source.rawValue,
            resolvedOnPage: draft.resolvedOnPage,
            anchorQuoted: draft.anchor.quoted,
            anchorPrefix: draft.anchor.prefix,
            anchorSuffix: draft.anchor.suffix,
            anchorPageIndex: draft.anchor.pageIndex,
            anchorRectX: draft.anchor.normalisedRect.x,
            anchorRectY: draft.anchor.normalisedRect.y,
            anchorRectWidth: draft.anchor.normalisedRect.width,
            anchorRectHeight: draft.anchor.normalisedRect.height,
            anchorSourceStart: draft.anchor.sourceRange?.start,
            anchorSourceEnd: draft.anchor.sourceRange?.end,
            deletedAt: nil,
            document: document
        )
    }
}

extension Comment {

    /// `sourceRaw` as the frozen enum. Unknown raw values read as `.typed`,
    /// matching `CommentSource`'s own decoder.
    var source: CommentSource {
        get { CommentSource(rawValue: sourceRaw) ?? .typed }
        set { sourceRaw = newValue.rawValue }
    }

    /// The anchor, reassembled from its columns.
    var anchor: Anchor {
        get {
            Anchor(
                quoted: anchorQuoted,
                prefix: anchorPrefix,
                suffix: anchorSuffix,
                pageIndex: anchorPageIndex,
                normalisedRect: NormalisedRect(
                    x: anchorRectX,
                    y: anchorRectY,
                    width: anchorRectWidth,
                    height: anchorRectHeight
                ),
                sourceRange: storedSourceRange
            )
        }
        set {
            anchorQuoted = newValue.quoted
            anchorPrefix = newValue.prefix
            anchorSuffix = newValue.suffix
            anchorPageIndex = newValue.pageIndex
            anchorRectX = newValue.normalisedRect.x
            anchorRectY = newValue.normalisedRect.y
            anchorRectWidth = newValue.normalisedRect.width
            anchorRectHeight = newValue.normalisedRect.height
            anchorSourceStart = newValue.sourceRange?.start
            anchorSourceEnd = newValue.sourceRange?.end
        }
    }

    /// The two source-range columns as a range, or nil when either is absent.
    var storedSourceRange: SourceRange? {
        guard let start = anchorSourceStart, let end = anchorSourceEnd else { return nil }
        return SourceRange(start: start, end: end)
    }

    /// The detached form.
    func snapshot() -> CommentSnapshot {
        CommentSnapshot(
            id: id,
            createdAt: createdAt,
            text: text,
            source: source,
            anchor: anchor,
            resolvedOnPage: resolvedOnPage
        )
    }
}
