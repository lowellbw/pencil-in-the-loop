//
//  VoiceClip.swift
//  Core · Contracts
//
//  One recording waiting for a better transcript
//  (notes/pencil-loop-cloud-dictation.md).
//
//  This is the sidecar written beside `<commentId>.flac`, and the two files
//  together *are* the queue: there is no table of pending work to keep in step
//  with the disk, so a clip cannot be orphaned by a crash between writing the
//  audio and recording that it needs doing.
//

import Foundation

/// What the upgrade needs to know about one recording.
///
/// **The draft is here as well as in the comment, and that is the point.** When
/// the upgrade lands, the stored comment is compared against `draft`: if they
/// still match, nobody has touched it and the better text can replace it. If
/// they differ, the reader edited it by hand, and a late upgrade must not
/// overwrite what they wrote. That is `edited_by_hand` from the design note,
/// derived rather than stored — a flag would be one more thing to keep true.
public struct VoiceClip: Codable, Sendable, Hashable, Identifiable {

    /// The comment this recording became. Also the clip's file name.
    public var commentId: UUID

    public var id: UUID { commentId }

    /// The document the comment is on, so the upgrade can be applied and the
    /// keyterms explained.
    public var documentId: UUID

    /// What the on-device engine heard. The thing being improved on, and the
    /// thing that stands if the upgrade never arrives.
    public var draft: String

    /// BCP-47, as chosen in Settings. Providers want to be told.
    public var language: String

    /// Document jargon, ranked, from `TranscriptCorrecting.terms(forDocumentText:title:)`.
    ///
    /// **The whole trick, per the note.** A context-free model turns "RIIO-3"
    /// into "R I O three"; a model told the document's own vocabulary does not.
    /// Sent as terms rather than prose on purpose — a term list discloses far
    /// less than the paragraph it came from.
    public var keyterms: [String]

    public var createdAt: Date

    /// How many times an upgrade has been attempted and failed.
    public var attempts: Int

    /// When the next attempt may run. Backoff lives on disk so it survives a
    /// relaunch, rather than resetting every time the app opens and hammering
    /// a provider that is down.
    public var nextAttemptAt: Date

    public init(
        commentId: UUID,
        documentId: UUID,
        draft: String,
        language: String,
        keyterms: [String] = [],
        createdAt: Date = Date(),
        attempts: Int = 0,
        nextAttemptAt: Date = Date()
    ) {
        self.commentId = commentId
        self.documentId = documentId
        self.draft = draft
        self.language = language
        self.keyterms = keyterms
        self.createdAt = createdAt
        self.attempts = attempts
        self.nextAttemptAt = nextAttemptAt
    }

    /// Retry at 2s, 8s, 30s, 2min, then hourly, then give up after a day and
    /// keep the draft permanently (design note, "online / offline behaviour").
    ///
    /// - Returns: the clip to write back, or nil when it has been trying for
    ///   long enough that the answer is "the draft is what you get".
    public func deferred(from now: Date = Date()) -> VoiceClip? {
        guard now.timeIntervalSince(createdAt) < VoiceClip.giveUpAfter else { return nil }
        let gaps: [TimeInterval] = [2, 8, 30, 120]
        let gap = attempts < gaps.count ? gaps[attempts] : 3600
        var next = self
        next.attempts = attempts + 1
        next.nextAttemptAt = now.addingTimeInterval(gap)
        return next
    }

    /// A day of trying is enough. After that the draft is the transcript, and
    /// the clip is removed rather than kept forever against a better model.
    public static let giveUpAfter: TimeInterval = 24 * 60 * 60

    /// Whether this clip is due, given the clock.
    public func isDue(at now: Date = Date()) -> Bool {
        nextAttemptAt <= now
    }
}
