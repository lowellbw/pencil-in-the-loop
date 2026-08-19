//
//  ReviewSentOutcome.swift
//  AppUI · Review
//
//  What the Sent screen knows (docs/02-spec.md § S5).
//
//  Everything in here is a fact the app can actually observe: bytes it built,
//  an event it received, a file that appeared. There is deliberately no field
//  for "picked up" or "agent working" — the file contract in
//  docs/05-file-contracts.md defines no signal for either, and a timeline that
//  invents them is a timeline that lies. See ReviewProgressTimeline.
//

import Foundation
import Core

/// The result of pressing Send, and everything that has happened to it since.
///
/// **Nonisolated.** AppUI's default isolation is `MainActor` (STYLE.md § 6),
/// which is right for a view and wrong for a value: this is a `Sendable`
/// aggregate of Core DTOs, and the Sent screen writes its files to a temporary
/// directory from a `nonisolated` helper so that the write happens off the main
/// actor (`ReviewSentView.exportFiles(for:)`). A main-actor-isolated value
/// cannot be read from there, and the alternative — passing its two fields as
/// loose arguments — only moves the same question one call further out.
nonisolated struct ReviewSentOutcome: Sendable, Hashable {

    /// How far the bundle has demonstrably got.
    ///
    /// `pending` is the honest state between `SyncCoordinating.send(_:)`
    /// returning and a `SyncEvent` arriving to say which of the two things
    /// happened: the bundle reached the sync folder, or it was queued because
    /// the folder was unreachable. `WrittenReview` alone cannot tell them apart
    /// — it is returned in both cases.
    enum Delivery: Sendable, Hashable {

        /// The bytes exist; the folder has not confirmed anything yet.
        case pending

        /// `SyncEvent.reviewWritten` arrived for this document.
        case written(at: Date)

        /// `SyncEvent.folderUnavailable` arrived instead. Not an error: the
        /// bundle is queued locally and goes out when the folder returns
        /// (docs/04-flows.md § F7).
        case queued(reason: String)
    }

    /// An agent's `reply.md`, once one turns up (docs/04-flows.md § F6).
    struct Reply: Sendable, Hashable {

        /// When the reply event reached us.
        var receivedAt: Date

        /// The prose, as the store recorded it
        /// (`DocumentStoring.recordReply`, read back through
        /// `reviewStatus(documentId:)`). Briefly nil between the arrival event
        /// and that read; nil for good only if the reply was empty. It used to
        /// be read from the folder directly and usually failed, because the
        /// sync folder's security scope is not open to the UI.
        var text: String?
    }

    var documentId: UUID
    var documentTitle: String

    /// What the destination row showed before the user committed.
    var path: ResolvedReturnPath

    /// `<document folder>.review`, the handle
    /// `SyncCoordinating.ingestReply(fromReviewDirectory:)` takes.
    var directoryName: String

    /// The bundle itself, kept so the fallback actions have something to copy,
    /// share and save without rebuilding it.
    var payload: OutboxPayload

    /// When the bundle finished being written.
    var builtAt: Date

    var delivery: Delivery

    var reply: Reply?

    init(
        documentId: UUID,
        documentTitle: String,
        path: ResolvedReturnPath,
        directoryName: String,
        payload: OutboxPayload,
        builtAt: Date,
        delivery: Delivery = .pending,
        reply: Reply? = nil
    ) {
        self.documentId = documentId
        self.documentTitle = documentTitle
        self.path = path
        self.directoryName = directoryName
        self.payload = payload
        self.builtAt = builtAt
        self.delivery = delivery
        self.reply = reply
    }

    var fileCount: Int { payload.files.count }

    var byteCount: Int { payload.files.reduce(0) { $0 + $1.data.count } }

    /// Rounded to whole kilobytes, never below one — a 40-byte review still
    /// took up space.
    var byteSummary: String {
        let kilobytes = max(1, byteCount / 1024)
        return "\(kilobytes) KB"
    }

    /// The prose payload, for "Copy review" and the share sheet
    /// (docs/06-integrations.md § The universal fallback).
    ///
    /// Empty only if the bundle somehow carried no `review.md`, which the
    /// builder does not permit.
    var reviewMarkdown: String {
        guard
            let file = payload.files.first(where: { $0.relativePath == DocumentFileNames.reviewMarkdown }),
            let text = String(data: file.data, encoding: .utf8)
        else {
            return ""
        }
        return text
    }

    /// The cropped ink PNGs, in bundle order. These are what the share sheet
    /// hands to the Claude app as photo attachments.
    var inkImageFiles: [BundleFile] {
        payload.files.filter { $0.relativePath.hasPrefix(InkImage.inkDirectoryName + "/") }
    }

    /// True when there is no automated way back and the screen should lead with
    /// copy / share / save. A supported outcome, never a failure
    /// (docs/06-integrations.md).
    var needsFallback: Bool { path.type == .none }
}
