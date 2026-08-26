//
//  AppSettingsGroupTests.swift
//  StorageTests
//
//  `AppSettingsStore`'s second face, `DocumentGrouping` (docs/02-spec.md § S1).
//
//  Each test uses its own `UserDefaults` suite, like `AppSettingsStoreTests`,
//  so nothing here can see or corrupt the developer's own defaults.
//
//  The test that matters most is
//  `testAMalformedGroupMapCostsTheGroupsAndNotTheSyncFolder`. Group assignments
//  are the only collection in the settings blob and therefore the likeliest
//  thing in it to be malformed; `AppSettingsStore.load` answers any decode
//  failure with `AppSettings.initial`, which throws the user back to the folder
//  picker. That test is what stands between a bad map and a lost folder.
//

import XCTest
import Foundation
import Core
@testable import Storage

final class AppSettingsGroupTests: XCTestCase {

    private var suiteName = ""

    override func setUp() {
        super.setUp()
        suiteName = "co.pencil-loop.tests." + UUID().uuidString
    }

    override func tearDown() {
        UserDefaults().removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testAFreshInstallHasNothingFiled() async {
        let store = AppSettingsStore(suiteName: suiteName)

        let groups = await store.groups()

        XCTAssertEqual(groups, .empty)
    }

    func testFilingADocumentSurvivesAReopen() async throws {
        let store = AppSettingsStore(suiteName: suiteName)
        try await store.setGroupName("Attention Papers", forFolderName: "2026-08-17-attention")

        let reopened = AppSettingsStore(suiteName: suiteName)
        let groups = await reopened.groups()

        XCTAssertEqual(groups.name(forFolderName: "2026-08-17-attention"), "Attention Papers")
    }

    func testFilingDoesNotDisturbAnythingElseInSettings() async throws {
        let store = AppSettingsStore(suiteName: suiteName)
        try await store.completeFirstRun()

        try await store.setGroupName("Q3 Planning", forFolderName: "a")

        let settings = await store.settings
        XCTAssertTrue(settings.hasCompletedFirstRun)
    }

    func testASenderCannotMoveADocumentTheUserFiled() async throws {
        let store = AppSettingsStore(suiteName: suiteName)
        try await store.setGroupName("Q3 Planning", forFolderName: "a")

        try await store.adoptGroupName("Attention Papers", forFolderName: "a")

        let groups = await store.groups()
        XCTAssertEqual(groups.name(forFolderName: "a"), "Q3 Planning")
    }

    func testRenamingMovesEveryDocumentInOneWrite() async throws {
        let store = AppSettingsStore(suiteName: suiteName)
        try await store.setGroupName("Attention Papers", forFolderName: "a")
        try await store.setGroupName("Attention Papers", forFolderName: "b")

        try await store.renameGroup("Attention Papers", to: "Transformers")

        let groups = await store.groups()
        XCTAssertEqual(groups.assignments, ["a": "Transformers", "b": "Transformers"])
    }

    func testRenamingToNothingIsRefusedRatherThanApplied() async throws {
        let store = AppSettingsStore(suiteName: suiteName)
        try await store.setGroupName("Attention Papers", forFolderName: "a")

        do {
            try await store.renameGroup("Attention Papers", to: "  ")
            XCTFail("A group with no name is not a rename, it is a deletion nobody asked for.")
        } catch {
            let groups = await store.groups()
            XCTAssertEqual(groups.name(forFolderName: "a"), "Attention Papers")
        }
    }

    func testPruningDropsDocumentsTheLibraryNoLongerHolds() async throws {
        let store = AppSettingsStore(suiteName: suiteName)
        try await store.setGroupName("Attention Papers", forFolderName: "a")
        try await store.setGroupName("Q3 Planning", forFolderName: "b")

        try await store.pruneGroups(keeping: ["a"])

        let groups = await store.groups()
        XCTAssertEqual(groups.assignments, ["a": "Attention Papers"])
    }

    func testAMalformedGroupMapCostsTheGroupsAndNotTheSyncFolder() async throws {
        // Built by encoding real settings and then corrupting exactly one key,
        // so that a failure here can only mean what it says. A hand-written blob
        // would prove nothing: a typo in any other field produces the same
        // fallback and the same red test, for a reason that is not the point.
        let valid = AppSettings(
            syncFolderBookmark: Data([1, 2, 3]),
            syncFolderDisplayName: "Reader",
            hasCompletedFirstRun: true
        )
        let encoded = try JSONEncoder().encode(valid)
        var blob = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        blob["documentGroups"] = "not a map"
        let corrupted = try JSONSerialization.data(withJSONObject: blob)
        UserDefaults(suiteName: suiteName)?.set(corrupted, forKey: AppSettingsStore.defaultsKey)

        let store = AppSettingsStore(suiteName: suiteName)
        let settings = await store.settings
        let groups = await store.groups()

        XCTAssertTrue(
            settings.hasCompletedFirstRun,
            "A group map this build cannot read must not land the user back on the first-run picker."
        )
        XCTAssertNotNil(settings.syncFolderBookmark, "Nor may it lose the folder they chose.")
        XCTAssertEqual(groups, .empty, "The groups are what a bad group map is allowed to cost.")
    }
}
