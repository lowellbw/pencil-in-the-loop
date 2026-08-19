//
//  SpeechAvailabilityTests.swift
//  AnnotateTests · Speech
//
//  The precedence rules behind the one Settings row (docs/03-architecture.md
//  § 4). Nothing here touches a permission or an asset catalog; that is the
//  point of having split the mapping out.
//

import XCTest
import Core
@testable import Annotate

final class SpeechAvailabilityTests: XCTestCase {

    private func state(
        permission: SpeechAvailability.Permission = .granted,
        localeSupported: Bool = true,
        assetsInstalled: Bool = true,
        downloadFraction: Double? = nil,
        downloadRequested: Bool = false
    ) -> SpeechAssetState {
        SpeechAvailability.state(
            permission: permission,
            localeSupported: localeSupported,
            localeDisplayName: "British English",
            assetsInstalled: assetsInstalled,
            downloadFraction: downloadFraction,
            downloadRequested: downloadRequested
        )
    }

    func testInstalledAndPermittedIsReady() {
        XCTAssertEqual(state(), .ready)
    }

    func testAnUnaskedPermissionIsNotAFailure() {
        // We ask at the first press, not at launch.
        XCTAssertEqual(state(permission: .notDetermined), .ready)
    }

    func testARefusedMicrophoneBeatsEverythingElse() {
        guard case let .unavailable(reason) = state(
            permission: .denied,
            localeSupported: false,
            assetsInstalled: false
        ) else {
            return XCTFail("a refused microphone must be reported")
        }
        XCTAssertTrue(reason.contains("Microphone"))
        XCTAssertTrue(reason.contains("hand"), "the row must offer a way out: \(reason)")
    }

    func testAnUnsupportedLanguageNamesItself() {
        guard case let .unavailable(reason) = state(localeSupported: false, assetsInstalled: false) else {
            return XCTFail("an unsupported language must be reported")
        }
        XCTAssertTrue(reason.contains("British English"))
    }

    func testADownloadInProgressReportsItsFraction() {
        XCTAssertEqual(
            state(assetsInstalled: false, downloadFraction: 0.42, downloadRequested: true),
            .downloading(progress: 0.42)
        )
    }

    func testAFractionOutsideZeroToOneIsClamped() {
        XCTAssertEqual(
            state(assetsInstalled: false, downloadFraction: 1.7, downloadRequested: true),
            .downloading(progress: 1)
        )
        XCTAssertEqual(
            state(assetsInstalled: false, downloadFraction: -3, downloadRequested: true),
            .downloading(progress: 0)
        )
    }

    func testAQueuedDownloadWithNoProgressYetIsIndeterminate() {
        XCTAssertEqual(
            state(assetsInstalled: false, downloadRequested: true),
            .downloading(progress: nil)
        )
    }

    func testNotDownloadedAndNotRequestedExplainsItself() {
        guard case let .unavailable(reason) = state(assetsInstalled: false) else {
            return XCTFail("a missing model must be reported")
        }
        XCTAssertTrue(reason.contains("British English"))
        XCTAssertTrue(reason.contains("background"))
    }

    func testInstalledAssetsBeatAStaleDownloadFraction() {
        XCTAssertEqual(state(assetsInstalled: true, downloadFraction: 0.5), .ready)
    }

    func testTheNarrowerOfTwoPermissionsWins() {
        XCTAssertEqual(SpeechAvailability.narrower(.granted, .granted), .granted)
        XCTAssertEqual(SpeechAvailability.narrower(.granted, .notDetermined), .notDetermined)
        XCTAssertEqual(SpeechAvailability.narrower(.notDetermined, .denied), .denied)
        XCTAssertEqual(SpeechAvailability.narrower(.denied, .granted), .denied)
    }
}
