//
//  AppSettingsStoreTests.swift
//  StorageTests
//
//  Settings, and the security-scoped bookmark Sync hands us to keep.
//
//  Each test uses its own `UserDefaults` suite so that nothing here can see —
//  or corrupt — the developer's own defaults.
//

import XCTest
import Foundation
import Core
@testable import Storage

final class AppSettingsStoreTests: XCTestCase {

    private var suiteName = ""

    override func setUp() {
        super.setUp()
        suiteName = "co.pencil-loop.tests." + UUID().uuidString
    }

    override func tearDown() {
        UserDefaults().removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testAFreshInstallReadsTheInitialSettings() async {
        let store = AppSettingsStore(suiteName: suiteName)
        let settings = await store.settings

        XCTAssertEqual(settings, AppSettings.initial)
        XCTAssertNil(settings.syncFolderBookmark)
        XCTAssertFalse(settings.hasCompletedFirstRun)
        XCTAssertEqual(settings.transcriptionLocaleIdentifier, "en-GB")
    }

    func testUpdatePersistsAcrossStores() async throws {
        let store = AppSettingsStore(suiteName: suiteName)
        var settings = await store.settings
        settings.pageTint = .sepia
        settings.sendInkedPagesAsImages = false
        settings.ink = InkDefaults(tool: .marker, widthPoints: 5, tintHex: "#0A84FF")
        try await store.update(settings)

        let reopened = AppSettingsStore(suiteName: suiteName)
        let reloaded = await reopened.settings

        XCTAssertEqual(reloaded.pageTint, .sepia)
        XCTAssertFalse(reloaded.sendInkedPagesAsImages)
        XCTAssertEqual(reloaded.ink.tool, .marker)
        XCTAssertEqual(reloaded.ink.tintHex, "#0A84FF")
    }

    func testBookmarkRoundTrips() async throws {
        let store = AppSettingsStore(suiteName: suiteName)
        let bookmark = Data("a security-scoped bookmark".utf8)

        try await store.setSyncFolder(bookmark: bookmark, displayName: "Pencil Loop")

        let stored = await store.syncFolderBookmark
        XCTAssertEqual(stored, bookmark)
        let settings = await store.settings
        XCTAssertEqual(settings.syncFolderDisplayName, "Pencil Loop")

        let reopened = AppSettingsStore(suiteName: suiteName)
        let reloaded = await reopened.settings
        XCTAssertEqual(reloaded.syncFolderBookmark, bookmark)
        XCTAssertEqual(reloaded.syncFolderDisplayName, "Pencil Loop")
    }

    func testForgettingTheFolderKeepsEveryOtherSetting() async throws {
        let store = AppSettingsStore(suiteName: suiteName)
        var settings = await store.settings
        settings.pageTint = .cream
        try await store.update(settings)
        try await store.setSyncFolder(bookmark: Data([0x01]), displayName: "Pencil Loop")

        try await store.setSyncFolder(bookmark: nil, displayName: nil)

        let after = await store.settings
        XCTAssertNil(after.syncFolderBookmark, "no bookmark sends the app back to first run")
        XCTAssertNil(after.syncFolderDisplayName)
        XCTAssertEqual(after.pageTint, .cream)
    }

    func testCompletingFirstRunIsIdempotent() async throws {
        let store = AppSettingsStore(suiteName: suiteName)
        try await store.completeFirstRun()
        try await store.completeFirstRun()

        let settings = await store.settings
        XCTAssertTrue(settings.hasCompletedFirstRun)
    }
}
