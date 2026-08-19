//
//  PreviewFolderAccess.swift
//  AppUI · FirstRun
//
//  The folder access `PreviewEnvironment` does not carry. Same idea as the
//  stubs in AppUI/Support/AppEnvironment.swift: it never touches the disk, never
//  fails, and exists so the first-run and Settings screens can be previewed on a
//  Mac with no folder and no device.
//

import Foundation
import Core

/// A `FolderAccessing` that agrees to everything and does nothing.
///
/// **On failure:** it has no failure mode. `prepareFolder(at:)` returns the URL
/// it was given with an empty bookmark, which is enough for a preview to walk
/// through S0; the two resolving calls return a fixed folder; `withAccess`
/// simply runs the body.
public struct PreviewFolderAccess: FolderAccessing {

    public init() {}

    public nonisolated func prepareFolder(at url: URL) throws -> SyncFolder {
        SyncFolder(rootURL: url, bookmark: Data())
    }

    public nonisolated func resolveFolder(bookmark: Data) throws -> SyncFolder {
        PreviewFolderAccess.folder(bookmark: bookmark)
    }

    public nonisolated func refreshedFolder(bookmark: Data) throws -> SyncFolder {
        PreviewFolderAccess.folder(bookmark: bookmark)
    }

    public nonisolated func withAccess<T: Sendable>(
        to folder: SyncFolder,
        perform body: @Sendable (SyncFolder) throws -> T
    ) throws -> T {
        try body(folder)
    }

    public nonisolated func withAccess<T: Sendable>(
        to folder: SyncFolder,
        perform body: @Sendable (SyncFolder) async throws -> T
    ) async throws -> T {
        try await body(folder)
    }

    /// True, because a preview's folder is imaginary and always there.
    public nonisolated func isReachable(_ folder: SyncFolder) -> Bool {
        true
    }

    private nonisolated static func folder(bookmark: Data) -> SyncFolder {
        SyncFolder(
            rootURL: URL(fileURLWithPath: "/PencilLoop", isDirectory: true),
            bookmark: bookmark
        )
    }
}
