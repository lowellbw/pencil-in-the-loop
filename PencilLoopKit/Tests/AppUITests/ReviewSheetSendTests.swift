//
//  ReviewSheetSendTests.swift
//  AppUITests
//
//  What pressing Send persists, and what a queued send deliberately does not.
//
//  `SyncCoordinating.send(_:)` returns a `WrittenReview` whether the bundle
//  reached `outbox/` or went to the local queue, and `isQueued` is the only
//  thing that tells them apart (docs/04-flows.md § F7). The sheet used to render
//  that distinction — "Will send when online" — and then record a delivery
//  anyway: `recordReviewSent` with a directory inside the app container, and the
//  document moved to "Read" on the strength of a send that had not happened. The
//  next time the sheet opened it said "Sent <date> — nothing back yet", and
//  "Open reply as document" asked `ingestReply(fromReviewDirectory:)` for a
//  directory that was not in the outbox to be found.
//
//  One delivery, one writer. The sheet records the bundle its own Send press put
//  in `outbox/`; `SyncCoordinator.flushQueue` records a bundle that got there
//  later, because a queue flush waits on the network and by then this sheet has
//  usually been closed for hours. What is asserted here is the sheet's half —
//  including that it stays out of the half it does not own.
//

import Foundation
import XCTest
@testable import AppUI
import Core

@MainActor
final class ReviewSheetSendTests: XCTestCase {

    // MARK: - Written

    /// The ordinary case: the folder was there.
    func testAWrittenReviewIsRecordedAndTheDocumentIsRead() async {
        let store = AppUITestStore()
        let environment = AppUITestEnvironment(store: store, sync: AppUITestSyncCoordinator())
        let model = ReviewSheetModel(document: AppUITestSamples.detail())
        model.closingInstruction = "Have a look at the token rotation."

        await model.send(environment: environment)

        XCTAssertEqual(model.phase, .sent)
        let sends = await store.recordedSends
        XCTAssertEqual(sends.count, 1, "A bundle in outbox/ is a review that has been sent.")
        let states = await store.recordedStates
        XCTAssertEqual(states, [.read], "Reviewed and sent is the end of the reading lifecycle.")
    }

    // MARK: - Queued

    /// The folder was unreachable, so the bytes are in the app container.
    func testAQueuedReviewIsNotRecordedAsSent() async {
        let store = AppUITestStore()
        let environment = AppUITestEnvironment(
            store: store,
            sync: AppUITestSyncCoordinator(isQueued: true)
        )
        let model = ReviewSheetModel(document: AppUITestSamples.detail())
        model.closingInstruction = "Have a look at the token rotation."

        await model.send(environment: environment)

        XCTAssertEqual(model.phase, .sent)
        guard case .queued? = model.outcome?.delivery else {
            XCTFail("A queued write must be rendered as queued.")
            return
        }

        let sends = await store.recordedSends
        XCTAssertTrue(sends.isEmpty, "Nothing reached outbox/, so there is no delivery to record.")
        let states = await store.recordedStates
        XCTAssertEqual(
            states,
            [.reviewing],
            "Sent-pending is neither sent nor un-reviewed: the document stays under Reviewing."
        )
    }

    /// The queue is flushed while the Sent screen is still up.
    ///
    /// The delivery is real and is recorded — by `SyncCoordinator.flushQueue`,
    /// which is the only component still there when a flush lands hours after
    /// the sheet was closed, and which records it *before* emitting the event
    /// this sheet is reacting to. The sheet's job here is to render the news and
    /// read the store back, not to write a second delivery: two writers for one
    /// delivery is a store whose `sentAt` depends on which of them lost the
    /// race.
    func testAFlushedQueueIsShownButNotRecordedBySheet() async throws {
        let document = AppUITestSamples.detail()
        let directoryName = OutboxPayload.directoryName(forDocumentFolder: document.folderName)
        let store = AppUITestStore()
        let environment = AppUITestEnvironment(
            store: store,
            sync: AppUITestSyncCoordinator(isQueued: true)
        )
        let model = ReviewSheetModel(document: document)
        model.closingInstruction = "Have a look at the token rotation."

        // `apply(_:)` reads through the environment `load` handed it, which is
        // how the sheet is wired on screen (ReviewSheet § .task).
        await model.load(environment: environment)
        await model.send(environment: environment)

        // The queue flushes. `SyncCoordinator.flushQueue` writes the bundle to
        // `outbox/`, records the delivery, and only then emits — these two
        // calls stand in for it, in that order.
        try await store.recordReviewSent(
            documentId: document.id,
            at: Date(timeIntervalSince1970: 1_787_000_000),
            directoryName: directoryName
        )
        try await store.setState(.read, documentId: document.id)
        let writesBeforeEvent = await store.writes

        model.apply(
            .reviewWritten(
                documentId: document.id,
                directoryURL: AppUITestSyncCoordinator.directoryURL(
                    for: directoryName,
                    isQueued: false
                )
            )
        )
        await ReviewSheetSendTests.settle()

        guard case .written? = model.outcome?.delivery else {
            XCTFail("The bundle is in outbox/ now, and the Sent screen has to say so.")
            return
        }
        let writesAfterEvent = await store.writes
        XCTAssertEqual(
            writesAfterEvent,
            writesBeforeEvent,
            "Sync recorded this delivery before the event; a second write here only races its own timestamp."
        )
        let states = await store.recordedStates
        XCTAssertEqual(
            states,
            [.reviewing, .read],
            "Reviewing is the sheet's own write for a queued bundle; Read is Sync's, and there is one of each."
        )
        XCTAssertEqual(
            model.priorReview?.directoryName,
            directoryName,
            "and the sheet reads back what Sync recorded, so 'Open reply as document' has its directory"
        )
    }

    // MARK: - Waiting

    /// Long enough for a write that should not happen to have happened.
    private static func settle() async {
        try? await Task.sleep(for: .milliseconds(50))
    }
}
