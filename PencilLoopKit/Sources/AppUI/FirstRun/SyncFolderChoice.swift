//
//  SyncFolderChoice.swift
//  AppUI · FirstRun
//
//  Adopting a folder the user picked, in one place. First run does it (S0) and
//  Settings does it again when the folder changes (S6); doing it twice in two
//  files is how two screens end up persisting two different things.
//

import Foundation
import Core

/// Turns a `fileImporter` URL into a prepared `SyncFolder` and the settings
/// that remember it.
///
/// **On failure:** throws whatever `FolderAccessing.prepareFolder(at:)` threw —
/// `.accessDenied` when the scope will not open, `.folderUnavailable` when
/// `inbox/` and `outbox/` cannot be created — or
/// `PencilLoopError.storeWriteFailed` when the settings could not be written.
/// Nothing is persisted unless the folder was prepared, so a failed attempt
/// leaves the previous folder in place.
public enum SyncFolderChoice {

    /// Prepares the folder, mints the bookmark, and persists both it and the
    /// display name (docs/02-spec.md § S0).
    ///
    /// `nonisolated` so the directory creation and the bookmark minting happen
    /// off the main actor; the caller is a view and resumes on it.
    ///
    /// - Parameter url: exactly what the picker returned, unnormalised — a
    ///   bookmark minted from a rewritten URL may not resolve.
    /// - Returns: the prepared folder, for a caller that wants to start syncing
    ///   it immediately.
    public nonisolated static func adopt(
        _ url: URL,
        folderAccess: any FolderAccessing,
        settings: any SettingsStoring
    ) async throws -> SyncFolder {
        let folder = try folderAccess.prepareFolder(at: url)
        var updated = await settings.settings
        updated.syncFolderBookmark = folder.bookmark
        updated.syncFolderDisplayName = folder.displayName
        updated.hasCompletedFirstRun = true
        try await settings.update(updated)
        return folder
    }

    /// One line a person can read, for a status row or an inline message.
    ///
    /// `PencilLoopError` carries display text on every case, which is why the
    /// UI never has to compose an error string of its own
    /// (Core/Contracts/PencilLoopError.swift).
    public nonisolated static func describe(_ error: any Error) -> String {
        if let known = error as? PencilLoopError {
            return known.message
        }
        return error.localizedDescription
    }
}
