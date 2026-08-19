//
//  OutboxQueue.swift
//  Sync · Write
//
//  Where a review waits when the folder is not there (docs/04-flows.md § F7).
//
//  "The bundle is written locally and syncs whenever the connection returns;
//  the Sent screen says 'will send when online' rather than failing."
//
//  The queue lives in the app container, not in the sync folder — the sync
//  folder is a published contract and a half-sent review is not part of it. A
//  queued bundle is a real directory of real files, in exactly the layout it
//  will have in `outbox/`, so it can be inspected with Files.app and so
//  flushing it is a copy rather than a re-render.
//

import Foundation
import Core

/// Reviews written while the sync folder was unreachable.
///
/// **On failure:** `enqueue(_:)` throws `.outboxWriteFailed(reason:)` when even
/// the local queue cannot be written, which is the only case in which the user
/// is told a review could not be saved. Reading a malformed queue entry never
/// throws: it is skipped and logged, because one bad entry must not strand the
/// rest.
public struct OutboxQueue: Sendable {

    /// The sidecar that makes a queued directory a queued *bundle*.
    ///
    /// Written last, so a directory without one is a copy that did not finish
    /// and is ignored rather than half-sent.
    public struct Ticket: Codable, Sendable, Hashable {

        /// The document the review belongs to.
        public var documentId: UUID

        /// `<document folder name>.review`.
        public var directoryName: String

        /// When it was queued, which is the order it will be sent in.
        public var queuedAt: Date

        public init(documentId: UUID, directoryName: String, queuedAt: Date) {
            self.documentId = documentId
            self.directoryName = directoryName
            self.queuedAt = queuedAt
        }
    }

    /// Where queued bundles live.
    public var rootURL: URL

    public init(rootURL: URL = OutboxQueue.defaultRootURL()) {
        self.rootURL = rootURL
    }

    /// `Application Support/PencilLoop/outbox-queue`.
    ///
    /// The container part comes from `DocumentContainer` rather than being
    /// spelled again here: three modules once invented three layouts, and a
    /// queue root that spells its own would strand queued-but-unsent reviews
    /// silently the day the container name changes (STYLE.md § 9).
    public static func defaultRootURL() -> URL {
        DocumentContainer.containerRoot()
            .appendingPathComponent(queueDirectoryName, isDirectory: true)
    }

    /// The queue's directory inside the app container.
    public static let queueDirectoryName = "outbox-queue"

    /// The sidecar's file name.
    public static let ticketFileName = ".queued.json"

    /// Writes a payload to the queue.
    ///
    /// - Returns: the queued directory, which is what the Sent screen shows as
    ///   "where it landed" until the folder comes back.
    /// - Throws: `.outboxWriteFailed(reason:)`.
    @discardableResult
    public func enqueue(_ payload: OutboxPayload) throws -> URL {
        let manager = FileManager.default
        let destination = rootURL.appendingPathComponent(payload.directoryName, isDirectory: true)
        let staging = rootURL.appendingPathComponent(
            SyncFileNames.stagingName(for: payload.directoryName, token: UUID().uuidString),
            isDirectory: true
        )
        // Anything a previous process left half-written here is debris nothing
        // else removes: `queuedPayloads()` skips hidden entries, so it would sit
        // in the app container for ever.
        StagingSweeper.sweep(in: rootURL)

        do {
            try manager.createDirectory(at: staging, withIntermediateDirectories: true)
            for file in OutboxWriter.writeOrder(for: payload.files) {
                let target = staging.appendingPathComponent(file.relativePath, isDirectory: false)
                let parent = target.deletingLastPathComponent()
                if parent.path != staging.path {
                    try manager.createDirectory(at: parent, withIntermediateDirectories: true)
                }
                try file.data.write(to: target, options: [.atomic])
            }
            let ticket = Ticket(
                documentId: payload.documentId,
                directoryName: payload.directoryName,
                queuedAt: Date()
            )
            let ticketURL = staging.appendingPathComponent(OutboxQueue.ticketFileName, isDirectory: false)
            try ContractCoding.encoder().encode(ticket).write(to: ticketURL, options: [.atomic])

            if manager.fileExists(atPath: destination.path) {
                try manager.removeItem(at: destination)
            }
            try manager.moveItem(at: staging, to: destination)
            SyncLog.outbox.info("Queued \(payload.directoryName) until the folder is reachable.")
            return destination
        } catch {
            try? manager.removeItem(at: staging)
            throw PencilLoopError.outboxWriteFailed(
                reason: "The review could not be saved for later. \(error.localizedDescription)"
            )
        }
    }

    /// Everything waiting, oldest first.
    ///
    /// Never throws: a queue directory that cannot be read is logged and
    /// skipped. An unreadable entry is a lost review, and a lost review must
    /// not also block the ones behind it.
    public func queuedPayloads() -> [OutboxPayload] {
        let manager = FileManager.default
        guard let entries = try? manager.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var pairs: [(ticket: Ticket, payload: OutboxPayload)] = []
        for entry in entries {
            if SyncFileNames.isHidden(entry.lastPathComponent) { continue }
            guard let ticket = ticket(inDirectory: entry) else {
                SyncLog.outbox.notice("Ignoring \(entry.lastPathComponent): no queue ticket, so the copy did not finish.")
                continue
            }
            let files = OutboxQueue.bundleFiles(in: entry)
            guard files.isEmpty == false else { continue }
            pairs.append((ticket, OutboxPayload(
                directoryName: ticket.directoryName,
                documentId: ticket.documentId,
                files: files
            )))
        }
        return pairs.sorted { $0.ticket.queuedAt < $1.ticket.queuedAt }.map { $0.payload }
    }

    /// Whether anything is waiting.
    public var isEmpty: Bool {
        queuedPayloads().isEmpty
    }

    /// Drops a queued bundle, after it has been written to `outbox/`.
    public func remove(_ directoryName: String) {
        try? FileManager.default.removeItem(
            at: rootURL.appendingPathComponent(directoryName, isDirectory: true)
        )
    }

    // MARK: - Internals

    private func ticket(inDirectory directoryURL: URL) -> Ticket? {
        let url = directoryURL.appendingPathComponent(OutboxQueue.ticketFileName, isDirectory: false)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? ContractCoding.decoder().decode(Ticket.self, from: data)
    }

    /// Every file in a queued directory except the ticket, with
    /// bundle-relative paths.
    static func bundleFiles(in directoryURL: URL) -> [BundleFile] {
        let manager = FileManager.default
        guard let entries = manager.enumerator(atPath: directoryURL.path) else { return [] }

        var files: [BundleFile] = []
        for case let relative as String in entries {
            if relative == OutboxQueue.ticketFileName { continue }
            if relative.hasPrefix(".") { continue }
            let url = directoryURL.appendingPathComponent(relative)
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey])
            if values?.isDirectory == true { continue }
            guard let data = try? Data(contentsOf: url) else { continue }
            files.append(BundleFile(relativePath: relative, data: data))
        }
        return OutboxWriter.writeOrder(for: files.sorted { $0.relativePath < $1.relativePath })
    }
}
