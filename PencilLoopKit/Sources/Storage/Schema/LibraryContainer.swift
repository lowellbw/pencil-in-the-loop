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
        let configuration = ModelConfiguration(schema: schema, url: storeURL)
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
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
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
