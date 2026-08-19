//
//  AppUITestSyncCoordinator.swift
//  AppUITests
//
//  A `SyncCoordinating` whose `send(_:)` answers whatever the test needs it to:
//  a bundle in `outbox/`, or one in the local queue.
//
//  The distinction is the whole subject of `ReviewSheetSendTests` —
//  `WrittenReview.isQueued` is returned in both cases and is the only thing that
//  tells them apart (Core/Contracts/DTOs.swift § WrittenReview).
//

import Foundation
import Core

/// A sync coordinator that writes nothing and reports what it was told to.
actor AppUITestSyncCoordinator: SyncCoordinating {

    /// What the next `send(_:)` reports.
    private let isQueued: Bool

    private(set) var sentPayloads: [OutboxPayload] = []

    init(isQueued: Bool = false) {
        self.isQueued = isQueued
    }

    func start() async {}

    func stop() async {}

    func refresh() async throws -> Int { 0 }

    /// No events: the review sheet's own `apply(_:)` is driven directly in the
    /// tests, which is the only way to place an event at a chosen moment.
    nonisolated func events() -> AsyncStream<SyncEvent> {
        AsyncStream { continuation in continuation.finish() }
    }

    func send(_ payload: OutboxPayload) async throws -> WrittenReview {
        sentPayloads.append(payload)
        return WrittenReview(
            documentId: payload.documentId,
            directoryURL: AppUITestSyncCoordinator.directoryURL(
                for: payload.directoryName,
                isQueued: isQueued
            ),
            directoryName: payload.directoryName,
            writtenAt: Date(timeIntervalSince1970: 1_787_000_000),
            fileCount: payload.files.count,
            byteCount: payload.files.reduce(0) { $0 + Int64($1.data.count) },
            isQueued: isQueued
        )
    }

    @discardableResult
    nonisolated func ingestReply(fromReviewDirectory reviewDirectoryName: String) async throws -> UUID {
        throw PencilLoopError.nothingToIngest(folderName: reviewDirectoryName)
    }

    /// A queued bundle lives in the app container; a written one lives in
    /// `outbox/`. The paths are what the Sent screen's "Open reply as document"
    /// would eventually be pointed at.
    static func directoryURL(for directoryName: String, isQueued: Bool) -> URL {
        let root = isQueued ? "/tmp/container/queue" : "/tmp/folder/outbox"
        return URL(fileURLWithPath: root).appendingPathComponent(directoryName, isDirectory: true)
    }
}
