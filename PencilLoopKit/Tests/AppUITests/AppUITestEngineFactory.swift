//
//  AppUITestEngineFactory.swift
//  AppUITests
//
//  Counts engines, and takes as long to build one as the real factory does.
//
//  `SpeechEngineFactory.makeEngine(locale:)` asks the system which languages the
//  analyser supports, so building an engine suspends — and that suspension is
//  the window `DeferredSpeechTranscriber` has to hold shut. A stub that returned
//  an engine immediately would close the window and prove nothing, so this one
//  sleeps first.
//

import Foundation
import Core

/// A stand-in for `SpeechEngineFactory` that records every build.
actor AppUITestEngineFactory {

    /// The locale identifier of every engine built, in order.
    private(set) var builds: [String] = []

    private var engines: [AppUITestSpeechEngine] = []

    private let delayMilliseconds: Int

    /// - Parameter delayMilliseconds: how long a build takes. Long enough that
    ///   concurrent callers genuinely overlap in it.
    init(delayMilliseconds: Int = 20) {
        self.delayMilliseconds = delayMilliseconds
    }

    /// The closure `DeferredSpeechTranscriber` is built with.
    nonisolated func makeEngine() -> @Sendable (Locale) async -> any SpeechTranscribing {
        { locale in await self.build(locale) }
    }

    var buildCount: Int { builds.count }

    /// The nth engine built, counting from one, or nil when there is no such
    /// engine yet.
    func engine(_ ordinal: Int) -> AppUITestSpeechEngine? {
        guard ordinal >= 1, ordinal <= engines.count else { return nil }
        return engines[ordinal - 1]
    }

    /// Waits until at least `count` engines exist. Bounded, so a failure is a
    /// failed assertion rather than a hung suite.
    func waitForBuilds(_ count: Int) async {
        for _ in 0..<400 {
            if engines.count >= count { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    private func build(_ locale: Locale) async -> any SpeechTranscribing {
        try? await Task.sleep(for: .milliseconds(delayMilliseconds))
        let name = "engine-\(engines.count + 1)-\(locale.identifier)"
        // The final text is the engine's own name, so a test can say which
        // engine a `stop()` reached rather than only that one answered.
        let engine = AppUITestSpeechEngine(name: name, finalText: name)
        builds.append(locale.identifier)
        engines.append(engine)
        return engine
    }
}
