//
//  AppSettingsStore.swift
//  Storage · Settings
//
//  `SettingsStoring`, and with it the security-scoped bookmark for the sync
//  folder (`AppSettings.syncFolderBookmark`).
//
//  ─── WHERE THE BOOKMARK LIVES, AND WHERE IT DOES NOT ─────────────────────────
//  Storage *stores* the bookmark bytes. It does not mint them, resolve them, or
//  open a security scope: that is `FolderAccessing`, which is declared under
//  `// MARK: - Sync` in Core/Contracts/Protocols.swift and belongs to the Sync
//  unit. Storage cannot implement it anyway — `prepareFolder(at:)` has to create
//  `inbox/` and `outbox/` inside a scope only Sync opens.
//
//  So the split is: Sync mints, Storage keeps, Sync resolves on next launch.
//  ─────────────────────────────────────────────────────────────────────────────
//
//  Not SwiftData. Settings are one small value read on almost every view update
//  and written a handful of times a year; `UserDefaults` is the right size of
//  tool, it survives a store migration going wrong, and it means the folder
//  picker still works when the library store will not open — which is precisely
//  the state in which the user needs to re-pick their folder.
//

import Foundation
import os
import Core

/// Persisted user settings (docs/02-spec.md § S6).
///
/// **On failure:** `update(_:)` throws `PencilLoopError.storeWriteFailed`.
/// Reads never throw — settings that will not decode fall back to
/// `AppSettings.initial`, which lands the user on the folder picker, which is
/// the correct recovery.
public actor AppSettingsStore: SettingsStoring {

    private static let log = Logger(subsystem: "co.pencil-loop.storage", category: "settings")

    /// The `UserDefaults` key the whole settings value is stored under, as one
    /// JSON blob. One key rather than seven means a partial write is impossible.
    public static let defaultsKey = "co.pencil-loop.settings"

    /// Nil for the standard suite. Tests pass a unique name so they cannot see
    /// each other's writes.
    private let suiteName: String?

    private var stored: AppSettings

    /// - Parameter suiteName: a `UserDefaults` suite, or nil for the standard
    ///   one. Nothing is read from disk after this initialiser returns; the
    ///   value is cached and updated in step with `update(_:)`.
    public init(suiteName: String? = nil) {
        self.suiteName = suiteName
        self.stored = AppSettingsStore.load(suiteName: suiteName)
    }

    /// The current settings. Cheap; safe to read per view update.
    public var settings: AppSettings {
        stored
    }

    /// Replaces the settings and persists them.
    ///
    /// - Throws: `PencilLoopError.storeWriteFailed` when the value will not
    ///   encode. The in-memory value is left untouched in that case, so a failed
    ///   write cannot leave the app disagreeing with its own defaults.
    public func update(_ settings: AppSettings) throws {
        let data: Data
        do {
            data = try JSONEncoder().encode(settings)
        } catch {
            throw PencilLoopError.storeWriteFailed(reason: error.localizedDescription)
        }
        AppSettingsStore.defaults(suiteName: suiteName).set(data, forKey: AppSettingsStore.defaultsKey)
        stored = settings
    }

    // MARK: - Bookmark storage

    /// Stores the security-scoped bookmark Sync minted, with the folder's
    /// display name for the Settings row.
    ///
    /// Passing nil for `bookmark` forgets the folder entirely, which sends the
    /// app back to first run (`AppSettings.syncFolderBookmark` nil ⇒ S0). Every
    /// other setting is preserved.
    ///
    /// - Throws: `PencilLoopError.storeWriteFailed`, as `update(_:)` does.
    public func setSyncFolder(bookmark: Data?, displayName: String?) throws {
        var next = stored
        next.syncFolderBookmark = bookmark
        next.syncFolderDisplayName = displayName
        try update(next)
    }

    /// The stored bookmark, or nil on first run.
    ///
    /// Sync resolves it with `FolderAccessing.resolveFolder(bookmark:)`; a stale
    /// bookmark is normal, and the recovery is to mint a fresh one and call
    /// `setSyncFolder(bookmark:displayName:)` again.
    public var syncFolderBookmark: Data? {
        stored.syncFolderBookmark
    }

    /// Marks first run complete (docs/02-spec.md § S0).
    public func completeFirstRun() throws {
        guard stored.hasCompletedFirstRun == false else { return }
        var next = stored
        next.hasCompletedFirstRun = true
        try update(next)
    }

    // MARK: - Private

    private static func defaults(suiteName: String?) -> UserDefaults {
        guard let suiteName, let suite = UserDefaults(suiteName: suiteName) else {
            return UserDefaults.standard
        }
        return suite
    }

    /// Reads the persisted settings, falling back to `AppSettings.initial`.
    private static func load(suiteName: String?) -> AppSettings {
        guard let data = defaults(suiteName: suiteName).data(forKey: defaultsKey) else {
            return .initial
        }
        do {
            return try JSONDecoder().decode(AppSettings.self, from: data)
        } catch {
            log.error("Settings could not be decoded; falling back to defaults.")
            return .initial
        }
    }
}
