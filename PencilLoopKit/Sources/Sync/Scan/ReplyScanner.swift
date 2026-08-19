//
//  ReplyScanner.swift
//  Sync · Scan
//
//  Finds `outbox/<slug>.review/reply.md` (docs/04-flows.md § F6).
//
//  This is the half of the loop the app does not initiate: an agent writes a
//  reply into the bundle we sent, and the Sent screen shows it inline with an
//  option to open it as a new document. Like everything else here it is found
//  by looking, not by being told — the same reasoning as the inbox watcher.
//

import Foundation
import Core

/// Looks for replies in `outbox/`.
///
/// **On failure:** returns an empty array. A missing or unreadable `outbox/` is
/// not an error worth surfacing — it means there are no replies, and the app
/// carries on. Genuine folder trouble is reported by the watcher's reachability
/// check, in one place, rather than by every scan separately.
public struct ReplyScanner: Sendable {

    /// One reply found on disk.
    public struct Reply: Sendable, Hashable {

        /// `2026-08-18-auth-refactor-plan.review`.
        public var reviewDirectoryName: String

        /// `2026-08-18-auth-refactor-plan` — the handle
        /// `DocumentStoring.documentId(forFolderName:)` takes.
        public var documentFolderName: String

        /// The `reply.md` itself.
        public var replyURL: URL

        /// When it last changed, so an edited reply is noticed as new.
        public var modifiedAt: Date

        public init(
            reviewDirectoryName: String,
            documentFolderName: String,
            replyURL: URL,
            modifiedAt: Date
        ) {
            self.reviewDirectoryName = reviewDirectoryName
            self.documentFolderName = documentFolderName
            self.replyURL = replyURL
            self.modifiedAt = modifiedAt
        }
    }

    public init() {}

    /// Every reply currently sitting in `outbox/`, in directory-name order.
    ///
    /// - Parameter folder: the sync root. The caller must already hold access.
    public func scan(_ folder: SyncFolder) -> [Reply] {
        let manager = FileManager.default
        guard let entries = try? manager.contentsOfDirectory(
            at: folder.outboxURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var replies: [Reply] = []
        for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let name = entry.lastPathComponent
            if SyncFileNames.isHidden(name) { continue }
            guard name.hasSuffix(OutboxPayload.reviewDirectorySuffix) else { continue }

            let replyURL = entry.appendingPathComponent(DocumentFileNames.reply, isDirectory: false)
            guard manager.fileExists(atPath: replyURL.path) else { continue }

            let values = try? replyURL.resourceValues(forKeys: [.contentModificationDateKey])
            replies.append(Reply(
                reviewDirectoryName: name,
                documentFolderName: ReplyScanner.documentFolderName(forReviewDirectory: name),
                replyURL: replyURL,
                modifiedAt: values?.contentModificationDate ?? Date(timeIntervalSince1970: 0)
            ))
        }
        return replies
    }

    /// Strips `.review` off a bundle directory name.
    ///
    /// The only place the suffix is removed, as
    /// `OutboxPayload.directoryName(forDocumentFolder:)` is the only place it
    /// is added.
    public static func documentFolderName(forReviewDirectory name: String) -> String {
        guard name.hasSuffix(OutboxPayload.reviewDirectorySuffix) else { return name }
        return String(name.dropLast(OutboxPayload.reviewDirectorySuffix.count))
    }
}
