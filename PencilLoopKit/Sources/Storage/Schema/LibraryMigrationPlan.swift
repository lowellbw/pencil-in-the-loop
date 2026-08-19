//
//  LibraryMigrationPlan.swift
//  Storage · Schema
//
//  One version, no stages. The scaffolding exists so that adding V2 is an
//  append to two arrays.
//

import Foundation
import SwiftData

/// How the store gets from one schema version to the next.
///
/// **Adding a version:** declare `LibrarySchemaV2`, append it to `schemas`, and
/// append a `MigrationStage` to `stages` — `.lightweight` when the change is
/// additive, `.custom` when data has to be rewritten. The order of `schemas` is
/// the upgrade order and SwiftData walks it in sequence.
public enum LibraryMigrationPlan: SchemaMigrationPlan {

    /// Oldest first.
    public static var schemas: [any VersionedSchema.Type] {
        [LibrarySchemaV1.self]
    }

    /// Empty while there is only one version. A stage per adjacent pair.
    public static var stages: [MigrationStage] {
        []
    }
}
