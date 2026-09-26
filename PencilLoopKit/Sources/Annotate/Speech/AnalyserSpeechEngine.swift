//
//  AnalyserSpeechEngine.swift
//  Annotate · Speech
//
//  ─── THE DELETABLE FILE ──────────────────────────────────────────────────────
//  This is the only file in the repo that names `SpeechAnalyzer`,
//  `SpeechTranscriber`, `AnalyzerInput` or `AssetInventory`. If the iOS 26 API
//  turns out to differ from what we wrote this against, triage on the Mac is
//  two steps and no design work:
//
//    1. Add `.define("PENCILLOOP_LEGACY_SPEECH")` to the Annotate target in
//       PencilLoopKit/Package.swift, next to the PENCILLOOP_STROKE_RECOGNIZER
//       define that is already there for the same reason.
//    2. Delete this file.
//
//  Everything else — the factory, the corrector, the state machine, the audio
//  capture, the popover in Wave 2 — is untouched, and the app dictates through
//  `SFSpeechRecognizer` with `requiresOnDeviceRecognition = true` instead. See
//  SpeechEngineFactory.swift, which holds the only reference to this type and
//  holds it inside that one `#if`.
//  ─────────────────────────────────────────────────────────────────────────────
//
//  Written against the iOS 26 API as documented: an actor-based analyser that
//  modules attach to, a transcriber module that yields volatile and finalised
//  results separately, on-device, with language assets managed through
//  AssetInventory (docs/03-architecture.md § 4). None of it can be compiled or
//  run on the machine this was written on.
//

import Foundation
import AVFoundation
import Speech
import os
import Core

/// On-device dictation through `SpeechAnalyzer` with a `SpeechTranscriber`
/// module attached.
///
/// **An actor**, because the analyser is one, because there is exactly one
/// recording at a time, and because the buffer pump, the results loop and
/// `stop()` all touch the same handful of variables from different tasks.
/// `transcribe(contextualTerms:)` is the one `nonisolated` member: the contract
/// declares it synchronous, so it builds the stream and hands the work to a
/// task rather than making every caller `await` before it can show a popover.
///
/// **No vocabulary biasing.** The analyser has no equivalent of
/// `contextualStrings`, so `contextualTerms` is accepted and ignored here; the
/// caller repairs jargon afterwards with `TermListCorrector`
/// (docs/03-architecture.md § 4). Passing the terms anyway is what lets the two
/// engines be swapped without the call site changing.
///
/// **After the assets land, no network, ever.** The only thing here that
/// touches it is `prepareAssets()`, which runs in the background on first run
/// and never on the reading or annotating path (CLAUDE.md non-negotiable 1).
public actor AnalyserSpeechEngine: SpeechTranscribing {

    private let locale: Locale
    private let capture: MicrophoneCapture
    private let logger = Logger(subsystem: "co.pencil-loop", category: "speech")

    private var transcriber: SpeechTranscriber?
    private var analyser: SpeechAnalyzer?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?
    private var pumpTask: Task<Void, Never>?
    private var streamContinuation: AsyncThrowingStream<TranscriptionUpdate, Error>.Continuation?

    /// Everything the transcriber has settled, cumulative for this recording.
    private var settledText = ""

    /// Which recording the engine's state belongs to. Bumped by every
    /// `begin`, so a `begin` that suspended — and a results loop outliving its
    /// recording — can tell on waking whether it is still the one anybody
    /// wants (`isCurrent`).
    private var recordingNumber = 0

    /// The recording `stop()` was last asked to end. Set before it awaits
    /// anything, which is what a `begin` still starting that recording checks.
    /// Zero, before any, names none: `begin` numbers from one.
    private var stoppedRecording = 0

    private var installationProgress: Progress?
    private var downloadTask: Task<Void, Never>?
    private var cachedSupported: Bool?
    private var cachedInstalled = false

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

    /// Whether this engine can transcribe a language at all, downloaded or not.
    ///
    /// Used by `SpeechEngineFactory` to decide between the engines before
    /// either has been built.
    public static func supportsLocale(_ locale: Locale) async -> Bool {
        let supported = await SpeechTranscriber.supportedLocales
        return supported.contains { matches($0, locale) }
    }

    /// Every language `SpeechTranscriber` knows, installed or not.
    ///
    /// The Settings picker's list (docs/02-spec.md § S6). Sorted by the name
    /// the user would read rather than by identifier, because that is the order
    /// the picker shows them in.
    ///
    /// - Returns: an empty array if the system will not say, which the caller
    ///   treats as "offer the current language only" rather than as an error.
    public func supportedLocales() async -> [Locale] {
        let supported = await SpeechTranscriber.supportedLocales
        return supported.sorted {
            SpeechAvailability.displayName(for: $0)
                .localizedCaseInsensitiveCompare(SpeechAvailability.displayName(for: $1)) == .orderedAscending
        }
    }

    static func isInstalled(_ locale: Locale) async -> Bool {
        let installed = await SpeechTranscriber.installedLocales
        return installed.contains { matches($0, locale) }
    }

    /// BCP-47 comparison, because `Locale` equality is stricter than we want:
    /// `en-GB` from settings and `en_GB` from the system are the same language.
    static func matches(_ left: Locale, _ right: Locale) -> Bool {
        left.identifier(.bcp47).caseInsensitiveCompare(right.identifier(.bcp47)) == .orderedSame
    }

    public func assetState() async -> SpeechAssetState {
        let supported: Bool
        if let cached = cachedSupported {
            supported = cached
        } else {
            supported = await Self.supportsLocale(locale)
            cachedSupported = supported
        }

        if cachedInstalled == false {
            cachedInstalled = await Self.isInstalled(locale)
        }

        return SpeechAvailability.state(
            permission: SpeechAvailability.microphone(),
            localeSupported: supported,
            localeDisplayName: SpeechAvailability.displayName(for: locale),
            assetsInstalled: cachedInstalled,
            downloadFraction: installationProgress.map(\.fractionCompleted),
            downloadRequested: downloadTask != nil
        )
    }

    public func prepareAssets() async {
        guard downloadTask == nil, cachedInstalled == false else { return }
        downloadTask = Task { await self.installAssets() }
    }

    /// The one-time download. Everything here is best-effort: a failure leaves
    /// `assetState()` reporting `.unavailable` with a sentence, which is the
    /// Settings row, which is the whole of the user-facing consequence.
    private func installAssets() async {
        if await Self.isInstalled(locale) {
            cachedInstalled = true
            downloadTask = nil
            return
        }
        let module = makeTranscriber(reportVolatileResults: false)
        do {
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
                installationProgress = request.progress
                try await request.downloadAndInstall()
            }
        } catch {
            logger.error("Speech asset install failed: \(error.localizedDescription, privacy: .public)")
        }
        installationProgress = nil
        cachedInstalled = await Self.isInstalled(locale)
        downloadTask = nil
    }

    // MARK: Recording

    /// Opens the audio session, prepares the engine graph and starts the
    /// microphone into a one-second ring, so the press that follows pays for
    /// none of it and the first word is not lost to setup
    /// (MicrophoneCapture § prewarm).
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

    /// Gives back a pre-warmed microphone that no recording followed. A running
    /// recording is left alone (Protocols.swift § releaseCapture).
    public func releaseCapture() async {
        guard streamContinuation == nil, analyser == nil else { return }
        await capture.stop()
    }

    public nonisolated func transcribe(
        contextualTerms: [String]
    ) -> AsyncThrowingStream<TranscriptionUpdate, Error> {
        AsyncThrowingStream { continuation in
            let work = Task { await self.begin(continuation: continuation) }
            continuation.onTermination = { termination in
                // Only a *consumer* walking away means stop. `.finished` is us
                // finishing the stream ourselves — in `stop()`, or when a second
                // recording supersedes this one — and reacting to that would let
                // an old stream's teardown pull the microphone out from under the
                // recording that replaced it (Protocols.swift § Lifecycle).
                guard case .cancelled = termination else { return }
                work.cancel()
                Task { _ = await self.stop() }
            }
        }
    }

    /// Starts capture first and builds the analyser second, deliberately.
    ///
    /// The microphone is the long pole and it is already pre-warmed, so the
    /// buffers start flowing into the stream's 64-buffer backlog while the
    /// analyser is still being assembled; nothing spoken in that window is
    /// lost, and nothing avoidable sits between the press and the first buffer
    /// (docs/03-architecture.md § Performance targets).
    private func begin(
        continuation: AsyncThrowingStream<TranscriptionUpdate, Error>.Continuation
    ) async {
        // One recording at a time: a second `transcribe` finishes the first
        // stream rather than interleaving two (Protocols.swift § Lifecycle).
        //
        // The microphone is left alone here. `capture.start()` below hands the
        // tap from the previous recording to this one itself, and giving the
        // audio session back on the way into a recording would throw away the
        // pre-warm this path is timed around (MicrophoneCapture § start).
        finishStream(with: .speechUnavailable(reason: "Another recording started."))
        await teardown(releasingCapture: false)

        recordingNumber += 1
        let recording = recordingNumber
        streamContinuation = continuation
        settledText = ""

        // Every path out of here that is not a recording gives the microphone
        // back, pre-warmed session included: leaving it active would leave the
        // system recording indicator lit for a comment that never started.
        //
        // And every await below is somewhere a lift can land. `stop()` does not
        // wait for this to finish starting; it marks the recording stopped and
        // gives the microphone back, so each wake-up asks whether that happened
        // and gives up if it did. Carrying on regardless is how a recording
        // used to be finished for nobody — microphone on, clip open — and the
        // next one hung behind it.
        let permission = await SpeechAvailability.requestMicrophone()
        guard isCurrent(recording) else {
            await abandon(recording)
            return
        }
        guard permission != .denied else {
            finishStream(with: .permissionDenied(what: "Microphone"))
            await teardown()
            return
        }

        // Asked of the system once per engine, not once per press. The answer
        // does not change underneath a running app, and the query used to sit
        // between the press and the microphone on every recording.
        if cachedInstalled != true {
            cachedInstalled = await Self.isInstalled(locale)
            guard isCurrent(recording) else {
                await abandon(recording)
                return
            }
        }
        guard cachedInstalled == true else {
            await prepareAssets()
            finishStream(with: .speechUnavailable(
                reason: "The dictation model for \(SpeechAvailability.displayName(for: locale)) is still downloading."
            ))
            await teardown()
            return
        }

        do {
            let chunks = try await capture.startWaitingForInput(clipURL: clipDestination)
            guard isCurrent(recording) else {
                await abandon(recording)
                return
            }
            // The microphone is live from here — say so, before the analyser
            // exists. The popover claims to be listening on this and on nothing
            // earlier (VoiceRecordingMachine § isListening).
            emit(volatile: "")

            let module = makeTranscriber(reportVolatileResults: true)
            transcriber = module
            let session = SpeechAnalyzer(modules: [module])
            analyser = session

            let (inputSequence, input) = AsyncStream<AnalyzerInput>.makeStream(
                bufferingPolicy: .bufferingNewest(64)
            )
            inputContinuation = input

            resultsTask = Task { await self.consumeResults(from: module, recording: recording) }
            try await session.start(inputSequence: inputSequence)
            guard isCurrent(recording) else {
                input.finish()
                await abandon(recording)
                return
            }

            guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module]) else {
                throw PencilLoopError.speechUnavailable(reason: "No compatible audio format.")
            }
            guard isCurrent(recording) else {
                input.finish()
                await abandon(recording)
                return
            }
            pumpTask = Task { await self.pump(chunks, to: format) }
        } catch {
            // A start that `stop()` overtook throws too. That is not a
            // failure to report, and the teardown is not this one's to do:
            // the state it would clear may already be a newer recording's.
            guard isCurrent(recording) else {
                await abandon(recording)
                return
            }
            let failure = (error as? PencilLoopError)
                ?? PencilLoopError.speechUnavailable(reason: error.localizedDescription)
            finishStream(with: failure)
            await teardown()
        }
    }

    /// Whether `recording` is still the one anybody wants: not replaced by a
    /// newer `begin`, not stopped, and not already failed.
    private func isCurrent(_ recording: Int) -> Bool {
        recordingNumber == recording
            && stoppedRecording != recording
            && streamContinuation != nil
    }

    /// A `begin` that woke to find itself stopped, failed or replaced.
    ///
    /// Replaced: the newer recording owns the microphone, and nothing is
    /// touched. Otherwise the microphone is given back again. `stop()` gave it
    /// back once already, but a capture this start was still waiting on can
    /// have come up after that — and left there it stays on, indicator lit,
    /// with nobody listening and the next recording queued behind its clip.
    private func abandon(_ recording: Int) async {
        guard recordingNumber == recording else { return }
        await capture.stop()
    }

    /// Volatile results are the in-progress hypothesis and are replaced
    /// wholesale; finalised results are appended and never change again. Both
    /// go out on every update so the popover can render settled text solid and
    /// the tail dimmer (DTOs.swift § TranscriptionUpdate).
    ///
    /// Scoped to the recording that started it. A loop that outlives its
    /// recording — cancelled by the next one's teardown, throwing on the way
    /// out — must not fail the stream or fill the transcript of the recording
    /// that replaced it. It still runs through `stop()`, which is when the
    /// last finalised result arrives and is the point of the comment.
    private func consumeResults(from module: SpeechTranscriber, recording: Int) async {
        do {
            for try await result in module.results {
                guard recordingNumber == recording else { return }
                let text = String(result.text.characters)
                if result.isFinal {
                    settledText += text
                    emit(volatile: "")
                } else {
                    emit(volatile: text)
                }
            }
        } catch {
            guard recordingNumber == recording else { return }
            logger.error("Transcription stream ended: \(error.localizedDescription, privacy: .public)")
            finishStream(with: .speechUnavailable(reason: error.localizedDescription))
        }
    }

    private func pump(_ chunks: AsyncStream<MicrophoneCapture.Chunk>, to format: AVAudioFormat) async {
        var converter: AVAudioConverter?
        for await chunk in chunks {
            if Task.isCancelled { return }
            let source = chunk.buffer
            if Self.formatsMatch(source.format, format) {
                inputContinuation?.yield(AnalyzerInput(buffer: source))
                continue
            }
            if converter == nil {
                converter = AVAudioConverter(from: source.format, to: format)
            }
            guard let converter,
                  let converted = Self.convert(source, to: format, using: converter) else { continue }
            inputContinuation?.yield(AnalyzerInput(buffer: converted))
        }
    }


    /// Where the next recording's audio is also written, or nil.
    private var clipDestination: URL?

    // MARK: - The clip

    public func setClipDestination(_ url: URL?) async {
        clipDestination = url
    }

    public func finishedClip() async -> URL? {
        clipDestination = nil
        return await capture.finishClip()
    }

    public func stop() async -> String {
        guard streamContinuation != nil || analyser != nil else { return "" }
        // Already being stopped: a second finalise of the same analyser is
        // at best an error in the log, and the first stop returns the text.
        guard stoppedRecording != recordingNumber else { return "" }

        // Marked before anything is awaited, so a `begin` still starting this
        // recording sees on waking that it has been stopped, and gives up
        // rather than finishing the job for nobody (`isCurrent`).
        let recording = recordingNumber
        stoppedRecording = recording

        // This recording's pieces, taken before the first await for the same
        // reason: a recording that starts while this one finishes must not
        // have its analyser finalised or its results waited on by this stop.
        let pump = pumpTask
        let input = inputContinuation
        let session = analyser
        let results = resultsTask

        await capture.stop()
        pump?.cancel()
        input?.finish()
        if recordingNumber == recording {
            pumpTask = nil
            inputContinuation = nil
        }

        // Drains what is still in flight and delivers the last finalised
        // result, which is why this is awaited rather than cancelled: the
        // trailing word of a comment is usually the point of the comment.
        if let session {
            do {
                try await session.finalizeAndFinishThroughEndOfInput()
            } catch {
                logger.error("Analyser did not finish cleanly: \(error.localizedDescription, privacy: .public)")
            }
        }
        await results?.value

        // A newer recording that began while this one was finishing owns
        // everything from here on; clearing it would end that one too.
        guard recordingNumber == recording else { return "" }
        resultsTask = nil
        let text = settledText.trimmingCharacters(in: .whitespacesAndNewlines)
        finishStream(with: nil)
        analyser = nil
        transcriber = nil
        return text
    }

    // MARK: Internals

    private func makeTranscriber(reportVolatileResults: Bool) -> SpeechTranscriber {
        SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: reportVolatileResults ? [.volatileResults] : [],
            attributeOptions: []
        )
    }

    /// Drops the analyser and everything feeding it.
    ///
    /// - Parameter releasingCapture: true to give the microphone and the audio
    ///   session back as well, which is what a failed or finished recording
    ///   wants. False on the way *into* a recording, where the session has
    ///   just been pre-warmed and `capture.start()` will replace the tap
    ///   anyway.
    private func teardown(releasingCapture: Bool = true) async {
        pumpTask?.cancel()
        pumpTask = nil
        resultsTask?.cancel()
        resultsTask = nil
        inputContinuation?.finish()
        inputContinuation = nil
        analyser = nil
        transcriber = nil
        if releasingCapture {
            await capture.stop()
        }
    }

    private func emit(volatile: String) {
        streamContinuation?.yield(
            TranscriptionUpdate(volatileText: volatile, finalisedText: settledText)
        )
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

    static func formatsMatch(_ left: AVAudioFormat, _ right: AVAudioFormat) -> Bool {
        left.sampleRate == right.sampleRate
            && left.channelCount == right.channelCount
            && left.commonFormat == right.commonFormat
    }

    /// Resamples one buffer into the analyser's preferred format.
    ///
    /// Returns nil rather than throwing: a buffer that will not convert is one
    /// buffer, and dropping it costs a syllable at worst, where failing the
    /// recording costs the comment.
    static func convert(
        _ buffer: AVAudioPCMBuffer,
        to format: AVAudioFormat,
        using converter: AVAudioConverter
    ) -> AVAudioPCMBuffer? {
        guard buffer.format.sampleRate > 0 else { return nil }
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
            return nil
        }

        var delivered = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, outStatus in
            if delivered {
                outStatus.pointee = .noDataNow
                return nil
            }
            delivered = true
            outStatus.pointee = .haveData
            return buffer
        }
        guard conversionError == nil, status != .error, output.frameLength > 0 else {
            return nil
        }
        return output
    }
}
