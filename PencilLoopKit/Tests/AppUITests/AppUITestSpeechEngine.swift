//
//  AppUITestSpeechEngine.swift
//  AppUITests
//
//  A `SpeechTranscribing` with a name and a memory, so a test can tell one
//  engine from another.
//
//  `DeferredSpeechTranscriberTests` is entirely about which engine a call
//  reached: whether three concurrent callers shared one, and whether `stop()`
//  addressed the one the running stream was bound to. Neither question can be
//  asked of an engine with no identity. Nothing here records audio — a recording
//  is one yielded update and a final string, which is the whole of what the
//  deferred transcriber can see of one (STYLE.md § 10: dictation itself is not
//  unit testable).
//

import Foundation
import Core

/// A named stub engine that reports what it was asked to do.
actor AppUITestSpeechEngine: SpeechTranscribing {

    /// Which engine this is. The tests assert on it.
    let name: String

    /// What `stop()` returns.
    private let finalText: String

    private(set) var stopCount = 0
    private(set) var prewarmCount = 0
    private(set) var transcribeCount = 0

    /// The running stream, kept open until `stop()` — exactly like a real
    /// engine between the first token and the lift, which is the window every
    /// interesting question here is asked in.
    private var live: AsyncThrowingStream<TranscriptionUpdate, Error>.Continuation?

    init(name: String, finalText: String = "") {
        self.name = name
        self.finalText = finalText
    }

    func assetState() async -> SpeechAssetState { .ready }

    func prepareAssets() async {}

    func prewarm() async {
        prewarmCount += 1
    }

    func supportedLocales() async -> [Locale] { [] }

    nonisolated func transcribe(contextualTerms: [String]) -> AsyncThrowingStream<TranscriptionUpdate, Error> {
        AsyncThrowingStream { continuation in
            Task { await self.begin(continuation) }
        }
    }

    /// Recorded so a test can assert a clip was asked for; nothing writes one.
    private(set) var clipDestination: URL?

    func setClipDestination(_ url: URL?) async { clipDestination = url }

    func finishedClip() async -> URL? { clipDestination }

    func stop() async -> String {
        stopCount += 1
        live?.finish()
        live = nil
        return finalText
    }

    /// Waits until a recording has actually started, so a test can change
    /// something underneath one. Bounded, so a failure is a failed assertion
    /// rather than a hung suite.
    func waitUntilTranscribing() async {
        for _ in 0..<400 {
            if transcribeCount > 0 { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    private func begin(_ continuation: AsyncThrowingStream<TranscriptionUpdate, Error>.Continuation) {
        transcribeCount += 1
        live = continuation
        continuation.yield(TranscriptionUpdate(volatileText: finalText, finalisedText: ""))
    }
}
