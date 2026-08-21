//
//  AppSettingsInkResetTests.swift
//  StorageTests
//
//  The one-shot that brings a saved ink choice back to the shipped defaults
//  when those defaults move.
//
//  It exists because the tool picker writes every change the user makes
//  straight back into `AppSettings.ink`, so changing the shipped default
//  reaches nobody who has ever opened the picker. The reset is what reaches
//  them — and the part that has to be right is that it happens **once**. A
//  reset that repeats would undo a deliberate choice on every launch, silently,
//  and would look exactly like the app ignoring the tool picker.
//
//  Each test uses its own `UserDefaults` suite, like `AppSettingsStoreTests`.
//

import XCTest
import Foundation
import Core
@testable import Storage

final class AppSettingsInkResetTests: XCTestCase {

    private var suiteName = ""

    override func setUp() {
        super.setUp()
        suiteName = "co.pencil-loop.tests." + UUID().uuidString
    }

    override func tearDown() {
        UserDefaults().removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func write(_ settings: AppSettings) throws {
        let data = try JSONEncoder().encode(settings)
        UserDefaults(suiteName: suiteName)?.set(data, forKey: AppSettingsStore.defaultsKey)
    }

    private var marker: InkDefaults {
        InkDefaults(tool: .marker, widthPoints: 18, tintHex: "#FFCC00")
    }

    /// The case this was written for: a real install, carrying a marker chosen
    /// months ago, with no stamp because the stamp did not exist then.
    func testAnUnstampedBlobHasItsInkReset() async throws {
        var stored = AppSettings.initial
        stored.ink = marker
        stored.hasCompletedFirstRun = true
        stored.inkDefaultsGeneration = nil
        try write(stored)

        let settings = await AppSettingsStore(suiteName: suiteName).settings

        XCTAssertEqual(settings.ink, .standard)
        XCTAssertEqual(settings.ink.tool, .pen)
        XCTAssertEqual(settings.ink.widthPoints, InkDefaults.finestWidthPoints)
        XCTAssertEqual(settings.inkDefaultsGeneration, InkDefaults.generation)
    }

    /// Everything else in the blob is left exactly where it was. A reset that
    /// took the sync folder with it would put the user back on the picker.
    func testTheResetTouchesNothingButInk() async throws {
        var stored = AppSettings.initial
        stored.ink = marker
        stored.hasCompletedFirstRun = true
        stored.syncFolderDisplayName = "PencilLoop"
        stored.pageTint = .sepia
        stored.transcriptionLocaleIdentifier = "fr-FR"
        stored.inkDefaultsGeneration = nil
        try write(stored)

        let settings = await AppSettingsStore(suiteName: suiteName).settings

        XCTAssertTrue(settings.hasCompletedFirstRun)
        XCTAssertEqual(settings.syncFolderDisplayName, "PencilLoop")
        XCTAssertEqual(settings.pageTint, .sepia)
        XCTAssertEqual(settings.transcriptionLocaleIdentifier, "fr-FR")
    }

    /// A blob already at this generation is somebody's deliberate choice.
    func testAStampedBlobKeepsItsInk() async throws {
        var stored = AppSettings.initial
        stored.ink = marker
        stored.inkDefaultsGeneration = InkDefaults.generation
        try write(stored)

        let settings = await AppSettingsStore(suiteName: suiteName).settings

        XCTAssertEqual(settings.ink, marker, "a choice made after the reset is not undone")
    }

    /// **Once.** The stamp is written back immediately, so a second store over
    /// the same defaults — the next launch — sees a current blob and leaves the
    /// marker chosen in between alone.
    func testTheResetDoesNotRepeatOnTheNextLaunch() async throws {
        var stored = AppSettings.initial
        stored.ink = marker
        stored.inkDefaultsGeneration = nil
        try write(stored)

        // First launch: reset.
        let first = AppSettingsStore(suiteName: suiteName)
        let afterReset = await first.settings
        XCTAssertEqual(afterReset.ink, .standard)

        // The user picks the marker again, deliberately.
        var chosen = afterReset
        chosen.ink = marker
        try await first.update(chosen)

        // Second launch.
        let settings = await AppSettingsStore(suiteName: suiteName).settings
        XCTAssertEqual(settings.ink, marker, "the reset must not run a second time")
    }
}
