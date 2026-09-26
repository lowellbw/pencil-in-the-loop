//
//  VoiceClipStore.swift
//  Sync · Clips
//
//  The upgrade queue, which is a directory
//  (notes/pencil-loop-cloud-dictation.md).
//
//  Two files per pending recording, named by the comment they became:
//
//      Clips/<commentId>.flac    the audio
//      Clips/<commentId>.json    the VoiceClip sidecar
//
//  There is no table of pending work, deliberately. A queue kept anywhere but
//  the disk it describes is a queue that can disagree with it — a row for a clip
//  that was never written, or a clip nobody remembers needing. Here the pair
//  being present *is* the pending work, so a crash between the two writes leaves
//  an orphan that a later sweep tidies rather than a lie that survives. Later,
//  not next: a recording in progress looks exactly like that orphan, which is
//  what `VoiceClipStore.orphanGracePeriod` is for.
//
//  Nothing here is coordinated with `NSFileCoordinator`: these files are in the
//  app's own container, not the user's synced folder, and nothing outside this
//  process ever opens them.
//

import Foundation
import os
import Core

/// Reads and writes the clips waiting for a better transcript.
///
/// **On failure:** every read returns nil or an empty list and every write is
/// silently dropped. A queue that cannot be read costs later upgrades, never a
/// comment — the draft is already saved in the library by the time anything here
/// runs, and that is the whole reason this can afford to be quiet.
public struct VoiceClipStore: Sendable {

    private static let log = Logger(subsystem: "co.pencil-loop.sync", category: "clips")

    private let root: URL

    /// - Parameter root: the clips directory. Defaults to the app container's.
    public init(root: URL = DocumentContainer.clipsRoot()) {
        self.root = root
    }

    /// Where the audio for one comment goes.
    public func audioURL(forCommentId commentId: UUID) -> URL {
        root.appendingPathComponent(commentId.uuidString + ".flac", isDirectory: false)
    }

    /// Where its sidecar goes.
    public func sidecarURL(forCommentId commentId: UUID) -> URL {
        root.appendingPathComponent(commentId.uuidString + ".json", isDirectory: false)
    }

    /// Records that a clip needs upgrading.
    ///
    /// Written after the audio, and atomically, so a sweep never reads a
    /// half-written sidecar — and so an interrupted save leaves audio with no
    /// sidecar, which `sweep()` cleans up, rather than a sidecar naming audio
    /// that is not there.
    ///
    /// - Returns: whether it was written. False means no upgrade will be
    ///   attempted, which costs the draft nothing.
    @discardableResult
    public func enqueue(_ clip: VoiceClip) -> Bool {
        guard FileManager.default.fileExists(atPath: audioURL(forCommentId: clip.commentId).path) else {
            VoiceClipStore.log.notice("No audio for \(clip.commentId, privacy: .public); not queued.")
            return false
        }
        do {
            let data = try ContractCoding.encoder().encode(clip)
            try data.write(to: sidecarURL(forCommentId: clip.commentId), options: [.atomic])
            return true
        } catch {
            VoiceClipStore.log.notice("Could not queue a clip: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// Every clip waiting, oldest first.
    ///
    /// Oldest first because a comment dictated ten minutes ago is more likely to
    /// still be on screen than one from yesterday, and because a queue that
    /// drains in the order it filled is one whose behaviour can be predicted
    /// from the outside.
    public func pending() -> [VoiceClip] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: root.path) else {
            return []
        }
        var clips: [VoiceClip] = []
        for name in names where name.hasSuffix(".json") && name.hasPrefix(".") == false {
            let url = root.appendingPathComponent(name, isDirectory: false)
            guard let data = try? Data(contentsOf: url),
                  let clip = try? ContractCoding.decoder().decode(VoiceClip.self, from: data)
            else { continue }
            clips.append(clip)
        }
        return clips.sorted { $0.createdAt < $1.createdAt }
    }

    /// Puts a clip back with its attempt count raised, or removes it when it has
    /// been trying for a day.
    public func defer_(_ clip: VoiceClip, at now: Date = Date()) {
        guard let next = clip.deferred(from: now) else {
            VoiceClipStore.log.notice("Giving up on \(clip.commentId, privacy: .public); the draft stands.")
            remove(commentId: clip.commentId)
            return
        }
        enqueue(next)
    }

    /// Removes a clip and its sidecar. Done, given up on, or never wanted.
    public func remove(commentId: UUID) {
        try? FileManager.default.removeItem(at: sidecarURL(forCommentId: commentId))
        try? FileManager.default.removeItem(at: audioURL(forCommentId: commentId))
    }

    /// How long a file may sit without its partner before `sweep()` calls it
    /// an orphan.
    ///
    /// Unpaired is not the same as abandoned. A recording in progress is audio
    /// with no sidecar — it is written here, under its own name, and gets a
    /// sidecar only once its comment is saved — and so, for the moment between
    /// the rename and `enqueue`, is a clip being filed. The sweep runs on every
    /// sync poll, every fifteen seconds, and deleted both: any comment longer
    /// than the gap to the next poll lost its audio mid-sentence, and with it
    /// the better transcript it was recorded for. Both are written to
    /// continuously or were a moment ago, so an hour since the last write is
    /// far past either and still tidies a real orphan the same day.
    public static let orphanGracePeriod: TimeInterval = 60 * 60

    /// Deletes audio with no sidecar and sidecars with no audio, once they
    /// have been that way for `orphanGracePeriod`.
    ///
    /// The first is a recording whose comment was never saved — the reader
    /// cancelled, or the save threw — and the second is a queue entry that can
    /// never be satisfied. Both are dead weight in a directory that is otherwise
    /// the only record of what is outstanding.
    ///
    /// - Returns: how many files were removed.
    @discardableResult
    public func sweep(now: Date = Date()) -> Int {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: root.path) else {
            return 0
        }
        let audio = Set(names.filter { $0.hasSuffix(".flac") }.map { String($0.dropLast(5)) })
        let sidecars = Set(names.filter { $0.hasSuffix(".json") }.map { String($0.dropLast(5)) })
        var removed = 0
        for orphan in audio.symmetricDifference(sidecars) {
            guard let commentId = UUID(uuidString: orphan),
                  isStale(commentId: commentId, now: now) else { continue }
            remove(commentId: commentId)
            removed += 1
        }
        return removed
    }

    /// Whether neither of a clip's files has been written to within
    /// `orphanGracePeriod`. A file whose date cannot be read counts as stale,
    /// which is what the sweep did with every orphan before there was a grace.
    private func isStale(commentId: UUID, now: Date) -> Bool {
        let paths = [audioURL(forCommentId: commentId).path, sidecarURL(forCommentId: commentId).path]
        for path in paths {
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
                  let modified = attributes[.modificationDate] as? Date else { continue }
            if now.timeIntervalSince(modified) < VoiceClipStore.orphanGracePeriod {
                return false
            }
        }
        return true
    }
}
