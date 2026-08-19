//
//  SyncTokenKeychain.swift
//  Storage · Settings
//
//  The relay's bearer token, and the one setting that may not live with the
//  others.
//
//  ─── WHY THIS IS NOT IN AppSettings ──────────────────────────────────────────
//  `AppSettingsStore` writes the whole settings struct to `UserDefaults` as one
//  JSON blob. That file is unencrypted, it is included in device backups, and it
//  is readable by anything that can read the container. A bearer token is a
//  credential: it is the entire authority to read every document this identity
//  has ever synced. So it goes in the Keychain, and `AppSettings` never learns
//  it exists.
//  ─────────────────────────────────────────────────────────────────────────────
//
//  Four decisions, each of which has a failure mode behind it:
//
//  · **`kSecAttrAccount` is the base URL's host**, not a fixed string. Point the
//    app at a second relay and it must not hand that relay the first one's
//    token — which is exactly what one shared account would do, silently, on the
//    first poll after the switch.
//  · **`kSecAttrAccessibleAfterFirstUnlock`.** The app polls in the background;
//    after a reboot the device may not have been unlocked since, and
//    `WhenUnlocked` would fail that poll. It is the least-permissive class that
//    still lets sync work.
//  · **`kSecUseDataProtectionKeychain`.** The modern, per-app keychain rather
//    than the file-based one every process on the system shares.
//  · **Delete, then add.** `SecItemUpdate` takes a different query depending on
//    whether the item is already there, so the caller ends up branching on
//    `errSecItemNotFound` anyway. Delete-then-add is the same two calls with no
//    branch, and it is idempotent, which is what a settings write has to be.
//
//  ─── BY HAND, ON THE DEVICE (STYLE.md § 10) ──────────────────────────────────
//  `SecItemAdd` with `kSecUseDataProtectionKeychain` needs a keychain-access
//  entitlement that a bare `xctest` process has not got; it fails there with
//  `errSecMissingEntitlement` however correct the code is. Faking that into a
//  passing test would prove nothing, so the seam below is what the tests
//  exercise and these four are checked on device instead:
//
//    1. Enter a URL and token, force-quit, relaunch → sync still works, so the
//       token survived the process.
//    2. Reboot the iPad and do not unlock it; wait for a background poll →
//       documents arrive, so `AfterFirstUnlock` is the right class.
//    3. Switch to a second server, then back → each URL keeps its own token and
//       neither is offered the other's.
//    4. Delete the app and reinstall → the token is gone; the app asks again.
//  ─────────────────────────────────────────────────────────────────────────────
//

import Foundation
import Security
import Core

/// The Keychain item that holds the relay's bearer token, one per server host.
///
/// **On failure:** reads answer nil and never throw — a missing token, a locked
/// Keychain and a corrupt item are the same answer to the caller, which is "ask
/// the user for a token again", and a throw on the sync path would be a network
/// error wearing a disguise. Writes throw `PencilLoopError.storeWriteFailed`.
struct SyncTokenKeychain: Sendable {

    /// The `kSecAttrService` every token is filed under. One service, many
    /// accounts.
    static let service = "co.pencil-loop.sync-token"

    /// The three Keychain calls this type makes, behind a seam.
    ///
    /// Everything worth getting wrong is *above* this struct — which account a
    /// URL maps to, deleting before adding, answering nil rather than throwing
    /// when there is nothing there — and all of it is unit tested against an
    /// in-memory double. What is below it is three `SecItem…` calls that cannot
    /// run in a test process at all; see the note at the top of this file.
    ///
    /// **On failure:** `read` answers nil, `delete` is silent (deleting an item
    /// that is not there is a success, not an error), and `add` returns the raw
    /// `OSStatus` so the layer above can put the number in front of the user.
    struct Items: Sendable {

        /// The stored bytes for an account, or nil when there is no item.
        var read: @Sendable (_ account: String) -> Data?

        /// Removes the item for an account. Absent is not an error.
        var delete: @Sendable (_ account: String) -> Void

        /// Adds the item, answering `errSecSuccess` or the reason it did not.
        var add: @Sendable (_ account: String, _ secret: Data) -> OSStatus
    }

    private let items: Items

    /// - Parameter items: the real Keychain by default; tests pass a double.
    init(items: Items = .live) {
        self.items = items
    }

    // MARK: - Accounts

    /// The account a server's token is filed under: the base URL's host,
    /// lowercased.
    ///
    /// **When it fails:** nil, because the string is not a URL or carries no
    /// host. The caller must *not* fall back to a shared account — that is the
    /// bug this function exists to make impossible — and should refuse to adopt
    /// the server instead.
    static func account(forBaseURLString string: String) -> String? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false,
              let components = URLComponents(string: trimmed),
              let host = components.host,
              host.isEmpty == false
        else {
            return nil
        }
        return host.lowercased()
    }

    /// The account for a host that has already been parsed out of a URL.
    ///
    /// Hosts are case-insensitive, so this lowercases; a caller that passed
    /// `Relay.Example.com` and a caller that passed `relay.example.com` must
    /// reach the same item or one of them silently sees no token.
    static func account(forHost host: String) -> String {
        host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    // MARK: - The token

    /// The token filed under `account`.
    ///
    /// **When it fails:** nil, and nil is not distinguishable from "never set"
    /// on purpose — every reason the Keychain can decline (no item, device
    /// locked, entitlement missing, bytes that are not UTF-8) has the same
    /// recovery, which is to ask for the token again. Never throws.
    func token(forAccount account: String) -> String? {
        guard let data = items.read(account), data.isEmpty == false else {
            return nil
        }
        let token = String(decoding: data, as: UTF8.self)
        return token.isEmpty ? nil : token
    }

    /// Stores `token` under `account`, replacing whatever was there. Passing
    /// nil, or an empty string, forgets the token.
    ///
    /// - Throws: `PencilLoopError.storeWriteFailed` when the Keychain refuses
    ///   the add, carrying the `OSStatus` so the number reaches the user rather
    ///   than a shrug. The delete has already happened by then, so the failure
    ///   state is "no token stored" and never "the previous server's token
    ///   stored under the new server's account".
    func setToken(_ token: String?, forAccount account: String) throws {
        items.delete(account)
        guard let token, token.isEmpty == false else {
            return
        }
        let status = items.add(account, Data(token.utf8))
        guard status == errSecSuccess else {
            throw PencilLoopError.storeWriteFailed(
                reason: "The sync token could not be saved to the Keychain (status \(status))."
            )
        }
    }
}

extension SyncTokenKeychain.Items {

    /// The real Keychain.
    ///
    /// **On failure:** every one of these three swallows the status except
    /// `add`, which returns it. That asymmetry is deliberate: a read that fails
    /// and a read that finds nothing want the same handling, and a delete that
    /// finds nothing has done its job, but a write that did not happen is the
    /// one the user has to be told about.
    static let live = SyncTokenKeychain.Items(
        read: { account in
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: SyncTokenKeychain.service,
                kSecAttrAccount as String: account,
                kSecUseDataProtectionKeychain as String: true,
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne
            ]
            var found: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &found)
            guard status == errSecSuccess else {
                return nil
            }
            return found as? Data
        },
        delete: { account in
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: SyncTokenKeychain.service,
                kSecAttrAccount as String: account,
                kSecUseDataProtectionKeychain as String: true
            ]
            // errSecItemNotFound is the ordinary case on a first write, and
            // it means the same thing to this caller as a successful delete.
            _ = SecItemDelete(query as CFDictionary)
        },
        add: { account, secret in
            let attributes: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: SyncTokenKeychain.service,
                kSecAttrAccount as String: account,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
                kSecUseDataProtectionKeychain as String: true,
                kSecValueData as String: secret
            ]
            return SecItemAdd(attributes as CFDictionary, nil)
        }
    )
}
