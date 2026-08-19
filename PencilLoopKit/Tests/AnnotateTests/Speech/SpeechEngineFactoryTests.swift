//
//  SpeechEngineFactoryTests.swift
//  AnnotateTests · Speech
//
//  The selection rule is a pure function of a preference and three booleans
//  precisely so it can be tested here rather than discovered on a device.
//

import XCTest
import Core
@testable import Annotate

final class SpeechEngineFactoryTests: XCTestCase {

    private func facts(
        compiledIn: Bool = true,
        analyserLocale: Bool = true,
        legacyLocale: Bool = true
    ) -> SpeechEngineFactory.Facts {
        SpeechEngineFactory.Facts(
            analyserCompiledIn: compiledIn,
            analyserSupportsLocale: analyserLocale,
            legacySupportsLocale: legacyLocale
        )
    }

    func testAutomaticPrefersTheAnalyserWhenItSupportsTheLanguage() {
        XCTAssertEqual(
            SpeechEngineFactory.kind(for: .automatic, facts: facts()),
            .analyser
        )
    }

    func testAutomaticFallsBackWhenTheAnalyserDoesNotKnowTheLanguage() {
        XCTAssertEqual(
            SpeechEngineFactory.kind(for: .automatic, facts: facts(analyserLocale: false)),
            .legacy
        )
    }

    func testAutomaticFallsBackInATriageBuild() {
        XCTAssertEqual(
            SpeechEngineFactory.kind(for: .automatic, facts: facts(compiledIn: false)),
            .legacy
        )
    }

    func testAnExplicitLegacyPreferenceAlwaysWins() {
        for compiledIn in [true, false] {
            for analyserLocale in [true, false] {
                XCTAssertEqual(
                    SpeechEngineFactory.kind(
                        for: .legacy,
                        facts: facts(compiledIn: compiledIn, analyserLocale: analyserLocale)
                    ),
                    .legacy
                )
            }
        }
    }

    func testAnExplicitAnalyserPreferenceSurvivesAnUnsupportedLanguage() {
        // The engine reports `.unavailable` with a sentence, which is more use
        // than quietly substituting a different engine.
        XCTAssertEqual(
            SpeechEngineFactory.kind(for: .analyser, facts: facts(analyserLocale: false)),
            .analyser
        )
    }

    func testAnExplicitAnalyserPreferenceCannotSurviveATriageBuild() {
        XCTAssertEqual(
            SpeechEngineFactory.kind(for: .analyser, facts: facts(compiledIn: false)),
            .legacy
        )
    }

    func testThereIsAlwaysAnEngineEvenWhenNothingSupportsTheLanguage() {
        for preference in SpeechEngineFactory.Preference.allCases {
            let chosen = SpeechEngineFactory.kind(
                for: preference,
                facts: facts(compiledIn: false, analyserLocale: false, legacyLocale: false)
            )
            XCTAssertEqual(chosen, .legacy, "\(preference) left the user without an engine")
        }
    }

    func testTheCompileTimeFlagMatchesTheBuildThisRanIn() {
        #if PENCILLOOP_LEGACY_SPEECH
        XCTAssertFalse(SpeechEngineFactory.isAnalyserCompiledIn)
        #else
        XCTAssertTrue(SpeechEngineFactory.isAnalyserCompiledIn)
        #endif
    }
}
