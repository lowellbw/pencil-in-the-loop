//
//  FakeSpeechEngine.swift
//  AnnotateTests · Speech
//
//  A scripted `SpeechTranscribing`. Neither real engine can be exercised here —
//  there is no microphone, no device and no Speech framework at test time — so
//  everything that talks *to* an engine is tested against this instead, and the
//  engines themselves are checked by hand on device.
//

import Foundation
import Core

/// An engine that plays a script.
///
/// Deliberately faithful to the awkward parts of the contract: `stop()` returns
/// "" when nothing is running, a second `transcribe` finishes the first stream
/// with `.speechUnavailable`, and `assetState()` only moves when it is told to.
actor FakeSpeechEngine: SpeechTranscribing {

    /// What this engine will do when asked.
    struct Script: Sendable {

        /// Yielded, in order, as soon as a recording starts.
        var updates: [TranscriptionUpdate]

        /// What `stop()` returns.
        var finalText: String

        /// Thrown after the updates, if set.
        var failure: PencilLoopError?

        /// Walked one entry at a time by `advanceAssetState()`.
        var states: [SpeechAssetState]

        /// What `supportedLocales()` reports. Empty is the documented "this
        /// engine cannot say" answer, so it is the default.
        var supportedLocales: [Locale]

        init(
            updates: [TranscriptionUpdate] = [],
            finalText: String = "",
            failure: PencilLoopError? = nil,
            states: [SpeechAssetState] = [.ready],
            supportedLocales: [Locale] = []
        ) {
            self.updates = updates
            self.finalText = finalText
            self.failure = failure
            self.states = states
            self.supportedLocales = supportedLocales
        }
    }

    private let script: Script
    private var stateIndex = 0
    private var continuation: AsyncThrowingStream<TranscriptionUpdate, Error>.Continuation?
    private var isRunning = false

    private(set) var receivedTerms: [String] = []
    private(set) var prepareCount = 0
    private(set) var prewarmCount = 0
    private(set) var startCount = 0
    private(set) var stopCount = 0

    init(script: Script = Script()) {
        self.script = script
    }

    // MARK: SpeechTranscribing

    func assetState() async -> SpeechAssetState {
        guard script.states.isEmpty == false else { return .ready }
        return script.states[min(stateIndex, script.states.count - 1)]
    }

    func prepareAssets() async {
        prepareCount += 1
    }

    /// Counted rather than acted on. A prewarm is best-effort by contract, so
    /// the only thing a test can assert about it is that it happened and that
    /// it changed nothing.
    func prewarm() async {
        prewarmCount += 1
    }

    nonisolated func transcribe(
        contextualTerms: [String]
    ) -> AsyncThrowingStream<TranscriptionUpdate, Error> {
        AsyncThrowingStream { continuation in
            Task { await self.begin(contextualTerms: contextualTerms, continuation: continuation) }
        }
    }

    /// Whatever the script says, so a test can drive the Settings picker
    /// without a device. Empty by default — the "engine cannot say" case.
    func supportedLocales() async -> [Locale] {
        script.supportedLocales
    }

    func stop() async -> String {
        guard isRunning else { return "" }
        isRunning = false
        stopCount += 1
        continuation?.finish()
        continuation = nil
        return script.finalText
    }

    // MARK: Test controls

    /// Moves `assetState()` on by one entry of the script.
    func advanceAssetState() {
        if stateIndex + 1 < script.states.count {
            stateIndex += 1
        }
    }

    /// Suspends until at least `expected` recordings have started, so a test
    /// never races the task that `transcribe` spawns.
    func waitForStart(_ expected: Int) async -> Bool {
        for _ in 0..<10_000 {
            if startCount >= expected { return true }
            await Task.yield()
        }
        return false
    }

    // MARK: Internals

    private func begin(
        contextualTerms: [String],
        continuation: AsyncThrowingStream<TranscriptionUpdate, Error>.Continuation
    ) async {
        if let previous = self.continuation {
            self.continuation = nil
            previous.finish(
                throwing: PencilLoopError.speechUnavailable(reason: "Another recording started.")
            )
        }

        self.continuation = continuation
        receivedTerms = contextualTerms
        isRunning = true
        startCount += 1

        for update in script.updates {
            continuation.yield(update)
        }
        if let failure = script.failure {
            self.continuation = nil
            isRunning = false
            continuation.finish(throwing: failure)
        }
    }
}
