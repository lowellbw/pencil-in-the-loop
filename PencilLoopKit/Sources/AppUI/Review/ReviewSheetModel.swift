//
//  ReviewSheetModel.swift
//  AppUI · Review
//
//  The state behind the review sheet and the Sent screen (docs/02-spec.md
//  §§ S4-S5, docs/04-flows.md §§ F5-F7).
//
//  One model spans both screens on purpose: the Sent screen's only real
//  progress signals arrive on `SyncCoordinating.events()`, and that stream has
//  to be listened to from before Send is pressed until the sheet closes. Two
//  models would mean two subscriptions and a window between them where a reply
//  is missed.
//
//  Bundle building is the one expensive thing here and it never runs on the
//  main actor: `ReviewBundleBuilding.build(_:)` is a nonisolated async member
//  of a Sendable protocol, so awaiting it from this main-actor type leaves the
//  main actor for the duration (docs/03-architecture.md § Performance targets
//  gives it under 2s for 50 pages and 20 comments).
//

import Foundation
import Observation
import SwiftUI
import Core

/// Everything the review sheet collects, and everything the Sent screen learns.
@Observable
final class ReviewSheetModel {

    /// Which of the two screens the sheet is showing.
    enum Phase: Sendable, Hashable {
        case composing
        case sending
        case sent
    }

    /// The document under review. Fixed for the life of the sheet.
    let document: DocumentDetail

    /// In document order, as the store returned them. Edited in place by the
    /// rows; persisted through `DocumentStoring.updateComment(id:text:)`.
    var comments: [CommentSnapshot]

    /// The four Include toggles. Opens on `ReviewIncludeOptions.standard` —
    /// comments, ink and recognised text on, full document off — because the
    /// three layers are worth more together than any one of them alone
    /// (docs/00-brief.md).
    var include: ReviewIncludeOptions

    /// The closing instruction field. Turns a pile of notes into a request.
    var closingInstruction: String

    /// Accumulated reading time for the subtitle. Zero when never tracked, in
    /// which case the subtitle is just the title.
    var readingSeconds: TimeInterval

    /// What the destination row shows. Resolved in `load(environment:)`;
    /// `.unresolved` until then, which is the safe thing to render.
    var returnPath: ResolvedReturnPath

    var phase: Phase

    /// A sentence to show the user when something failed. Nil when nothing has.
    var failureMessage: String?

    /// True when a comment was deleted this session and the store can put it
    /// back. Nothing is destructive without undo (docs/02-spec.md
    /// § Cross-cutting).
    var canUndoDelete: Bool

    /// Set once the bundle exists. Drives the whole Sent screen.
    var outcome: ReviewSentOutcome?

    /// True while `SyncCoordinating.ingestReply(fromReviewDirectory:)` runs.
    var isOpeningReply: Bool

    /// What the store knows about a review sent for this document *before* this
    /// sheet was opened, including a reply that arrived while nothing was on
    /// screen (Protocols.swift § DocumentStoring.reviewStatus).
    ///
    /// This is the route back to a sent review that did not exist: an agent
    /// takes minutes, the user closes the sheet, and the reply used to have
    /// nowhere to land. Nil until `load(environment:)` has run, and its fields
    /// are nil for a document that has never been reviewed.
    var priorReview: ReviewStatus?

    /// Per-comment debounced saves, so typing does not hit the store on every
    /// keystroke. Cancelled and flushed before the bundle is built.
    private var pendingSaves: [UUID: Task<Void, Never>] = [:]

    /// A `reviewWritten` event that arrived before the outcome existed.
    private var confirmedWriteAt: Date?

    /// True once *this sheet* has recorded its send against the document.
    ///
    /// One delivery, one writer. The sheet records the bundle its own Send
    /// press put in `outbox/`; `SyncCoordinator.flushQueue` records a queued
    /// bundle that reached `outbox/` later, because a flush waits on the
    /// network and usually happens long after this sheet has gone. Nothing on
    /// the event path writes here, so this guards one route rather than
    /// arbitrating between two.
    private var hasRecordedSend = false

    /// A `folderUnavailable` event that arrived before the outcome existed.
    private var folderUnavailableReason: String?

    /// Kept from `load(environment:)` so that folding a sync event in can read
    /// the store back. Nil until the sheet has loaded, and in a preview, where
    /// no events arrive.
    private var environment: (any AppEnvironment)?

    /// - Parameters:
    ///   - document: everything the reader already holds. The sheet does not
    ///     re-fetch it.
    ///   - previewReadingSeconds: previews only. `PreviewEnvironment`'s store
    ///     reports zero reading time, and the subtitle is one of the things
    ///     worth previewing.
    ///   - previewOutcome: previews only. Seeds the Sent screen without
    ///     building a bundle.
    init(
        document: DocumentDetail,
        previewReadingSeconds: TimeInterval? = nil,
        previewOutcome: ReviewSentOutcome? = nil
    ) {
        self.document = document
        self.comments = document.comments
        self.include = ReviewIncludeOptions.standard
        self.closingInstruction = ""
        self.readingSeconds = previewReadingSeconds ?? 0
        self.returnPath = previewOutcome?.path ?? ResolvedReturnPath.unresolved
        self.phase = previewOutcome == nil ? .composing : .sent
        self.failureMessage = nil
        self.canUndoDelete = false
        self.outcome = previewOutcome
        self.isOpeningReply = false
        self.priorReview = nil
    }

    // MARK: - Loading

    /// Resolves the destination, reads the reading time and refreshes the
    /// comment list. Cheap, and every failure degrades to what the reader
    /// already handed over.
    func load(environment: any AppEnvironment) async {
        self.environment = environment
        returnPath = environment.returnPathResolver.resolve(document.origin)

        let settings = await environment.settings.settings
        include.inkImages = settings.sendInkedPagesAsImages

        if let seconds = try? await environment.store.readingSeconds(documentId: document.id), seconds > 0 {
            readingSeconds = seconds
        }
        if let fresh = try? await environment.store.comments(documentId: document.id), fresh.isEmpty == false {
            comments = fresh
        }

        // A review sent earlier, and any reply to it. Read here rather than
        // watched for, because the event that announced the reply may have gone
        // out while this sheet did not exist (docs/04-flows.md § F6). The
        // composer renders it from `priorReview` directly; the Sent screen,
        // which only exists after a send, takes it from `outcome.reply`.
        priorReview = try? await environment.store.reviewStatus(documentId: document.id)
    }

    /// Listens to sync for as long as the sheet is open.
    ///
    /// This is the only source of truth for what happened to the bundle after
    /// it was handed over: `SyncCoordinating.send(_:)` returns a
    /// `WrittenReview` whether it wrote or queued, so the events are what tell
    /// the two apart.
    func observe(environment: any AppEnvironment) async {
        self.environment = environment
        for await event in environment.sync.events() {
            apply(event)
        }
    }

    /// Folds one sync event into the outcome. Events for other documents are
    /// ignored.
    func apply(_ event: SyncEvent) {
        switch event {
        case let .reviewWritten(documentId, _):
            guard documentId == document.id else { return }
            let now = Date()
            confirmedWriteAt = now
            outcome?.delivery = .written(at: now)

            // A queue that has just been flushed — the one delivery this sheet
            // does not own. `SyncCoordinator.flushQueue` records it against the
            // document *before* emitting this event, because it is the only
            // component still there when a flush lands hours after the sheet
            // was closed. So by the time this arrives the store already says
            // sent, read, and in which directory; the sheet reads that back
            // rather than writing a second delivery whose only difference from
            // the first would be a worse timestamp.
            //
            // `.sending` is excluded because `send(_:)` is mid-flight with its
            // own write to `outbox/`, and that one the sheet does own — it
            // records it in `recordDelivery(of:at:environment:)`, with the date
            // the user pressed Send rather than the date the event arrived.
            if let environment, phase != .sending {
                refreshReviewStatus(environment: environment)
            }

        case let .folderUnavailable(reason):
            folderUnavailableReason = reason
            if case .pending = outcome?.delivery {
                outcome?.delivery = .queued(reason: reason)
            }

        case let .replyReceived(documentId, _):
            guard documentId == document.id else { return }
            outcome?.reply = ReviewSentOutcome.Reply(receivedAt: Date(), text: nil)
            // The text comes from the store, not from the URL the event
            // carried: Sync has already written it there
            // (`DocumentStoring.recordReply`), and reading the folder from here
            // would need a security scope the UI does not hold. It used to try
            // anyway and usually failed.
            if let environment { refreshReviewStatus(environment: environment) }

        default:
            return
        }
    }

    /// Re-reads the stored review status: when it was sent, where the bundle
    /// went, and whatever reply it holds.
    ///
    /// The sheet's way of catching up with a write somebody else made — Sync
    /// records both a flushed delivery and an arriving reply — rather than
    /// guessing at it from the event.
    func refreshReviewStatus(environment: any AppEnvironment) {
        Task { [weak self] in
            guard let self else { return }
            guard let status = try? await environment.store.reviewStatus(documentId: self.document.id) else { return }
            self.priorReview = status
            guard let text = status.replyText, text.isEmpty == false else { return }
            if self.outcome != nil {
                self.outcome?.reply = ReviewSentOutcome.Reply(
                    receivedAt: status.replyReceivedAt ?? Date(),
                    text: text
                )
            }
        }
    }

    // MARK: - Counts and copy

    /// Pages that will actually produce an image: ink present and archived
    /// bytes to render it from.
    var inkedPages: [PageSnapshot] {
        document.pages
            .filter { $0.hasInk && $0.drawingData != nil }
            .sorted { $0.pageIndex < $1.pageIndex }
    }

    var inkedPageCount: Int { inkedPages.count }

    /// Pages carrying recognised handwriting, which is what the "Recognised
    /// text" toggle actually governs.
    var recognisedPageCount: Int {
        document.pages.filter { page in
            guard let text = page.recognisedInk else { return false }
            return text.isEmpty == false
        }
        .count
    }

    /// "3 comments, 2 inked pages" (docs/02-spec.md § S4).
    var headline: String {
        let commentPart = comments.count == 1 ? "1 comment" : "\(comments.count) comments"
        let inkPart = inkedPageCount == 1 ? "1 inked page" : "\(inkedPageCount) inked pages"
        return "\(commentPart), \(inkPart)"
    }

    /// The document title, plus time spent when there is any worth reporting.
    var subtitle: String {
        guard readingSeconds >= 60 else { return document.title }
        let minutes = Int(readingSeconds / 60)
        return "\(document.title) · \(minutes) min of review"
    }

    /// The label on the one prominent button.
    var sendButtonTitle: String {
        returnPath.sameThread ? "Send back to thread" : "Send review"
    }

    /// False when there is nothing worth sending, or a send is already running.
    var canSend: Bool {
        guard phase == .composing, document.pdfURL != nil else { return false }
        if include.comments, comments.isEmpty == false { return true }
        if include.inkImages, inkedPageCount > 0 { return true }
        return trimmedInstruction.isEmpty == false
    }

    private var trimmedInstruction: String {
        closingInstruction.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Editing comments

    /// The current text of one comment, or empty when it has been deleted out
    /// from under the row.
    func text(forCommentId id: UUID) -> String {
        comments.first { $0.id == id }?.text ?? ""
    }

    /// A two-way binding for a row's text field. Writes are debounced.
    func textBinding(for id: UUID, environment: any AppEnvironment) -> Binding<String> {
        Binding(
            get: { [weak self] in self?.text(forCommentId: id) ?? "" },
            set: { [weak self] value in
                self?.setText(value, forCommentId: id, environment: environment)
            }
        )
    }

    private func setText(_ text: String, forCommentId id: UUID, environment: any AppEnvironment) {
        guard let index = comments.firstIndex(where: { $0.id == id }) else { return }
        comments[index].text = text
        pendingSaves[id]?.cancel()
        pendingSaves[id] = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            if Task.isCancelled { return }
            try? await environment.store.updateComment(id: id, text: text)
            self?.pendingSaves[id] = nil
        }
    }

    /// Writes the outstanding edits through before anything reads the store's
    /// copy.
    ///
    /// **Only the comments this sheet has actually edited.** It used to write
    /// all of them, which cost n store round trips inside the Send path's 2s
    /// budget and, worse, overwrote any comment edited elsewhere between
    /// `load(environment:)` and Send — a marker popover in the reader is the
    /// obvious one — with this sheet's older copy. A debounce task exists for
    /// exactly the comments whose text has been typed into here, so its keys are
    /// the set to write.
    func flushPendingEdits(environment: any AppEnvironment) async {
        let edited = pendingSaves.keys.sorted { $0.uuidString < $1.uuidString }
        for task in pendingSaves.values {
            task.cancel()
        }
        pendingSaves.removeAll()
        for id in edited {
            guard let text = comments.first(where: { $0.id == id })?.text else { continue }
            try? await environment.store.updateComment(id: id, text: text)
        }
    }

    /// Swipe to delete. Soft in the store, so it can be put back.
    func delete(commentId: UUID, environment: any AppEnvironment) async {
        pendingSaves[commentId]?.cancel()
        pendingSaves[commentId] = nil
        comments.removeAll { $0.id == commentId }
        do {
            try await environment.store.deleteComment(id: commentId)
            canUndoDelete = true
        } catch let error as PencilLoopError {
            failureMessage = error.message
        } catch {
            failureMessage = "That comment could not be deleted."
        }
    }

    /// Puts the last deleted comment back, with its original id and anchor.
    func undoDelete(environment: any AppEnvironment) async {
        guard let restored = try? await environment.store.undoLastCommentDeletion() else {
            canUndoDelete = false
            return
        }
        comments.append(restored)
        comments.sort(by: ReviewSheetModel.isBefore)
        canUndoDelete = false
    }

    /// Document order: page, then down the page, then oldest first.
    ///
    /// Internal rather than private so `AppUITests` can check it: it is pure,
    /// it is the order the exported bundle is numbered in, and getting it wrong
    /// renumbers every comment in a review.
    nonisolated static func isBefore(_ first: CommentSnapshot, _ second: CommentSnapshot) -> Bool {
        if first.resolvedOnPage != second.resolvedOnPage {
            return first.resolvedOnPage < second.resolvedOnPage
        }
        if first.anchor.normalisedRect.y != second.anchor.normalisedRect.y {
            return first.anchor.normalisedRect.y < second.anchor.normalisedRect.y
        }
        return first.createdAt < second.createdAt
    }

    // MARK: - Sending (docs/04-flows.md § F5)

    /// Builds the bundle off the main actor, hands it to Sync, and records the
    /// review against the document.
    ///
    /// Never throws out: every failure becomes `failureMessage` and returns the
    /// sheet to `.composing`, because a review the user cannot retry is a
    /// review they have to retype.
    func send(environment: any AppEnvironment) async {
        guard phase == .composing else { return }
        guard let pdfURL = document.pdfURL else {
            failureMessage = "This document has no local file yet, so a review cannot be built."
            return
        }

        failureMessage = nil
        phase = .sending
        // Only events from this send may describe this send. A folder that was
        // unreachable an hour ago says nothing about the write about to happen.
        confirmedWriteAt = nil
        folderUnavailableReason = nil
        await flushPendingEdits(environment: environment)

        let sentAt = Date()
        let draft = ReviewDraft(
            documentId: document.id,
            // `review.json`'s `documentId` is the id the sending tool wrote
            // into `meta.json`, which is the whole reason that field exists.
            // Our own UUID is the fallback, not the answer.
            externalDocumentId: document.externalId ?? document.id.uuidString,
            documentTitle: document.title,
            folderName: document.folderName,
            pdfURL: pdfURL,
            sourceMarkdownURL: document.sourceMarkdownURL,
            sourceMap: document.sourceMap,
            reviewedAt: sentAt,
            timeSpent: readingSeconds > 0 ? readingSeconds : nil,
            closingInstruction: trimmedInstruction,
            comments: include.comments ? comments : [],
            pages: document.pages,
            include: include,
            origin: document.origin,
            returnPath: returnPath
        )

        do {
            let payload = try await environment.bundleBuilder.build(draft)
            let written = try await environment.sync.send(payload)
            outcome = ReviewSentOutcome(
                documentId: document.id,
                documentTitle: document.title,
                path: returnPath,
                directoryName: written.directoryName,
                payload: payload,
                builtAt: written.writtenAt,
                delivery: delivery(for: written)
            )
            phase = .sent
            await recordDelivery(of: written, at: sentAt, environment: environment)
        } catch let error as PencilLoopError {
            failureMessage = error.message
            phase = .composing
        } catch {
            failureMessage = "The review could not be sent. Nothing was lost — try again."
            phase = .composing
        }
    }

    /// What a send persists, and what it deliberately does not.
    ///
    /// A bundle that reached `outbox/` is a review that has been sent: it is
    /// recorded with the directory an agent's reply will come back in, and the
    /// document leaves "Reviewing" for "Read" (docs/04-flows.md § F5).
    ///
    /// **A queued bundle is neither of those.** `WrittenReview.isQueued` means
    /// the folder was unreachable and the bytes went to the local queue in the
    /// app container, not to `outbox/` (docs/04-flows.md § F7). Recording it as
    /// sent would put a delivery in the store that has not happened: reopening
    /// the sheet would say "Sent <date> — nothing back yet", and "Open reply as
    /// document" would ask `ingestReply(fromReviewDirectory:)` for a directory
    /// that is not in the outbox to be found. What is true of a queued review is
    /// that the document has work outstanding on it, so it is put in
    /// `.reviewing` — sent-pending, which is neither sent nor un-reviewed — and
    /// the Sent screen says "Will send when online" over the same fact.
    ///
    /// The queued bundle is recorded by `SyncCoordinator.flushQueue` at the
    /// moment it reaches `outbox/`, whether or not this sheet still exists —
    /// and it usually does not, since a flush waits on the network. This sheet
    /// only reflects it, on `SyncEvent.reviewWritten`.
    private func recordDelivery(
        of written: WrittenReview,
        at sentAt: Date,
        environment: any AppEnvironment
    ) async {
        guard written.isQueued == false else {
            try? await environment.store.setState(.reviewing, documentId: document.id)
            return
        }
        await recordSent(
            at: sentAt,
            directoryName: written.directoryName,
            environment: environment
        )
    }

    /// Records one delivery, once.
    private func recordSent(
        at date: Date,
        directoryName: String,
        environment: any AppEnvironment
    ) async {
        guard hasRecordedSend == false else { return }
        hasRecordedSend = true
        try? await environment.store.recordReviewSent(
            documentId: document.id,
            at: date,
            directoryName: directoryName
        )
        try? await environment.store.setState(.read, documentId: document.id)
    }

    /// What actually happened to the bundle.
    ///
    /// `WrittenReview.isQueued` is the answer, and it is the writer's own: the
    /// UI used to infer it by racing `SyncCoordinating.events()`, whose losing
    /// side is a screen claiming a review was delivered when it is sitting in a
    /// local queue. The events are still folded in — one may have arrived while
    /// the bundle was being built, and `.reviewWritten` is what later confirms
    /// a queued bundle went out — but they are no longer how this is decided.
    private func delivery(for written: WrittenReview) -> ReviewSentOutcome.Delivery {
        if written.isQueued {
            return .queued(
                reason: folderUnavailableReason
                    ?? "The sync folder is not reachable right now."
            )
        }
        if let writtenAt = confirmedWriteAt { return .written(at: writtenAt) }
        return .written(at: written.writtenAt)
    }

    // MARK: - The reply (docs/04-flows.md § F6)

    /// Ingests `reply.md` as a new document, origin inherited.
    ///
    /// - Returns: the new document's id, or nil when it could not be opened —
    ///   including the ordinary case of there being no reply yet, which throws
    ///   `.nothingToIngest`.
    func openReply(environment: any AppEnvironment) async -> UUID? {
        // Either the review sent a moment ago, or one sent days ago whose reply
        // has only just been read back out of the store.
        guard let directoryName = outcome?.directoryName ?? priorReview?.directoryName else { return nil }
        isOpeningReply = true
        defer { isOpeningReply = false }
        do {
            return try await environment.sync.ingestReply(fromReviewDirectory: directoryName)
        } catch let error as PencilLoopError {
            failureMessage = error.message
            return nil
        } catch {
            failureMessage = "That reply could not be opened as a document."
            return nil
        }
    }
}
