//
//  AppUITestStore.swift
//  AppUITests
//
//  A `DocumentStoring` that remembers what it was asked to do.
//
//  `PreviewEnvironment`'s store accepts every write silently, which is right for
//  a preview and useless for a test whose whole question is *which* writes
//  happened: how many comments the review sheet flushed, and whether a queued
//  review was recorded as sent. This one answers reads from whatever it was
//  seeded with and keeps a log of the writes.
//

import Foundation
import Core

/// A recording store for the AppUI tests.
actor AppUITestStore: DocumentStoring {

    /// One write, as the test wants to read it back.
    enum Write: Sendable, Hashable {
        case updateComment(id: UUID, text: String)
        case reviewSent(documentId: UUID, directoryName: String)
        case state(DocState, documentId: UUID)
    }

    /// Every write, in the order it arrived.
    private(set) var writes: [Write] = []

    private var storedComments: [CommentSnapshot]
    private var storedStatus: ReviewStatus?

    init(comments: [CommentSnapshot] = [], status: ReviewStatus? = nil) {
        self.storedComments = comments
        self.storedStatus = status
    }

    // MARK: - What the tests ask

    /// The ids of every comment written through, in order.
    var updatedCommentIds: [UUID] {
        writes.compactMap { write in
            guard case let .updateComment(id, _) = write else { return nil }
            return id
        }
    }

    /// The text a comment was last written with, or nil when it was never
    /// written.
    func updatedText(forCommentId id: UUID) -> String? {
        var found: String?
        for write in writes {
            guard case let .updateComment(written, text) = write, written == id else { continue }
            found = text
        }
        return found
    }

    var recordedSends: [Write] {
        writes.filter { write in
            if case .reviewSent = write { return true }
            return false
        }
    }

    var recordedStates: [DocState] {
        writes.compactMap { write in
            guard case let .state(state, _) = write else { return nil }
            return state
        }
    }

    // MARK: - DocumentStoring

    func summaries(_ query: LibraryQuery) throws -> [DocumentSummary] { [] }

    func summary(id: UUID) throws -> DocumentSummary? { nil }

    func detail(id: UUID) throws -> DocumentDetail? { nil }

    func knownFolderNames() throws -> Set<String> { [] }

    func documentId(forFolderName folderName: String) throws -> UUID? { nil }

    @discardableResult
    func upsert(_ document: IngestedDocument) throws -> DocumentSummary {
        DocumentSummary(
            id: document.id,
            title: document.title,
            originDisplayName: document.origin.kind.displayName,
            addedAt: document.addedAt,
            pageCount: document.pageCount,
            state: .unread,
            localState: .local,
            commentCount: 0,
            hasInk: false,
            folderName: document.folderName
        )
    }

    func recordIngestFailure(folderName: String, reason: String) throws {}

    func setState(_ state: DocState, documentId: UUID) throws {
        writes.append(.state(state, documentId: documentId))
    }

    func setLastReadPage(_ pageIndex: Int, documentId: UUID) throws {}

    func setLocalState(_ state: DocumentLocalState, documentId: UUID) throws {}

    func saveDrawing(_ drawingData: Data?, pageIndex: Int, documentId: UUID) throws {}

    func saveRecognisedInk(_ text: String?, pageIndex: Int, documentId: UUID) throws {}

    func pages(documentId: UUID) throws -> [PageSnapshot] { [] }

    func drawingData(pageIndex: Int, documentId: UUID) throws -> Data? { nil }

    @discardableResult
    func addComment(_ draft: CommentDraft, documentId: UUID) throws -> CommentSnapshot {
        let saved = CommentSnapshot(
            id: UUID(),
            createdAt: Date(timeIntervalSince1970: 0),
            text: draft.text,
            source: draft.source,
            anchor: draft.anchor,
            resolvedOnPage: draft.resolvedOnPage
        )
        storedComments.append(saved)
        return saved
    }

    func updateComment(id: UUID, text: String) throws {
        writes.append(.updateComment(id: id, text: text))
        guard let index = storedComments.firstIndex(where: { $0.id == id }) else { return }
        storedComments[index].text = text
    }

    func deleteComment(id: UUID) throws {
        storedComments.removeAll { $0.id == id }
    }

    @discardableResult
    func undoLastCommentDeletion() throws -> CommentSnapshot? { nil }

    func comments(documentId: UUID) throws -> [CommentSnapshot] { storedComments }

    func recordReviewSent(documentId: UUID, at date: Date, directoryName: String) throws {
        writes.append(.reviewSent(documentId: documentId, directoryName: directoryName))
        storedStatus = ReviewStatus(
            documentId: documentId,
            sentAt: date,
            directoryName: directoryName,
            replyText: storedStatus?.replyText,
            replyReceivedAt: storedStatus?.replyReceivedAt
        )
    }

    func recordReply(documentId: UUID, text: String, receivedAt: Date) throws {
        storedStatus = ReviewStatus(
            documentId: documentId,
            sentAt: storedStatus?.sentAt,
            directoryName: storedStatus?.directoryName,
            replyText: text,
            replyReceivedAt: receivedAt
        )
    }

    func reviewStatus(documentId: UUID) throws -> ReviewStatus? {
        storedStatus ?? ReviewStatus(documentId: documentId)
    }

    func addReadingSeconds(_ seconds: TimeInterval, documentId: UUID) throws {}

    func readingSeconds(documentId: UUID) throws -> TimeInterval { 0 }

    func storageBytes() throws -> Int64 { 0 }

    func purgeArchived() throws -> Int64 { 0 }
}
