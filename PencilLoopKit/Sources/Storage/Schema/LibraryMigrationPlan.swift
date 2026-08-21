//
//  LibraryMigrationPlan.swift
//  Storage · Schema
//
//  One version, no stages — still, because nothing has shipped and V1 is
//  therefore still editable (`LibrarySchemaV1`).
//
//  ─── READ THIS BEFORE ADDING V2 ──────────────────────────────────────────────
//  This file used to promise that adding a version was "an append to two
//  arrays". It is not, and the shortcut fails at launch rather than at compile
//  time. Adding `Document.pinnedAt` was tried that way first and the app died in
//  `LibraryContainer.make()` with:
//
//      NSInvalidArgumentException: Duplicate version checksums detected.
//
//  The reason: a `VersionedSchema`'s `models` array names Swift types, and there
//  is only ever one `Document` class in this module. So `LibrarySchemaV1.models`
//  and `LibrarySchemaV2.models` both resolve to the *current* `Document` —
//  identical types, identical checksums, and Core Data refuses a lightweight
//  stage between two versions it cannot tell apart.
//
//  A real V2 therefore costs what the scaffolding was meant to avoid: each
//  version needs its own frozen copy of every model it names, nested inside the
//  version enum (`LibrarySchemaV1.Document`, `LibrarySchemaV2.Document`, …),
//  with `typealias Document = LibrarySchemaVN.Document` keeping the rest of
//  Storage spelling it the short way. That is three model classes duplicated per
//  version, and it is the price of migrating a store that holds somebody's
//  annotations.
//
//  Until a build ships, it is a price worth not paying: edit V1 instead.
//  ─────────────────────────────────────────────────────────────────────────────
//

import Foundation
import SwiftData

/// How the store gets from one schema version to the next.
///
/// **Adding a version, properly:** copy every model into the new version enum
/// as nested types, declare `LibrarySchemaVN`, append it to `schemas`, append a
/// `MigrationStage` to `stages` — `.lightweight` when the change is additive,
/// `.custom` when data has to be rewritten — and point `LibraryContainer.schema`
/// at it. The order of `schemas` is the upgrade order and SwiftData walks it in
/// sequence. See the file header for the failure mode when the models are not
/// copied.
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
