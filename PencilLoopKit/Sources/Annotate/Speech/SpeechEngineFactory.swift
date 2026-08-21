//
//  SpeechEngineFactory.swift
//  Annotate · Speech
//
//  The resilience seam. This file holds the only reference in the repo to
//  `AnalyserSpeechEngine`, and holds it inside a single `#if`, so that the
//  triage step described in docs/03-architecture.md § 4 is literally what it
//  claims to be: flip the factory to legacy, delete one file, everything else
//  stands.
//

import Foundation
import os
import Core

/// Chooses which engine the app dictates through.
///
/// A namespace, not an object: choosing an engine is a decision, not a
/// dependency, and every input to it comes from the system.
///
/// **Two seams, not one.** The runtime one — `kind(for:facts:)` — picks the
/// analyser when it can transcribe the user's language and the fallback when it
/// cannot, on the device, every launch. The compile-time one —
/// `PENCILLOOP_LEGACY_SPEECH` — exists for the case the runtime seam cannot
/// help with: the iOS 26 API not being shaped the way we wrote
/// `AnalyserSpeechEngine` against, which is a build failure rather than a
/// runtime answer.
///
/// **The fallback, in full:**
///
/// 1. Add `.define("PENCILLOOP_LEGACY_SPEECH")` to the `Annotate` target in
///    PencilLoopKit/Package.swift, beside the `PENCILLOOP_STROKE_RECOGNIZER`
///    define already sitting there for the same kind of reason.
/// 2. Delete `Sources/Annotate/Speech/AnalyserSpeechEngine.swift`.
///
/// Nothing else changes. `SpeechTranscribing` is unchanged, the popover is
/// unchanged, `TermListCorrector` is unchanged, `VoiceRecordingMachine` is
/// unchanged, and the tests below still pass because the only thing they assert
/// about the analyser is what the pure selection rule does with a boolean.
public enum SpeechEngineFactory {

    /// What the caller wants, when it has an opinion.
    public enum Preference: String, Sendable, Hashable, CaseIterable {

        /// Analyser when it can handle the language, fallback otherwise. What
        /// the app ships with.
        case automatic

        /// Force `SpeechAnalyzer`, even for a language it may not have assets
        /// for — the engine will report that honestly through `assetState()`.
        case analyser

        /// Force `SFSpeechRecognizer`. Also what `PENCILLOOP_LEGACY_SPEECH`
        /// produces regardless of what is asked for.
        case legacy
    }

    /// Which engine was chosen.
    public enum Kind: String, Sendable, Hashable, CaseIterable {
        case analyser
        case legacy
    }

    /// What the device says, gathered once so the decision itself stays pure
    /// and testable without a device.
    public struct Facts: Sendable, Hashable {

        /// False in a `PENCILLOOP_LEGACY_SPEECH` build, where the analyser file
        /// is not compiled in at all.
        public var analyserCompiledIn: Bool

        /// Whether `SpeechTranscriber` lists this language as supported.
        public var analyserSupportsLocale: Bool

        /// Whether `SFSpeechRecognizer` knows this language at all.
        public var legacySupportsLocale: Bool

        /// Whether the analyser's model for this language is on the device
        /// **right now**, as opposed to merely being a language it knows.
        ///
        /// Defaults to true so that a caller reasoning only about languages
        /// gets the behaviour this rule always had.
        public var analyserAssetsInstalled: Bool

        /// Whether `SFSpeechRecognizer` can transcribe this language without a
        /// network round trip right now — `supportsOnDeviceRecognition`.
        ///
        /// Only ever used to rescue a recording the analyser could not take.
        /// Defaults to false, which is the conservative answer.
        public var legacyTranscribesOnDevice: Bool

        public init(
            analyserCompiledIn: Bool,
            analyserSupportsLocale: Bool,
            legacySupportsLocale: Bool,
            analyserAssetsInstalled: Bool = true,
            legacyTranscribesOnDevice: Bool = false
        ) {
            self.analyserCompiledIn = analyserCompiledIn
            self.analyserSupportsLocale = analyserSupportsLocale
            self.legacySupportsLocale = legacySupportsLocale
            self.analyserAssetsInstalled = analyserAssetsInstalled
            self.legacyTranscribesOnDevice = legacyTranscribesOnDevice
        }
    }

    /// Whether this build contains the analyser at all.
    public static var isAnalyserCompiledIn: Bool {
        #if PENCILLOOP_LEGACY_SPEECH
        return false
        #else
        return true
        #endif
    }

    /// The decision, as a pure function of a preference and three booleans.
    ///
    /// - An explicit `.legacy` always wins: it is the escape hatch and an
    ///   escape hatch that argues is not one.
    /// - An explicit `.analyser` wins whenever the analyser is compiled in,
    ///   even for an unsupported language — the engine then reports
    ///   `.unavailable` with a sentence, which is more useful than silently
    ///   substituting a different engine behind the user's back.
    /// - `.automatic` takes the analyser only when it is both compiled in and
    ///   supports the language, and the fallback otherwise.
    /// - `.automatic` also **stands aside for the fallback when the analyser's
    ///   model has not been downloaded yet** and the fallback can transcribe
    ///   the language on device now. The analyser refuses a recording outright
    ///   until its assets land — "the dictation model is still downloading",
    ///   which is the sentence somebody sees when they hold to talk on a fresh
    ///   install and is indistinguishable, from where they are standing, from
    ///   dictation being broken. The fallback's model is provisioned by iOS
    ///   with the speech permission and is usually already there.
    ///
    /// There is deliberately no "neither" answer. When no engine can transcribe
    /// the user's language, the caller still gets an engine, that engine still
    /// reports `.unavailable` through `assetState()`, the popover still opens,
    /// and the user still writes the comment by hand (docs/02-spec.md § S3).
    public static func kind(for preference: Preference, facts: Facts) -> Kind {
        switch preference {
        case .legacy:
            return .legacy
        case .analyser:
            return facts.analyserCompiledIn ? .analyser : .legacy
        case .automatic:
            guard facts.analyserCompiledIn, facts.analyserSupportsLocale else { return .legacy }
            if facts.analyserAssetsInstalled == false && facts.legacyTranscribesOnDevice {
                return .legacy
            }
            return .analyser
        }
    }

    /// Builds the engine for a language.
    ///
    /// `async` because deciding requires asking the system which languages the
    /// analyser supports. Call it once when a document opens, not per comment:
    /// an engine is cheap to hold and the first press should not be waiting on
    /// this (docs/03-architecture.md § Performance targets).
    public static func makeEngine(
        locale: Locale,
        preference: Preference = .automatic
    ) async -> any SpeechTranscribing {
        #if PENCILLOOP_LEGACY_SPEECH
        // Triage build: AnalyserSpeechEngine.swift is not in the target.
        return LegacySpeechEngine(locale: locale)
        #else
        let facts = Facts(
            analyserCompiledIn: true,
            analyserSupportsLocale: await AnalyserSpeechEngine.supportsLocale(locale),
            legacySupportsLocale: LegacySpeechEngine.supportsLocale(locale),
            analyserAssetsInstalled: await AnalyserSpeechEngine.isInstalled(locale),
            legacyTranscribesOnDevice: LegacySpeechEngine.supportsOnDeviceTranscription(for: locale)
        )
        switch kind(for: preference, facts: facts) {
        case .analyser:
            return AnalyserSpeechEngine(locale: locale)
        case .legacy:
            return LegacySpeechEngine(locale: locale)
        }
        #endif
    }

    /// The engine for the user's chosen dictation language
    /// (`AppSettings.transcriptionLocale`).
    public static func makeEngine(
        settings: AppSettings,
        preference: Preference = .automatic
    ) async -> any SpeechTranscribing {
        await makeEngine(locale: settings.transcriptionLocale, preference: preference)
    }
}
