//
//  NarrationPlayer.swift
//  Annotate · Audio
//
//  Playing a document.
//
//  `AVAudioPlayer` rather than `AVPlayer`: the file is local, complete and on
//  disk before this is ever asked to play it, so there is nothing to stream and
//  no reason to carry a player built for streaming. It also seeks instantly,
//  which is what makes the back-30 button feel like a button rather than a
//  request.
//
//  The session belongs to `AudioSessionArbiter`, not to this. Playback ducks
//  for a dictated comment and resumes afterwards, and this type never sets a
//  category — see that file for why that matters.
//
//  ─── WHAT TO CHECK BY HAND, ON A DEVICE ──────────────────────────────────────
//  1. Lock the iPad mid-narration: it keeps playing, and the lock screen shows
//     the document's title with working transport controls.
//  2. Squeeze or pinch an AirPod: it pauses and resumes.
//  3. Leave the app entirely. It keeps playing.
//  4. Start a second document's narration while one is playing: the first
//     stops, and Now Playing shows the second.
//  ─────────────────────────────────────────────────────────────────────────────
//

import Foundation
import AVFoundation
import MediaPlayer
import os
import Core

/// Plays a document's narration.
///
/// **On failure:** `play(_:title:)` returns false and nothing happens. A file
/// that will not open is a document you read instead — there is no error worth
/// putting on screen for audio the reader can simply not use.
public actor NarrationPlayer {

    private static let log = Logger(subsystem: "co.pencil-loop.annotate", category: "narration")

    /// How far the skip buttons move. Thirty seconds back is the podcast
    /// convention and roughly a paragraph of speech; fifteen forward is enough
    /// to leave a passage without overshooting the next one.
    public static let skipBack: TimeInterval = 30
    public static let skipForward: TimeInterval = 15

    private var player: AVAudioPlayer?
    private var currentTitle = ""

    /// The document being played, so a view can tell whose narration this is.
    public private(set) var folderName: String?

    public init() {}

    /// Wires the lock screen, Control Center and AirPods to this player.
    ///
    /// Called once, when the player is built. `MPRemoteCommandCenter` is a
    /// process-wide singleton whose handlers accumulate, so registering twice
    /// would run every action twice — hence once, from the composition root,
    /// rather than whenever a sheet appears.
    public func connectRemoteControls() {
        let centre = MPRemoteCommandCenter.shared()
        centre.playCommand.removeTarget(nil)
        centre.pauseCommand.removeTarget(nil)
        centre.togglePlayPauseCommand.removeTarget(nil)
        centre.skipBackwardCommand.removeTarget(nil)
        centre.skipForwardCommand.removeTarget(nil)

        centre.skipBackwardCommand.preferredIntervals = [NSNumber(value: NarrationPlayer.skipBack)]
        centre.skipForwardCommand.preferredIntervals = [NSNumber(value: NarrationPlayer.skipForward)]

        centre.playCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            Task { await self.resume() }
            return .success
        }
        centre.pauseCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            Task { await self.pause() }
            return .success
        }
        centre.togglePlayPauseCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            Task { await self.toggle() }
            return .success
        }
        centre.skipBackwardCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            Task { await self.skip(-NarrationPlayer.skipBack) }
            return .success
        }
        centre.skipForwardCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            Task { await self.skip(NarrationPlayer.skipForward) }
            return .success
        }
    }

    // MARK: - Transport

    /// Starts playing a narration, replacing anything already playing.
    ///
    /// - Returns: whether it started. False means the file would not open, or a
    ///   recording holds the audio session.
    @discardableResult
    public func play(_ url: URL, title: String, folderName: String) async -> Bool {
        guard await AudioSessionArbiter.shared.beginPlayback() else {
            NarrationPlayer.log.notice("Playback refused: the microphone has the session.")
            return false
        }
        do {
            let made = try AVAudioPlayer(contentsOf: url)
            made.prepareToPlay()
            made.play()
            player = made
            currentTitle = title
            self.folderName = folderName
            updateNowPlaying()
            return true
        } catch {
            NarrationPlayer.log.notice(
                "Could not open the narration: \(error.localizedDescription, privacy: .public)"
            )
            await AudioSessionArbiter.shared.endPlayback()
            return false
        }
    }

    public func pause() {
        player?.pause()
        updateNowPlaying()
    }

    public func resume() async {
        guard let player else { return }
        guard await AudioSessionArbiter.shared.beginPlayback() else { return }
        player.play()
        updateNowPlaying()
    }

    /// Pause or resume, whichever the player is not doing.
    public func toggle() async {
        if player?.isPlaying == true {
            pause()
        } else {
            await resume()
        }
    }

    public func stop() async {
        player?.stop()
        player = nil
        folderName = nil
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        await AudioSessionArbiter.shared.endPlayback()
    }

    /// Moves by `seconds`, clamped to the file.
    public func skip(_ seconds: TimeInterval) {
        guard let player else { return }
        player.currentTime = min(max(0, player.currentTime + seconds), player.duration)
        updateNowPlaying()
    }

    /// Jumps to a fraction of the way through, for a scrubber.
    public func seek(toFraction fraction: Double) {
        guard let player else { return }
        player.currentTime = player.duration * min(1, max(0, fraction))
        updateNowPlaying()
    }

    /// What to draw. Cheap; safe to poll while a view is on screen.
    public func playback() -> NarrationPlayback {
        guard let player else { return NarrationPlayback() }
        return NarrationPlayback(
            isPlaying: player.isPlaying,
            elapsed: player.currentTime,
            duration: player.duration
        )
    }

    /// Resumes after a dictated comment gave the session back.
    ///
    /// Called by whoever ended the recording, because the arbiter knows a
    /// narration was interrupted but not which player to tell.
    public func resumeAfterRecording() async {
        guard let player, player.isPlaying == false, player.currentTime > 0 else { return }
        await resume()
    }

    // MARK: - The lock screen

    /// Puts the document in the Now Playing slot.
    ///
    /// Without this the audio still plays with the screen off, but the lock
    /// screen shows whatever was playing before and its buttons do nothing —
    /// which reads as a bug in this app rather than an absence.
    private func updateNowPlaying() {
        guard let player else { return }
        var info: [String: Any] = [:]
        info[MPMediaItemPropertyTitle] = currentTitle
        // "PencilLoop" rather than a person: this is a document being read, and
        // naming a narrator would imply one exists.
        info[MPMediaItemPropertyArtist] = "PencilLoop"
        info[MPMediaItemPropertyPlaybackDuration] = player.duration
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = player.currentTime
        info[MPNowPlayingInfoPropertyPlaybackRate] = player.isPlaying ? 1.0 : 0.0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
}
