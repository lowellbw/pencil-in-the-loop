//
//  SyncCursorStore.swift
//  Sync · HTTP
//
//  Where the relay's cursor lives between launches.
//
//  It is one small JSON file in the app container, beside the outbox queue and
//  under the same root, because a second container layout is how three modules
//  once ended up with three (DocumentContainer.swift). Losing it costs one
//  re-list of documents the device already has pinned, which is why it is a
//  plain file and not a database row.
//
//  ─── THE RULE THAT IS NOT AN OPTIMISATION ────────────────────────────────────
//  **A base-URL change resets the cursor.** Sequence numbers are allocated per
//  relay, so cursor 412 from one server means "you have seen everything up to
//  412" on a server that has never heard of it — and the device would then skip
//  every document that server had already numbered below 412. Silently. The
//  same argument applies to the epoch, which is exactly what it is for: a relay
//  that rebuilt its index mints a new one, and a device that sees an unfamiliar
//  epoch starts again from zero.
//  ─────────────────────────────────────────────────────────────────────────────
//

import Foundation
import Core

/// Remembers how far through one relay's change feed this device has read.
///
/// **On failure:** nothing here throws. A cursor that cannot be read is nil,
/// which costs a full re-list and nothing else; a cursor that cannot be written
/// is logged and dropped, which costs the same re-list on the next launch. Both
/// are recoverable by construction, and a sync layer that refused to run
/// because its bookkeeping file was unwritable would not be.
public struct SyncCursorStore: Sendable {

    /// What one device remembers about one relay.
    public struct State: Codable, Sendable, Hashable {

        /// The relay this cursor belongs to, as the user typed it. Compared
        /// exactly: two URLs that differ by a trailing slash are treated as two
        /// servers, which errs towards a needless re-list rather than towards
        /// skipping documents.
        public var baseURLString: String

        /// The relay's index generation. A different one means everything must
        /// be re-listed.
        public var epoch: String

        /// The last sequence number a clean page reported.
        public var cursor: Int64

        /// When it was last advanced, for the Settings status line.
        public var updatedAt: Date

        public init(baseURLString: String, epoch: String, cursor: Int64, updatedAt: Date = Date()) {
            self.baseURLString = baseURLString
            self.epoch = epoch
            self.cursor = cursor
            self.updatedAt = updatedAt
        }
    }

    /// Where the file lives.
    public var rootURL: URL

    public init(rootURL: URL = SyncCursorStore.defaultRootURL()) {
        self.rootURL = rootURL
    }

    /// `Application Support/PencilLoop/http-sync`.
    ///
    /// The container part comes from `DocumentContainer`, exactly as
    /// `OutboxQueue.defaultRootURL()` does, so there is one place that knows
    /// what this app's container is called.
    public static func defaultRootURL() -> URL {
        DocumentContainer.containerRoot()
            .appendingPathComponent(directoryName, isDirectory: true)
    }

    /// The directory inside the app container.
    public static let directoryName = "http-sync"

    /// The file's name.
    public static let fileName = "cursor.json"

    /// The file itself.
    public var fileURL: URL {
        rootURL.appendingPathComponent(SyncCursorStore.fileName, isDirectory: false)
    }

    // MARK: - Reading

    /// What is recorded for `baseURL`, or nil when nothing is.
    ///
    /// - Returns: nil when there is no file, when it cannot be read, or when it
    ///   belongs to a **different relay** — which is the reset, and the reason
    ///   this takes a base URL rather than being a plain `load()`.
    public func state(forBaseURL baseURL: URL) -> State? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        guard let state = try? ContractCoding.decoder().decode(State.self, from: data) else {
            SyncLog.scan.notice("The sync cursor could not be read; the next poll will list everything.")
            return nil
        }
        guard state.baseURLString == baseURL.absoluteString else {
            SyncLog.scan.info("The server changed, so the sync cursor starts again from the beginning.")
            return nil
        }
        return state
    }

    /// Where to resume from for `baseURL`, given the epoch the server is
    /// currently reporting.
    ///
    /// - Parameter epoch: the epoch from the page just received. Pass nil
    ///   before any page has been seen this launch.
    /// - Returns: nil — meaning "list everything" — for a new server, an
    ///   unreadable file, or an epoch that does not match the one the cursor
    ///   was recorded against.
    public func cursor(forBaseURL baseURL: URL, epoch: String?) -> Int64? {
        guard let state = state(forBaseURL: baseURL) else { return nil }
        if let epoch, state.epoch != epoch { return nil }
        return state.cursor
    }

    // MARK: - Writing

    /// Records a cursor after a clean page.
    ///
    /// **Never throws.** A cursor that will not persist costs a re-list, and a
    /// re-list costs nothing a user can see.
    public func save(cursor: Int64, epoch: String, forBaseURL baseURL: URL, at date: Date = Date()) {
        let state = State(
            baseURLString: baseURL.absoluteString,
            epoch: epoch,
            cursor: cursor,
            updatedAt: date
        )
        let manager = FileManager.default
        do {
            try manager.createDirectory(at: rootURL, withIntermediateDirectories: true)
            try ContractCoding.encoder().encode(state).write(to: fileURL, options: [.atomic])
        } catch {
            SyncLog.scan.notice("The sync cursor could not be saved. \(error.localizedDescription)")
        }
    }

    /// Forgets everything, so the next poll lists the whole library again.
    ///
    /// What "sign out", "change server" and pull-to-refresh-after-an-epoch-change
    /// all reduce to. It never removes a pinned document: the bytes are the
    /// user's, and this file is only bookkeeping.
    public func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}
