//
//  ClipRecorder.swift
//  Annotate · Speech
//
//  Keeping the audio, so a transcript can be improved after the fact.
//
//  The on-device transcript is a draft. A better one can be made later — by a
//  model that knows what the document is about — but only from the audio, and
//  until this existed the audio was gone the moment the recogniser had finished
//  with it (notes/pencil-loop-cloud-dictation.md, "audio is the source of
//  truth"). This writes it down.
//
//  **Nothing here runs on the audio thread.** The tap block yields the same
//  `Chunk` it already copies for the engine into a second stream, and the write
//  happens in a task draining that stream. Encoding a buffer inside the callback
//  would be file I/O on the render thread, which is the one place this app is
//  not allowed to be slow.
//
//  ─── WHAT TO CHECK BY HAND, ON A DEVICE ──────────────────────────────────────
//  There is no microphone anywhere but a real iPad (STYLE.md § 10):
//
//  1. Record a comment, then look in the container: clips/<id>.flac exists and
//     is roughly a few hundred KB for twenty seconds.
//  2. Play it back. It must be the whole comment — a clip missing its first
//     word means the recorder was started after the tap rather than with it.
//  3. Record for ninety seconds. Memory must stay flat: this streams to disk
//     and holds one buffer, not the whole clip.
//  ─────────────────────────────────────────────────────────────────────────────
//

import Foundation
import AVFoundation
import os
import Core

/// Writes a recording to a file while the engine transcribes it.
///
/// **On failure:** every path is silent and lossy in one direction only — a
/// clip that cannot be written means no later upgrade, never a lost comment.
/// The draft transcript is unaffected by anything in here, which is why nothing
/// in here throws.
actor ClipRecorder {

    private static let log = Logger(subsystem: "co.pencil-loop.annotate", category: "clip")

    /// The container the clip is being written to, or nil once it is closed.
    private var file: AVAudioFile?

    /// Where it is being written. Kept so `finish()` can name it after the file
    /// has been closed.
    private let url: URL

    private var framesWritten: AVAudioFramePosition = 0

    /// Whether anything went wrong. A clip that failed part-way is deleted
    /// rather than handed on: half a comment transcribed confidently is worse
    /// than no upgrade at all.
    private var isSpoiled = false

    init(url: URL) {
        self.url = url
    }

    /// Opens the file, in the format the microphone is actually delivering.
    ///
    /// FLAC because it is lossless, about half the size of the raw samples, and
    /// accepted by every ASR API worth calling — and because transcoding
    /// through a lossy format on the way to a speech model throws away exactly
    /// the detail the model is listening for.
    ///
    /// - Returns: whether recording started. False means no clip, and the
    ///   caller carries on with the draft alone.
    func begin(format: AVAudioFormat) -> Bool {
        guard file == nil, isSpoiled == false else { return false }
        // Mono at the microphone's own rate. The note asks for 48 kHz and never
        // for a downsample we do not have to do: a provider that wants 16 kHz
        // can do that conversion better than we can, and one that does not gets
        // the detail.
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatFLAC,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16
        ]
        do {
            file = try AVAudioFile(forWriting: url, settings: settings)
            return true
        } catch {
            ClipRecorder.log.notice("No clip: \(error.localizedDescription, privacy: .public)")
            isSpoiled = true
            return false
        }
    }

    /// Appends one buffer. Cheap enough to call for every tap callback, and
    /// deliberately not called *from* one.
    func append(_ buffer: AVAudioPCMBuffer) {
        guard let file, isSpoiled == false else { return }
        do {
            try file.write(from: buffer)
            framesWritten += AVAudioFramePosition(buffer.frameLength)
        } catch {
            // One failed write means the rest of the file is a lie about what
            // was said, so the whole clip goes.
            ClipRecorder.log.notice("Clip spoiled: \(error.localizedDescription, privacy: .public)")
            isSpoiled = true
            self.file = nil
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Closes the file and says whether there is a clip worth keeping.
    ///
    /// - Returns: the clip's URL, or nil when there is nothing usable — a
    ///   failed write, or a recording too short to be a comment. A press that
    ///   caught a quarter of a second of room tone should not become an upload.
    func finish(minimumSeconds: Double = 0.3) -> URL? {
        guard let file else { return nil }
        let sampleRate = file.processingFormat.sampleRate
        self.file = nil
        guard isSpoiled == false, sampleRate > 0 else {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        let seconds = Double(framesWritten) / sampleRate
        guard seconds >= minimumSeconds else {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        return url
    }

    /// Throws the clip away — the recording was abandoned rather than saved.
    func discard() {
        file = nil
        try? FileManager.default.removeItem(at: url)
    }
}
