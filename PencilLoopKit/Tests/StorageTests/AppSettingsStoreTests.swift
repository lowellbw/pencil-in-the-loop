//
//  AppSettingsStoreTests.swift
//  StorageTests
//
//  Settings, the security-scoped bookmark Sync hands us to keep, and the relay
//  token that is the one setting not kept here at all.
//
//  Each test uses its own `UserDefaults` suite so that nothing here can see —
//  or corrupt — the developer's own defaults.
//
//  The test that matters most in this file is
//  `testSettingsWrittenBeforeTheServerTransportStillDecode`. `AppSettingsStore`
//  answers any decode failure with `AppSettings.initial` — no bookmark,
//  `hasCompletedFirstRun == false` — so a settings field added carelessly does
//  not crash, it quietly throws every existing user back to the folder picker
//  and loses the folder they chose. That test decodes a hand-written blob in the
//  shape this app shipped before the relay existed, and it is the only thing
//  standing between the next field and that outcome.
//

import XCTest
import Foundation
import Security
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

    // MARK: - Decoding what earlier builds wrote

    /// A settings blob in the exact shape this app wrote before `syncTransport`,
    /// `serverBaseURLString` and `serverDisplayName` existed.
    ///
    /// Written out by hand rather than encoded from a current `AppSettings`,
    /// because encoding one would produce today's shape and the test would then
    /// prove nothing at all — which is the failure mode this whole test is here
    /// to catch.
    private static let blobFromBeforeTheRelay = """
    {
      "syncFolderBookmark" : "Ym9va21hcmstYnl0ZXM=",
      "syncFolderDisplayName" : "Pencil",
      "pageTint" : "sepia",
      "ink" : { "tool" : "marker", "widthPoints" : 5, "tintHex" : "#0A84FF" },
      "transcriptionLocaleIdentifier" : "en-GB",
      "sendInkedPagesAsImages" : false,
      "hasCompletedFirstRun" : true
    }
    """

    func testSettingsWrittenBeforeTheServerTransportStillDecode() async {
        UserDefaults(suiteName: suiteName)?.set(
            Data(AppSettingsStoreTests.blobFromBeforeTheRelay.utf8),
            forKey: AppSettingsStore.defaultsKey
        )

        let settings = await AppSettingsStore(suiteName: suiteName).settings

        XCTAssertEqual(
            settings.syncFolderBookmark,
            Data(base64Encoded: "Ym9va21hcmstYnl0ZXM="),
            "the folder the user picked must survive the upgrade"
        )
        XCTAssertEqual(settings.syncFolderDisplayName, "Pencil")
        XCTAssertTrue(
            settings.hasCompletedFirstRun,
            "losing this sends an existing user back to the first-run picker"
        )
        XCTAssertEqual(settings.transport, .folder, "an upgrade never changes transport")
        XCTAssertNil(settings.syncTransport)
        XCTAssertNil(settings.serverBaseURLString)
        XCTAssertNil(settings.serverBaseURL)

        XCTAssertEqual(settings.pageTint, .sepia)
        XCTAssertEqual(settings.ink.tool, .marker)
        XCTAssertFalse(settings.sendInkedPagesAsImages)
    }

    func testABlobMissingAlmostEveryKeyFallsBackFieldByField() async {
        let sparse = """
        { "hasCompletedFirstRun" : true }
        """
        UserDefaults(suiteName: suiteName)?.set(
            Data(sparse.utf8),
            forKey: AppSettingsStore.defaultsKey
        )

        let settings = await AppSettingsStore(suiteName: suiteName).settings

        XCTAssertTrue(
            settings.hasCompletedFirstRun,
            "an absent key must fall back per field, not throw the whole blob away"
        )
        XCTAssertEqual(settings.pageTint, .none)
        XCTAssertEqual(settings.ink, InkDefaults.standard)
        XCTAssertEqual(settings.transcriptionLocaleIdentifier, "en-GB")
        XCTAssertTrue(settings.sendInkedPagesAsImages)
        XCTAssertEqual(settings.transport, .folder)
    }

    // MARK: - The server transport

    func testTheServerFieldsRoundTrip() async throws {
        let store = AppSettingsStore(suiteName: suiteName)
        var settings = await store.settings
        settings.syncTransport = .server
        settings.serverBaseURLString = "https://relay.example.com"
        settings.serverDisplayName = "The relay"
        try await store.update(settings)

        let reloaded = await AppSettingsStore(suiteName: suiteName).settings

        XCTAssertEqual(reloaded.syncTransport, .server)
        XCTAssertEqual(reloaded.transport, .server)
        XCTAssertEqual(reloaded.serverBaseURLString, "https://relay.example.com")
        XCTAssertEqual(reloaded.serverBaseURL?.host(), "relay.example.com")
        XCTAssertEqual(reloaded.serverDisplayName, "The relay")
    }

    func testAdoptingAServerKeepsTheFolderAndKeepsTheTokenOutOfDefaults() async throws {
        let keychain = KeychainDouble()
        let store = AppSettingsStore(
            suiteName: suiteName,
            tokenKeychain: SyncTokenKeychain(items: keychain.items)
        )
        try await store.setSyncFolder(bookmark: Data([0x01, 0x02]), displayName: "Pencil")

        try await store.setSyncServer(
            baseURLString: "https://relay.example.com",
            displayName: "The relay",
            token: "a-bearer-token"
        )

        let settings = await store.settings
        XCTAssertEqual(settings.transport, .server)
        XCTAssertEqual(
            settings.syncFolderBookmark,
            Data([0x01, 0x02]),
            "adopting a server must never cost the user their folder"
        )
        XCTAssertEqual(settings.syncFolderDisplayName, "Pencil")

        let token = await store.syncServerToken(forHost: "Relay.Example.com")
        XCTAssertEqual(token, "a-bearer-token", "a host is matched case-insensitively")

        let blob = UserDefaults(suiteName: suiteName)!.data(forKey: AppSettingsStore.defaultsKey)!
        XCTAssertFalse(
            String(decoding: blob, as: UTF8.self).contains("a-bearer-token"),
            "the token is a credential and the defaults blob is plaintext"
        )
    }

    func testAServerAddressWithNoHostIsRefusedAndChangesNothing() async throws {
        let keychain = KeychainDouble()
        let store = AppSettingsStore(
            suiteName: suiteName,
            tokenKeychain: SyncTokenKeychain(items: keychain.items)
        )

        do {
            try await store.setSyncServer(baseURLString: "not a url", displayName: nil, token: "t")
            XCTFail("a URL with no host has nowhere to file a token")
        } catch {
            // Expected.
        }

        let settings = await store.settings
        XCTAssertEqual(settings.transport, .folder)
        XCTAssertNil(settings.serverBaseURLString)
        XCTAssertEqual(keychain.calls, [], "nothing is written when the address is refused")
    }

    // MARK: - Keychain policy

    func testTheAccountIsTheLowercasedHostOfTheBaseURL() {
        XCTAssertEqual(
            SyncTokenKeychain.account(forBaseURLString: "https://Relay-Production.UP.railway.app/v1/"),
            "relay-production.up.railway.app"
        )
        XCTAssertEqual(SyncTokenKeychain.account(forHost: " Relay.Example.com "), "relay.example.com")
        XCTAssertNil(SyncTokenKeychain.account(forBaseURLString: "not a url"))
        XCTAssertNil(SyncTokenKeychain.account(forBaseURLString: "   "))
    }

    func testWritingATokenDeletesBeforeItAdds() throws {
        let double = KeychainDouble()
        let keychain = SyncTokenKeychain(items: double.items)

        try keychain.setToken("first", forAccount: "relay.example.com")
        try keychain.setToken("second", forAccount: "relay.example.com")

        XCTAssertEqual(
            double.calls,
            ["delete relay.example.com", "add relay.example.com",
             "delete relay.example.com", "add relay.example.com"],
            "delete-then-add is the only idempotent update"
        )
        XCTAssertEqual(keychain.token(forAccount: "relay.example.com"), "second")
    }

    func testAnAbsentTokenReadsAsNil() {
        let keychain = SyncTokenKeychain(items: KeychainDouble().items)

        XCTAssertNil(keychain.token(forAccount: "relay.example.com"))
    }

    func testTwoServersNeverShareAToken() throws {
        let keychain = SyncTokenKeychain(items: KeychainDouble().items)

        try keychain.setToken("first-token", forAccount: "one.example.com")

        XCTAssertNil(
            keychain.token(forAccount: "two.example.com"),
            "switching servers must not hand the new one the old one's token"
        )
        XCTAssertEqual(keychain.token(forAccount: "one.example.com"), "first-token")
    }

    func testForgettingATokenDeletesAndAddsNothing() throws {
        let double = KeychainDouble()
        let keychain = SyncTokenKeychain(items: double.items)
        try keychain.setToken("a-token", forAccount: "relay.example.com")
        double.calls = []

        try keychain.setToken(nil, forAccount: "relay.example.com")

        XCTAssertEqual(double.calls, ["delete relay.example.com"])
        XCTAssertNil(keychain.token(forAccount: "relay.example.com"))
    }

    func testAnEmptyTokenIsTheSameAsNoToken() throws {
        let keychain = SyncTokenKeychain(items: KeychainDouble().items)

        try keychain.setToken("", forAccount: "relay.example.com")

        XCTAssertNil(keychain.token(forAccount: "relay.example.com"))
    }

    func testAKeychainThatRefusesTheAddThrowsAndStoresNothing() {
        let double = KeychainDouble()
        double.addStatus = errSecDuplicateItem
        let keychain = SyncTokenKeychain(items: double.items)

        XCTAssertThrowsError(try keychain.setToken("a-token", forAccount: "relay.example.com"))
        XCTAssertNil(keychain.token(forAccount: "relay.example.com"))
    }

    // MARK: - The double

    /// The Keychain, in a dictionary.
    ///
    /// `SecItemAdd` with `kSecUseDataProtectionKeychain` fails in a bare test
    /// process whatever the code does, so what is tested here is the policy
    /// above the seam — account derivation, delete-then-add, nil for absent —
    /// and the real Keychain is on the hand-test list at the top of
    /// `SyncTokenKeychain.swift` (STYLE.md § 10).
    ///
    /// `@unchecked Sendable` because every test here drives it from one task.
    private final class KeychainDouble: @unchecked Sendable {

        private var stored: [String: Data] = [:]

        /// Every call in order, which is how delete-then-add is asserted.
        var calls: [String] = []

        /// What `add` answers. Set it to fail the write.
        var addStatus: OSStatus = errSecSuccess

        var items: SyncTokenKeychain.Items {
            SyncTokenKeychain.Items(
                read: { [self] account in
                    calls.append("read \(account)")
                    return stored[account]
                },
                delete: { [self] account in
                    calls.append("delete \(account)")
                    stored[account] = nil
                },
                add: { [self] account, secret in
                    calls.append("add \(account)")
                    guard addStatus == errSecSuccess else { return addStatus }
                    stored[account] = secret
                    return errSecSuccess
                }
            )
        }
    }
}
