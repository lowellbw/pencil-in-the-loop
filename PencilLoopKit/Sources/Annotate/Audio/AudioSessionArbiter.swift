//
//  AudioSessionArbiter.swift
//  Annotate · Audio
//
//  One audio session, two things that want it.
//
//  ─── WHY THIS EXISTS ─────────────────────────────────────────────────────────
//  There is one `AVAudioSession` per process, and until narration there was one
//  claimant: `MicrophoneCapture.prewarm()` set `.record` / `.measurement` and
//  `stopCapture()` deactivated it. That was safe precisely because nothing ever
//  played anything.
//
//  It stops being safe the moment a narration is running. `prewarm()` is called
//  *speculatively*, on a Pencil long-press that might become a comment — so
//  resting the Pencil on the page while listening would have silenced the audio,
//  and released the session afterwards without putting playback back.
//
//  So the session gets an owner. Nothing else in the app may call
//  `setCategory`; both callers ask for what they need and are given it in the
//  order that matters:
//
//    · recording always wins — a comment being dictated is the thing the user is
//      doing right now, and losing a spoken sentence is the worst failure this
//      app has;
//    · playback yields to it by ducking rather than stopping, so listening
//      resumes afterwards instead of having to be found again;
//    · when nobody wants it, the session is deactivated and other audio
//      unducks — which is what it did before, and is why music does not stay
//      quiet after a comment.
//  ─────────────────────────────────────────────────────────────────────────────
//
//  ─── WHAT TO CHECK BY HAND, ON A DEVICE ──────────────────────────────────────
//  None of this can be unit tested: there is no audio session anywhere but a
//  real iPad (STYLE.md § 10). With a narration playing:
//
//  1. Rest the Pencil on the page to pre-warm. The narration must keep playing.
//  2. Actually dictate a comment. The narration ducks, the transcript is right,
//     and playback comes back when you let go.
//  3. Lock the iPad mid-narration: it keeps going, and the lock screen shows the
//     document's title.
//  4. Play music, then start a narration: the music stops, as it should — this
//     is `.playback`, not a notification sound.
//  ─────────────────────────────────────────────────────────────────────────────
//

import Foundation
import AVFoundation
import os
import Core

/// Who owns the audio session right now.
///
/// **On failure:** every method is best-effort and non-throwing except
/// `beginRecording()`, which throws what `MicrophoneCapture` already throws so
/// the popover can say the microphone is unavailable. A session that will not
/// configure costs the feature asking for it, never the other one.
public actor AudioSessionArbiter {

    /// The shared owner. One session, so one arbiter.
    public static let shared = AudioSessionArbiter()

    private static let log = Logger(subsystem: "co.pencil-loop.annotate", category: "session")

    /// What the session is currently configured for. Nil means inactive.
    private enum Holder {
        case recording
        case playback
    }

    private var holder: Holder?

    /// True while a recording has taken the session from a playback that wants
    /// it back. The player asks after `endRecording()` and resumes itself.
    private var playbackWasInterrupted = false

    private init() {}

    // MARK: - Recording

    /// Claims the session for dictation. Recording always wins.
    ///
    /// - Throws: `PencilLoopError.speechUnavailable` when the session will not
    ///   take the category, which is what the comment popover reports.
    public func beginRecording() throws {
        if holder == .playback {
            // Not stopped — ducked, and remembered, so the reader gets their
            // narration back rather than having to find their place again.
            playbackWasInterrupted = true
        }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: [.duckOthers])
            try session.setActive(true, options: [])
        } catch {
            throw PencilLoopError.speechUnavailable(
                reason: "The microphone could not be started. \(error.localizedDescription)"
            )
        }
        holder = .recording
    }

    /// Gives the session back after a recording.
    ///
    /// - Returns: whether a narration was playing when the recording took the
    ///   session, and should now be resumed.
    @discardableResult
    public func endRecording() -> Bool {
        guard holder == .recording else { return false }
        let resume = playbackWasInterrupted
        playbackWasInterrupted = false
        if resume {
            // Straight back to playback rather than through an inactive
            // session: deactivating and reactivating would duck and unduck
            // other audio for no reason the listener could explain.
            configurePlayback()
        } else {
            deactivate()
        }
        return resume
    }

    // MARK: - Playback

    /// Claims the session for a narration.
    ///
    /// Refused while a recording holds it — a narration starting mid-dictation
    /// would talk over the person being transcribed.
    ///
    /// - Returns: whether playback may start.
    public func beginPlayback() -> Bool {
        guard holder != .recording else { return false }
        configurePlayback()
        return holder == .playback
    }

    /// Gives the session back after playback, if playback still holds it.
    public func endPlayback() {
        guard holder == .playback else { return }
        playbackWasInterrupted = false
        deactivate()
    }

    // MARK: - Internals

    private func configurePlayback() {
        do {
            let session = AVAudioSession.sharedInstance()
            // `.playback` is what makes this audio rather than a sound effect:
            // it keeps playing with the screen locked and puts the app in the
            // Now Playing slot, which `.ambient` and `.soloAmbient` do not.
            try session.setCategory(.playback, mode: .spokenAudio)
            try session.setActive(true, options: [])
            holder = .playback
        } catch {
            AudioSessionArbiter.log.notice(
                "Playback session refused: \(error.localizedDescription, privacy: .public)"
            )
            holder = nil
        }
    }

    private func deactivate() {
        do {
            try AVAudioSession.sharedInstance().setActive(
                false,
                options: .notifyOthersOnDeactivation
            )
        } catch {
            AudioSessionArbiter.log.debug(
                "Audio session stayed active: \(error.localizedDescription, privacy: .public)"
            )
        }
        holder = nil
    }
}
