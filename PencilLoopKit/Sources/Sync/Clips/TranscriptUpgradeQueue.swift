//
//  TranscriptUpgradeQueue.swift
//  Sync · Clips
//
//  Draft, then upgrade (notes/pencil-loop-cloud-dictation.md).
//
//  A voice comment is transcribed on the iPad and saved immediately, so there
//  is always text and dictation works on a train. This takes the recording that
//  produced it, sends it to a model that can be *told* what the document is
//  about, and replaces the words if a better version comes back.
//
//  **Nothing here is on the annotating path.** The comment is written, closed
//  and on screen before any of this runs, which is what keeps CLAUDE.md's first
//  non-negotiable true in the sense that matters: annotating never waits on the
//  network. This is a background sync, the same shape as a document arriving.
//
//  **Every failure keeps the draft.** Unreachable, refused, no key configured,
//  a provider having a bad day — all of it ends with the text the reader
//  already has, and after a day of trying the clip is deleted and the draft is
//  simply the transcript.
//

import Foundation
import os
import Core

/// Turns queued recordings into better transcripts, one at a time.
///
/// **On failure:** never throws. A clip that cannot be upgraded is deferred
/// with a longer backoff, and one that has been failing for a day is dropped.
/// The only thing a caller learns is how many comments actually changed.
public actor TranscriptUpgradeQueue {

    private static let log = Logger(subsystem: "co.pencil-loop.sync", category: "upgrade")

    private let clips: VoiceClipStore
    private let client: SyncServerClient
    private let store: any DocumentStoring

    /// True while a drain is running, so a poll landing on top of one does not
    /// start a second pass over the same directory.
    private var isDraining = false

    public init(
        client: SyncServerClient,
        store: any DocumentStoring,
        clips: VoiceClipStore = VoiceClipStore()
    ) {
        self.client = client
        self.store = store
        self.clips = clips
    }

    /// Upgrades whatever is due.
    ///
    /// - Returns: how many comments were rewritten. Zero is the normal answer
    ///   and is not a failure — it usually means there is nothing queued.
    @discardableResult
    public func drain(now: Date = Date()) async -> Int {
        guard isDraining == false else { return 0 }
        isDraining = true
        defer { isDraining = false }

        clips.sweep()
        var applied = 0
        for clip in clips.pending() where clip.isDue(at: now) {
            if Task.isCancelled { break }
            do {
                let better = try await upgrade(clip)
                if await apply(better, to: clip) { applied += 1 }
                clips.remove(commentId: clip.commentId)
            } catch {
                // Deliberately not surfaced. The reader has their comment; an
                // error about the version they were never promised would be
                // noise about a feature they cannot act on.
                TranscriptUpgradeQueue.log.notice(
                    "Upgrade deferred for \(clip.commentId, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
                clips.defer_(clip, at: now)
            }
        }
        return applied
    }

    // MARK: - One clip

    /// Declares the clip, uploads it, and reads the text back.
    ///
    /// Declare-then-upload because the keyterm list is up to a hundred phrases
    /// and does not belong in a URL — and because a retry can then re-upload
    /// without sending the document's vocabulary again.
    private func upgrade(_ clip: VoiceClip) async throws -> String {
        let audioURL = clips.audioURL(forCommentId: clip.commentId)
        let audio = try Data(contentsOf: audioURL)

        let declaration = ClipDeclaration(
            clipId: clip.commentId.uuidString,
            language: clip.language,
            keyterms: clip.keyterms
        )
        _ = try await client.post(try ContractCoding.encoder().encode(declaration), to: "/v1/clips")

        let body = try await client.put(
            audio,
            to: "/v1/clips/\(clip.commentId.uuidString)/audio",
            contentType: "audio/flac"
        )
        let result = try ContractCoding.decoder().decode(ClipResult.self, from: body)
        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.isEmpty == false else {
            throw PencilLoopError.outboxWriteFailed(reason: "The upgrade came back empty.")
        }
        return text
    }

    /// Replaces the comment's text, unless the reader has since edited it.
    ///
    /// **This is the whole of `edited_by_hand`, and it is derived rather than
    /// stored.** The sidecar remembers what the on-device engine heard; if the
    /// comment still says exactly that, nobody has touched it and the better
    /// text is strictly an improvement. If it says anything else, the reader
    /// rewrote it, and an upgrade arriving a minute later must not take that
    /// away. A stored flag would be one more thing to keep true.
    ///
    /// - Returns: whether the comment changed.
    private func apply(_ text: String, to clip: VoiceClip) async -> Bool {
        guard text != clip.draft else { return false }
        do {
            let comments = try await store.comments(documentId: clip.documentId)
            guard let current = comments.first(where: { $0.id == clip.commentId }) else {
                return false
            }
            guard current.text == clip.draft else {
                TranscriptUpgradeQueue.log.notice(
                    "\(clip.commentId, privacy: .public) was edited by hand; keeping what was written."
                )
                return false
            }
            try await store.updateComment(id: clip.commentId, text: text)
            return true
        } catch {
            TranscriptUpgradeQueue.log.notice(
                "Could not apply an upgrade: \(error.localizedDescription, privacy: .public)"
            )
            return false
        }
    }

    /// What `POST /v1/clips` takes.
    private struct ClipDeclaration: Encodable {
        let clipId: String
        let language: String
        let keyterms: [String]
    }

    /// What `PUT /v1/clips/{id}/audio` gives back.
    private struct ClipResult: Decodable {
        let text: String
    }
}
