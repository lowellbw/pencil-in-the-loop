//
//  LibraryContainer.swift
//  Storage · Schema
//
//  The one place a `ModelContainer` is built. Two variants: the real one, in the
//  app container, and an in-memory one for tests and previews.
//

import Foundation
import SwiftData
import Core

/// Builds the SwiftData container the whole app shares.
///
/// **On failure:** throws `PencilLoopError.storeWriteFailed` with the underlying
/// reason. There is no recovery inside Storage — a container that will not open
/// is a first-run decision the app layer has to make (ask the user, or move the
/// store aside), and swallowing it here would turn a diagnosable failure into an
/// empty library.
///
/// One container per process. It is `Sendable`, and `DocumentStore` is
/// constructed from it; do not build a second one for the same URL.
public enum LibraryContainer {

    /// The schema every variant uses.
    public static var schema: Schema {
        Schema(versionedSchema: LibrarySchemaV1.self)
    }

    /// The real store, at `StorageLocations.storeURL()`.
    ///
    /// - Parameter url: overrides the location. For tests that want a real file
    ///   on disk; the app passes nothing.
    public static func make(url: URL? = nil) throws -> ModelContainer {
        let storeURL = url ?? StorageLocations.storeURL()
        // `cloudKitDatabase: .none` is load-bearing, not tidiness.
        //
        // SwiftData turns CloudKit syncing on by itself whenever the app has an
        // iCloud entitlement — and this app has one, for the default sync folder
        // in its own container (Sync/Folder/DefaultSyncFolder.swift). CloudKit
        // then demands a schema it can mirror: every attribute optional or
        // defaulted, every relationship optional, and no unique constraints.
        // This schema is none of those — `folderName` and `id` are unique on
        // purpose, because upsert is keyed on them — so the store does not open
        // *at all*, and the app shows one error instead of a library.
        //
        // The library is deliberately local. Documents are pinned into this
        // container and the folder or the relay is the transport; mirroring the
        // library through CloudKit as well would be a different application.
        let configuration = ModelConfiguration(
            schema: schema,
            url: storeURL,
            cloudKitDatabase: .none
        )
        do {
            return try ModelContainer(
                for: schema,
                migrationPlan: LibraryMigrationPlan.self,
                configurations: configuration
            )
        } catch {
            throw PencilLoopError.storeWriteFailed(reason: error.localizedDescription)
        }
    }

    /// A container that never touches the disk.
    ///
    /// Used by `StorageTests` and by SwiftUI previews. Identical schema, so a
    /// test that passes here is a test of the real schema.
    public static func inMemory() throws -> ModelContainer {
        let configuration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: true,
            cloudKitDatabase: .none
        )
        do {
            return try ModelContainer(
                for: schema,
                migrationPlan: LibraryMigrationPlan.self,
                configurations: configuration
            )
        } catch {
            throw PencilLoopError.storeWriteFailed(reason: error.localizedDescription)
        }
    }
}
