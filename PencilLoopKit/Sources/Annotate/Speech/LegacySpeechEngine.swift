//
//  LegacySpeechEngine.swift
//  Annotate · Speech
//
//  The deliberate fallback (docs/03-architecture.md § 4): `SFSpeechRecognizer`
//  with `requiresOnDeviceRecognition = true`, behind the same protocol, so
//  either engine can be swapped in without a caller noticing.
//
//  It is not only a safety net. It is the one engine that accepts vocabulary
//  biasing — around a hundred `contextualStrings` — which the analyser path has
//  no equivalent for, so on a device where jargon accuracy matters more than
//  streaming quality this is a legitimate choice rather than a downgrade.
//

import Foundation
import AVFoundation
import Speech
import os
import Core

/// On-device dictation through `SFSpeechRecognizer`.
///
/// **Always on device.** `requiresOnDeviceRecognition` is set to true and never
/// unset. Reading and annotating do not touch the network, and a recogniser
/// that quietly fell back to a server would break that without anyone noticing
/// (CLAUDE.md non-negotiable 1).
///
/// **Volatile and finalised.** `SFSpeechRecognizer` reports one cumulative
/// string that keeps changing until the result is marked final, so every
/// partial arrives as `volatileText` with an empty `finalisedText`, and the
/// final result moves the whole string across. The popover renders
/// `displayText` either way and the distinction only affects styling
/// (DTOs.swift § TranscriptionUpdate).
///
/// **On failure:** the stream throws `PencilLoopError.speechUnavailable` or
/// `.permissionDenied`, the popover stays open, and the user writes the comment
/// by hand instead.
public actor LegacySpeechEngine: SpeechTranscribing {

    private let locale: Locale
    private let capture: MicrophoneCapture
    private let logger = Logger(subsystem: "co.pencil-loop", category: "speech")

    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var pumpTask: Task<Void, Never>?
    private var streamContinuation: AsyncThrowingStream<TranscriptionUpdate, Error>.Continuation?

    private var settledText = ""
    private var latestText = ""
    private var authorisationRequested = false

    /// Kept so a finished utterance can be followed by another one without
    /// giving the microphone back — see `renew()`.
    private var recogniser: SFSpeechRecognizer?
    private var contextualStrings: [String] = []

    /// Text from recognition tasks that have already finalised during *this*
    /// recording. `SFSpeechRecognizer` ends a task at end of speech, so a
    /// recording of any length is several tasks, and only this knows that.
    private var carried = ""

    /// Which recognition task's callbacks count. A finished task can report
    /// once more after it has been replaced, and acting on that would either
    /// duplicate an utterance or tear down its successor.
    private var generation = 0

    /// When recognition was last renewed, for the spin guard in `mayRenew()`.
    private var recentRenewals: [Date] = []

    /// A recogniser that finalises this often, this fast, is not listening to
    /// anybody — it is failing. Silence is not the same thing and must never
    /// trip this: a person pausing to think produces no finalisations at all.
    private static let maximumRenewalsPerWindow = 10
    private static let renewalWindow: TimeInterval = 2

    public init(locale: Locale) {
        self.locale = locale
        self.capture = MicrophoneCapture()
    }

    /// Injection point for tests on a Mac. Not public: `MicrophoneCapture` is
    /// an implementation detail, and a public initialiser may not name one.
    init(locale: Locale, capture: MicrophoneCapture) {
        self.locale = locale
        self.capture = capture
    }

    // MARK: Assets

    /// Whether this engine can transcribe a language on device.
    ///
    /// Used by `SpeechEngineFactory`. `SFSpeechRecognizer` returns nil for a
    /// language it does not know at all, and reports
    /// `supportsOnDeviceRecognition` separately for the ones it does.
    public static func supportsLocale(_ locale: Locale) -> Bool {
        SFSpeechRecognizer(locale: locale) != nil
    }

    /// Every language `SFSpeechRecognizer` knows.
    ///
    /// Wider than what it can do *on device* — `supportsOnDeviceRecognition` is
    /// per-recogniser and only answerable once one exists — so the picker may
    /// offer a language whose assets never arrive. That is the honest list to
    /// show: `assetState()` is what reports the difference, in the one Settings
    /// row that exists for it, and a language hidden from the picker can never
    /// be chosen at all.
    ///
    /// - Returns: an empty array when the system will not say. Never throws.
    public func supportedLocales() async -> [Locale] {
        SFSpeechRecognizer.supportedLocales().sorted {
            SpeechAvailability.displayName(for: $0)
                .localizedCaseInsensitiveCompare(SpeechAvailability.displayName(for: $1)) == .orderedAscending
        }
    }

    /// Whether the on-device model for a language is present.
    public static func supportsOnDeviceTranscription(for locale: Locale) -> Bool {
        guard let recogniser = SFSpeechRecognizer(locale: locale) else { return false }
        return recogniser.supportsOnDeviceRecognition
    }

    public func assetState() async -> SpeechAssetState {
        let permission = SpeechAvailability.narrower(
            SpeechAvailability.microphone(),
            SpeechAvailability.speechRecognition()
        )
        let recogniser = SFSpeechRecognizer(locale: locale)
        let installed = recogniser?.supportsOnDeviceRecognition == true
            && recogniser?.isAvailable == true

        return SpeechAvailability.state(
            permission: permission,
            localeSupported: recogniser != nil,
            localeDisplayName: SpeechAvailability.displayName(for: locale),
            assetsInstalled: installed,
            // There is no observable download here: iOS provisions the
            // dictation model itself once speech recognition is authorised.
            downloadFraction: nil,
            downloadRequested: authorisationRequested
        )
    }

    /// Asks for speech-recognition permission, which is what makes iOS
    /// provision the on-device dictation model.
    ///
    /// Idempotent and non-throwing, and it returns as soon as the prompt has
    /// been answered rather than when the model has landed — poll
    /// `assetState()` for that (Protocols.swift § SpeechTranscribing).
    public func prepareAssets() async {
        guard authorisationRequested == false else { return }
        authorisationRequested = true
        _ = await SpeechAvailability.requestSpeechRecognition()
    }

    // MARK: Recording

    /// Opens the audio session and prepares the engine graph, so the press that
    /// follows does not pay for it.
    ///
    /// Idempotent, non-throwing, best-effort (Protocols.swift §
    /// SpeechTranscribing). It does nothing when a recording is already
    /// running, and nothing when microphone permission has not been granted
    /// yet — warming must never be what makes the system permission alert
    /// appear, because the user has not asked for anything at that point.
    public func prewarm() async {
        guard streamContinuation == nil else { return }
        guard SpeechAvailability.microphone() == .granted else { return }
        do {
            try await capture.prewarm()
        } catch {
            // Best-effort by contract: the failure repeats in `transcribe`,
            // where there is a popover to show it.
            logger.debug("Speech prewarm did nothing: \(error.localizedDescription, privacy: .public)")
        }
    }

    public nonisolated func transcribe(
        contextualTerms: [String]
    ) -> AsyncThrowingStream<TranscriptionUpdate, Error> {
        AsyncThrowingStream { continuation in
            let work = Task { await self.begin(contextualTerms: contextualTerms, continuation: continuation) }
            continuation.onTermination = { termination in
                // See AnalyserSpeechEngine: only `.cancelled` is a consumer
                // walking away. `.finished` is our own teardown.
                guard case .cancelled = termination else { return }
                work.cancel()
                Task { _ = await self.stop() }
            }
        }
    }

    private func begin(
        contextualTerms: [String],
        continuation: AsyncThrowingStream<TranscriptionUpdate, Error>.Continuation
    ) async {
        // The microphone is left alone: `capture.start()` replaces the tap
        // itself, and handing the audio session back on the way into a
        // recording would throw away the pre-warm (MicrophoneCapture § start).
        finishStream(with: .speechUnavailable(reason: "Another recording started."))
        await teardown(releasingCapture: false)

        streamContinuation = continuation
        settledText = ""
        latestText = ""

        // Every path out of here that is not a recording gives the microphone
        // back, pre-warmed session included: leaving it active would leave the
        // system recording indicator lit for a comment that never started.
        let microphone = await SpeechAvailability.requestMicrophone()
        guard microphone != .denied else {
            finishStream(with: .permissionDenied(what: "Microphone"))
            await teardown()
            return
        }
        let speech = await SpeechAvailability.requestSpeechRecognition()
        authorisationRequested = true
        guard speech != .denied else {
            finishStream(with: .permissionDenied(what: "Speech recognition"))
            await teardown()
            return
        }

        guard let recogniser = SFSpeechRecognizer(locale: locale), recogniser.isAvailable else {
            finishStream(with: .speechUnavailable(
                reason: "\(SpeechAvailability.displayName(for: locale)) dictation is not available on this device."
            ))
            await teardown()
            return
        }
        guard recogniser.supportsOnDeviceRecognition else {
            finishStream(with: .speechUnavailable(
                reason: "The on-device dictation model for \(SpeechAvailability.displayName(for: locale)) has not been installed yet."
            ))
            await teardown()
            return
        }

        self.recogniser = recogniser
        self.contextualStrings = Array(contextualTerms.prefix(TermListCorrector.maximumTerms))
        self.carried = ""
        self.recentRenewals = []

        do {
            let chunks = try await capture.startWaitingForInput()
            startRecognition()
            pumpTask = Task { await self.pump(chunks) }
        } catch let error as PencilLoopError {
            finishStream(with: error)
            await teardown()
        } catch {
            finishStream(with: .speechUnavailable(reason: error.localizedDescription))
            await teardown()
        }
    }

    private func pump(_ chunks: AsyncStream<MicrophoneCapture.Chunk>) async {
        for await chunk in chunks {
            if Task.isCancelled { return }
            request?.append(chunk.buffer)
        }
    }

    /// Folds one callback from the recogniser into the stream.
    ///
    /// An error after something has already been transcribed is not worth
    /// reporting: `endAudio()` produces one, and so does a cancelled task.
    /// Losing a comment because the teardown was noisy would be the wrong
    /// trade.
    private func ingest(generation reporting: Int, text: String?, isFinal: Bool, failed: Bool) {
        // A task that has already been replaced, reporting once more on its way
        // out. Acting on it would either repeat an utterance or stop the task
        // that took its place.
        guard reporting == generation else { return }

        if let text, text.isEmpty == false {
            latestText = text
            if isFinal {
                settledText = text
            }
        }
        if failed {
            if carried.isEmpty, settledText.isEmpty, latestText.isEmpty {
                finishStream(with: .speechUnavailable(reason: "Dictation stopped unexpectedly."))
            } else {
                // The recogniser gave up on this utterance, not on the
                // recording. Keep what it heard and listen again.
                foldSegment()
                renew()
            }
            return
        }
        if isFinal {
            foldSegment()
            streamContinuation?.yield(
                TranscriptionUpdate(volatileText: "", finalisedText: carried)
            )
            renew()
        } else {
            streamContinuation?.yield(
                TranscriptionUpdate(volatileText: latestText, finalisedText: partialPrefix)
            )
        }
    }

    /// Starts a recognition task against the audio already flowing.
    ///
    /// The microphone, the audio session and the pump are untouched — this is
    /// only the recogniser, which is the part that keeps deciding it is done.
    private func startRecognition() {
        guard let recogniser else { return }
        generation += 1
        let mine = generation

        let audioRequest = SFSpeechAudioBufferRecognitionRequest()
        audioRequest.shouldReportPartialResults = true
        // Never a server round trip, on any path (CLAUDE.md non-negotiable 1).
        audioRequest.requiresOnDeviceRecognition = true
        // The one thing this engine can do that the analyser cannot: bias the
        // vocabulary towards the document's own words.
        audioRequest.contextualStrings = contextualStrings
        request = audioRequest

        task = recogniser.recognitionTask(with: audioRequest) { result, error in
            let text = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            let failed = error != nil
            Task { await self.ingest(generation: mine, text: text, isFinal: isFinal, failed: failed) }
        }
    }

    /// Listens again, on the same open microphone.
    ///
    /// `SFSpeechRecognizer` ends a task at end of speech — after about five
    /// seconds in practice — so without this a voice note simply stopped there,
    /// and stopped *silently*, which is what made it look like a length limit.
    /// Giving the audio session back and taking it again was tried first and is
    /// worse: the session does not reliably come back mid-sentence, and every
    /// word spoken during the handover is lost. Only the recogniser restarts.
    private func renew() {
        guard streamContinuation != nil else { return }
        guard mayRenew() else {
            logger.error("Recognition kept finalising with nothing to show for it; stopping.")
            finishStream(with: nil)
            return
        }
        request?.endAudio()
        task?.finish()
        request = nil
        task = nil
        startRecognition()
        logger.debug("Recogniser finalised; listening again with the microphone still open.")
    }

    /// False when recognition is finalising so fast and so often that it is
    /// failing rather than hearing sentence ends.
    private func mayRenew() -> Bool {
        let now = Date()
        recentRenewals.append(now)
        recentRenewals.removeAll { now.timeIntervalSince($0) > LegacySpeechEngine.renewalWindow }
        return recentRenewals.count <= LegacySpeechEngine.maximumRenewalsPerWindow
    }

    /// Moves the utterance just finished into the running total.
    private func foldSegment() {
        let best = settledText.isEmpty ? latestText : settledText
        carried = LegacySpeechEngine.joined(carried, best)
        settledText = ""
        latestText = ""
    }

    /// What goes in front of the in-progress hypothesis so the caller always
    /// sees the whole recording. `displayText` concatenates the two directly,
    /// so the separator lives here.
    private var partialPrefix: String {
        carried.isEmpty ? "" : carried + " "
    }

    private static func joined(_ first: String, _ second: String) -> String {
        let left = first.trimmingCharacters(in: .whitespacesAndNewlines)
        let right = second.trimmingCharacters(in: .whitespacesAndNewlines)
        if left.isEmpty { return right }
        if right.isEmpty { return left }
        return left + " " + right
    }

    /// Ends the recording and returns the best text there is.
    ///
    /// It does not wait for the recogniser's final callback. The user has
    /// released the Pencil and is waiting for a marker to appear, and the last
    /// partial differs from the final result by punctuation at most; the state
    /// machine falls back to the streamed text if this returns nothing anyway
    /// (VoiceRecordingMachine.settle).
    public func stop() async -> String {
        guard streamContinuation != nil || task != nil else { return "" }

        // Before anything else: the task about to be finished will report once
        // more, and `ingest` must not read that as an utterance ending and
        // start listening again after the user has let go.
        generation += 1

        await capture.stop()
        pumpTask?.cancel()
        pumpTask = nil
        request?.endAudio()
        task?.finish()

        foldSegment()
        let text = carried
        finishStream(with: nil)
        request = nil
        task = nil
        carried = ""
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Internals

    /// Drops the recogniser task and everything feeding it.
    ///
    /// - Parameter releasingCapture: true to give the microphone and the audio
    ///   session back as well, which is what a failed or finished recording
    ///   wants. False on the way *into* a recording, where the session has just
    ///   been pre-warmed and `capture.start()` will replace the tap anyway.
    private func teardown(releasingCapture: Bool = true) async {
        generation += 1
        pumpTask?.cancel()
        pumpTask = nil
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
        if releasingCapture {
            await capture.stop()
        }
    }

    private func finishStream(with error: PencilLoopError?) {
        guard let continuation = streamContinuation else { return }
        streamContinuation = nil
        if let error {
            continuation.finish(throwing: error)
        } else {
            continuation.finish()
        }
    }
}
