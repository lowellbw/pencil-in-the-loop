//
//  ContinuousTranscriber.swift
//  Annotate · Speech
//
//  Keeps talking working for as long as somebody is talking.
//
//  ─── THE BUG THIS EXISTS FOR ─────────────────────────────────────────────────
//  A speech engine decides on its own when an utterance is over. `SpeechAnalyzer`
//  ends `results` when it finalises; `SFSpeechRecognizer` ends its task at
//  end-of-speech and again at a duration cap of its own. Both then *finish their
//  stream normally* — no error, nothing thrown.
//
//  Every consumer in this app reads that stream with `for try await`, so a
//  normal finish falls out of the loop and neither `catch` runs. The recording
//  state was never told, so the row still said "Listening…", the microphone
//  indicator stayed lit, and the words kept going nowhere. It looked exactly
//  like a length limit, because that is what it was.
//
//  So this sits between the app and whichever engine the factory chose, and
//  restarts recognition whenever it stops before the person did. The engine
//  underneath keeps deciding where an utterance ends; it just no longer gets to
//  decide when the recording ends. That is `stop()`'s job, and `stop()` is
//  called by a hand letting go of a Pencil.
//
//  **The cost, stated plainly:** a restart takes a moment, and a word spoken in
//  that gap can be lost. That is worth it — a seam in a long note is a worse
//  transcript, a hard stop at ten seconds is not a note at all — but it is a
//  real cost and it is why this restarts rather than pre-empting.
//

import Foundation
import os
import Core

/// Wraps a `SpeechTranscribing` so that a recording ends when the user says so
/// and not when the engine loses interest.
///
/// **On failure:** identical to the engine underneath. A thrown error is passed
/// straight through and ends the recording, because an engine that cannot
/// start will not start on the second attempt either.
public actor ContinuousTranscriber: SpeechTranscribing {

    /// How many times in a row recognition may end having transcribed nothing
    /// before this gives up.
    ///
    /// Without a ceiling, an engine failing instantly — permission revoked
    /// mid-recording, the audio route taken by a call — would be restarted for
    /// ever in a tight loop. Three is enough to ride out a hiccup and few
    /// enough to notice a wall.
    private static let maximumSilentRestarts = 3

    /// A pause before restarting after a segment that produced nothing, so a
    /// failing engine is not hammered. Zero after a segment that produced
    /// words, because that is somebody mid-sentence.
    private static let silentRestartPause = Duration.milliseconds(200)

    private let engine: any SpeechTranscribing
    private let logger = Logger(subsystem: "com.lowellweisbord.pencilloop", category: "speech")

    /// Whether the *user* is still recording, as opposed to the engine.
    private var isRecording = false

    /// Text from segments the engine has already closed.
    private var carried = ""

    /// The segment in progress, kept so a restart can fold it into `carried`
    /// even when the engine returns nothing from `stop()`.
    private var current = ""

    public init(engine: any SpeechTranscribing) {
        self.engine = engine
    }

    // MARK: - SpeechTranscribing

    public nonisolated func transcribe(
        contextualTerms: [String]
    ) -> AsyncThrowingStream<TranscriptionUpdate, Error> {
        AsyncThrowingStream { continuation in
            let work = Task {
                guard await self.claimRecording() else {
                    continuation.finish(throwing: PencilLoopError.speechUnavailable(
                        reason: "Another recording is already running."
                    ))
                    return
                }
                var silentRestarts = 0

                while await self.isRecording {
                    var produced = false
                    do {
                        for try await update in self.engine.transcribe(contextualTerms: contextualTerms) {
                            produced = true
                            continuation.yield(await self.fold(update))
                        }
                    } catch {
                        await self.finishRecording()
                        continuation.finish(throwing: error)
                        return
                    }

                    // Ended because `stop()` was called: that is the recording
                    // finishing normally, and the caller already has the text.
                    guard await self.isRecording else { break }

                    silentRestarts = produced ? 0 : silentRestarts + 1
                    guard silentRestarts < ContinuousTranscriber.maximumSilentRestarts else {
                        await self.logGivingUp()
                        await self.finishRecording()
                        continuation.finish()
                        return
                    }

                    await self.closeSegment()
                    if produced == false {
                        try? await Task.sleep(for: ContinuousTranscriber.silentRestartPause)
                    }
                    if Task.isCancelled { break }
                }
                continuation.finish()
            }

            continuation.onTermination = { termination in
                // Only a consumer walking away means stop. `.finished` is this
                // stream finishing itself, above — the same rule the engines
                // follow, and the reason stopping does not recurse.
                guard case .cancelled = termination else { return }
                work.cancel()
                Task { _ = await self.stop() }
            }
        }
    }

    /// Ends the recording and returns everything said during it, across however
    /// many times the engine restarted.
    public func setClipDestination(_ url: URL?) async {
        await engine.setClipDestination(url)
    }

    public func finishedClip() async -> URL? {
        await engine.finishedClip()
    }

    public func stop() async -> String {
        guard isRecording else { return "" }
        isRecording = false

        let settled = await engine.stop()
        let last = settled.isEmpty ? current : settled
        let everything = ContinuousTranscriber.joined(carried, last)
        carried = ""
        current = ""
        return everything
    }

    public func assetState() async -> SpeechAssetState { await engine.assetState() }

    public func prepareAssets() async { await engine.prepareAssets() }

    public func prewarm() async { await engine.prewarm() }

    public func supportedLocales() async -> [Locale] { await engine.supportedLocales() }

    // MARK: - Accumulating across restarts

    /// Starts a recording, or refuses when one is already running.
    ///
    /// `SpeechTranscribing` is documented as one recording at a time
    /// (Protocols.swift § Lifecycle). This used to *assume* callers obeyed it
    /// and reset the accumulated text unconditionally, so a second recording
    /// started by mistake did not merely compete with the first — it erased
    /// what the first had already transcribed, and the user lost a comment they
    /// had finished speaking with no error anywhere.
    ///
    /// Refusing is louder and cannot lose words. The running recording wins,
    /// because it is the one with a person talking into it.
    private func claimRecording() -> Bool {
        guard isRecording == false else { return false }
        isRecording = true
        carried = ""
        current = ""
        return true
    }

    private func finishRecording() {
        isRecording = false
    }

    /// Re-frames one update so the caller sees the whole recording rather than
    /// the current segment.
    ///
    /// `finalisedText` is documented as cumulative from the start of the
    /// recording, and after a restart the engine's idea of the start is wrong —
    /// so the text from earlier segments is added back here, where it is the
    /// only place that knows there were any.
    private func fold(_ update: TranscriptionUpdate) -> TranscriptionUpdate {
        current = update.displayText
        return TranscriptionUpdate(
            volatileText: update.volatileText,
            finalisedText: ContinuousTranscriber.joined(carried, update.finalisedText)
        )
    }

    /// The engine stopped while the user is still talking. Keep what it settled
    /// and let the loop start it again.
    private func closeSegment() async {
        let settled = await engine.stop()
        carried = ContinuousTranscriber.joined(carried, settled.isEmpty ? current : settled)
        current = ""
        logger.debug("Recognition ended mid-recording; restarting.")
    }

    private func logGivingUp() {
        logger.error("Recognition kept ending with nothing transcribed; stopping.")
    }

    /// Two segments, one space, no leading or trailing whitespace.
    private static func joined(_ first: String, _ second: String) -> String {
        let left = first.trimmingCharacters(in: .whitespacesAndNewlines)
        let right = second.trimmingCharacters(in: .whitespacesAndNewlines)
        if left.isEmpty { return right }
        if right.isEmpty { return left }
        return left + " " + right
    }
}
