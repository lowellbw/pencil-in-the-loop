//
//  DeferredSpeechTranscriber.swift
//  AppUI · Support
//
//  The transcriber the environment holds, in front of the engine the factory
//  has not built yet.
//
//  ─── TWO PROBLEMS, ONE OBJECT ────────────────────────────────────────────────
//  1. `SpeechEngineFactory.makeEngine(settings:)` is `async` — it asks the
//     system which languages the analyser supports — and `AppEnvironment` is
//     built synchronously at launch, where nothing may await anything.
//  2. The dictation language is a setting (docs/02-spec.md § S6), and an engine
//     is built for one locale. Changing the language in Settings has to change
//     what the next comment is transcribed by, without anything having to
//     remember to rebuild an engine.
//
//  So the engine is built on first use, for whatever locale the settings say,
//  and rebuilt when that identifier changes. Cold-launch cost is nothing, and
//  the first press pays for it — which is what `prewarm()` is for, and the
//  comment gesture already calls that on touch-down, before the long press has
//  resolved (Core/Contracts/Protocols.swift § SpeechTranscribing).
//
//  ─── WHY THE BUILD IS A TASK AND NOT AN ENGINE ───────────────────────────────
//  An actor serialises statements, not transactions. Building an engine has two
//  suspension points in it — the settings read and the factory — and any caller
//  that suspends in the middle lets every other caller into the same window.
//  The comment popover always produces three of them within about 400ms:
//  `present()` asks for `assetState()`, the `.armed` trigger calls `prewarm()`,
//  and `.holdRecognised` calls `transcribe(contextualTerms:)`. Each one used to
//  see `engine == nil`, build its own, and assign last-writer-wins — so
//  `prewarm()` warmed an engine nobody recorded through, and worse, `stop()`
//  read the field rather than the engine the recording was actually bound to
//  and returned "" from an engine that had never recorded. The machine took
//  that as `.nothingHeard` and the dictated comment was thrown away, while the
//  other engine still held the audio session and the microphone indicator
//  stayed lit.
//
//  So what is memoised is the *build*, not its result: the check and the
//  assignment happen with no await between them, and the second caller awaits
//  the first caller's `Task`. And a recording binds to the engine it resolved,
//  by identity, so `stop()` can never address a different one.
//  ─────────────────────────────────────────────────────────────────────────────
//

import Foundation
import Annotate
import Core

/// A `SpeechTranscribing` that builds its engine when it is first needed, for
/// the language the user has chosen.
///
/// **On failure or unavailability:** identical to whatever engine it wraps —
/// `assetState()` reports it, `transcribe(contextualTerms:)` finishes the
/// stream with `PencilLoopError.speechUnavailable` or `.permissionDenied`, and
/// the comment popover still opens so the user can scribble instead. This type
/// adds no failure of its own: there is no path here that can refuse to produce
/// an engine, because `SpeechEngineFactory` always returns one.
public actor DeferredSpeechTranscriber: SpeechTranscribing {

    // The two types below are `nonisolated` because AppUI's default isolation
    // is `MainActor` (STYLE.md § 6) and these are this actor's own private
    // state — a main-actor value inside an actor could not be read from it.

    /// One engine being built, or already built, for one language.
    ///
    /// Held as the `Task` rather than as its result so that concurrent callers
    /// share a build instead of each starting one: creating the task and
    /// storing it happen in the same actor step, which the two awaits inside it
    /// do not interrupt.
    private nonisolated struct Build {

        /// Distinguishes this build from the one that replaces it, so a
        /// recording can say which engine it is holding without the engines
        /// themselves needing to be class-bound.
        let id: UUID

        /// The BCP-47 identifier this engine was built for, so a language
        /// change in Settings is noticed without anyone announcing it.
        let identifier: String

        let task: Task<any SpeechTranscribing, Never>
    }

    /// A recording in flight, and the engine it is bound to.
    private nonisolated struct Recording {

        /// Identifies one call to `transcribe(contextualTerms:)`, so a stream
        /// that has already been replaced cannot stop its successor's engine.
        let id: UUID

        let buildId: UUID

        let engine: any SpeechTranscribing
    }

    private let settings: any SettingsStoring

    /// How an engine is made. The app passes nothing and gets
    /// `SpeechEngineFactory`; `AppUITests` passes a counting stub, which is the
    /// only way to assert that concurrent callers share one build.
    private let makeEngine: @Sendable (Locale) async -> any SpeechTranscribing

    private var build: Build?

    private var recording: Recording?

    /// Where the next recording's audio is also written. Survives a rebuild of
    /// the engine, which is why it is held here and not in one.
    private var clipDestination: URL?

    public init(settings: any SettingsStoring) {
        self.settings = settings
        self.makeEngine = { locale in
            await SpeechEngineFactory.makeEngine(locale: locale)
        }
    }

    /// - Parameter makeEngine: the factory, injectable for tests. Called at most
    ///   once per language, from inside the memoised build.
    init(
        settings: any SettingsStoring,
        makeEngine: @escaping @Sendable (Locale) async -> any SpeechTranscribing
    ) {
        self.settings = settings
        self.makeEngine = makeEngine
    }

    // MARK: - SpeechTranscribing

    public func assetState() async -> SpeechAssetState {
        await current().assetState()
    }

    public func prepareAssets() async {
        await current().prepareAssets()
    }

    public func prewarm() async {
        await current().prewarm()
    }

    public func supportedLocales() async -> [Locale] {
        await current().supportedLocales()
    }

    /// The contract declares this synchronous, so the stream is returned at once
    /// and the engine is resolved inside it. A caller sees the same thing either
    /// way: a stream that yields when there is something to yield.
    ///
    /// The recording's identity is minted here, before the stream exists, so
    /// that `onTermination` can name the recording it is cancelling rather than
    /// whatever happens to be running by the time it runs.
    public nonisolated func transcribe(
        contextualTerms: [String]
    ) -> AsyncThrowingStream<TranscriptionUpdate, Error> {
        let recordingId = UUID()
        return AsyncThrowingStream { continuation in
            let work = Task {
                let engine = await self.beginRecording(recordingId)

                // Cancelled while the engine was still being built. Stopping it
                // here is what releases the audio session it just opened.
                if Task.isCancelled {
                    _ = await self.stopRecording(recordingId)
                    await self.endRecording(recordingId)
                    continuation.finish()
                    return
                }

                do {
                    for try await update in engine.transcribe(contextualTerms: contextualTerms) {
                        continuation.yield(update)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
                await self.endRecording(recordingId)
            }
            continuation.onTermination = { termination in
                // Only a consumer walking away means stop, exactly as the
                // engines themselves treat it: `.finished` is us finishing the
                // stream, and tearing the microphone down on that would pull it
                // out from under the recording that replaced this one.
                guard case .cancelled = termination else { return }
                work.cancel()
                Task { _ = await self.stopRecording(recordingId) }
            }
        }
    }

    /// Ends whatever is recording and returns its final text.
    ///
    /// Addresses the engine the running stream resolved, never the field: those
    /// were once allowed to be different engines and the difference cost the
    /// user the comment they had just dictated. With nothing recording it still
    /// stops the built engine, because a pre-warmed one holds the audio session
    /// and leaving it open is how the microphone indicator stays on.
    /// Held here rather than pushed at a built engine, because the engine for
    /// the next recording may not exist yet — and when it is rebuilt for a
    /// language change, the destination has to survive that.
    public func setClipDestination(_ url: URL?) async {
        clipDestination = url
        if let recording { await recording.engine.setClipDestination(url) }
    }

    /// Asks the engine the running stream resolved, for the same reason `stop()`
    /// does: the clip belongs to the recording that made it, not to whichever
    /// engine the field happens to hold now.
    public func finishedClip() async -> URL? {
        clipDestination = nil
        if let recording { return await recording.engine.finishedClip() }
        guard let build else { return nil }
        return await build.task.value.finishedClip()
    }

    public func stop() async -> String {
        if let recording { return await recording.engine.stop() }
        guard let build else { return "" }
        let engine = await build.task.value
        // A recording may have bound itself while that build was finishing. It
        // owns the engine now, and its own stop is the one that matters.
        if let recording { return await recording.engine.stop() }
        return await engine.stop()
    }

    // MARK: - Internals

    /// The engine for the language currently chosen.
    private func current() async -> any SpeechTranscribing {
        await currentBuild().task.value
    }

    /// The build for the language currently chosen, starting one if the choice
    /// has moved.
    ///
    /// The settings read suspends, so the check and the assignment below are
    /// deliberately the first two statements after it with nothing awaited
    /// between them: that is the whole of what stops two callers building two
    /// engines.
    private func currentBuild() async -> Build {
        let identifier = await settings.settings.transcriptionLocaleIdentifier
        if let build, build.identifier == identifier {
            return build
        }

        let previous = build
        let replacement = Build(
            id: UUID(),
            identifier: identifier,
            task: Task {
                // Retiring the old engine first, inside the task rather than
                // before it, keeps the check-and-assign above uninterrupted
                // while still releasing the shared audio session before the new
                // engine asks for it.
                if let previous {
                    await self.retire(previous)
                }
                return await self.makeEngine(Locale(identifier: identifier))
            }
        )
        build = replacement
        return replacement
    }

    /// Stops the engine a language change has replaced.
    ///
    /// A recording bound to it is left alone: the user cannot change the
    /// language from inside the comment popover, but Settings and a running
    /// dictation are two screens and one process, and stopping the engine
    /// underneath a recording would end it with nothing said and nothing shown.
    /// `endRecording(_:)` stops it when its stream finishes instead.
    private func retire(_ previous: Build) async {
        let engine = await previous.task.value
        guard recording?.buildId != previous.id else { return }
        _ = await engine.stop()
    }

    /// Resolves the engine for a new recording and records which one it is.
    private func beginRecording(_ recordingId: UUID) async -> any SpeechTranscribing {
        let resolved = await currentBuild()
        let engine = await resolved.task.value
        recording = Recording(id: recordingId, buildId: resolved.id, engine: engine)
        return engine
    }

    /// Stops one named recording, or nothing at all when it has already been
    /// replaced or has already finished.
    private func stopRecording(_ recordingId: UUID) async -> String {
        guard let recording, recording.id == recordingId else { return "" }
        return await recording.engine.stop()
    }

    /// The stream for one recording has finished.
    private func endRecording(_ recordingId: UUID) async {
        guard let finished = recording, finished.id == recordingId else { return }
        recording = nil

        // The language changed while this was recording, so `retire(_:)` left
        // this engine alone. Nobody else will ever reach it, and it is still
        // holding the audio session.
        guard build?.id != finished.buildId else { return }
        _ = await finished.engine.stop()
    }
}
