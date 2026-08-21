//
//  LibrarySchemaV1.swift
//  Storage · Schema
//
//  Version 1 of the library schema, named so that version 2 is an addition
//  rather than a rewrite. A `VersionedSchema` costs three lines today; retrofitting
//  one after the first shipped build costs a lightweight-migration failure on a
//  device holding the only copy of somebody's annotations.
//

import Foundation
import SwiftData

/// The models as they stand in the first shipping build.
///
/// **Adding to this is not allowed once a build has shipped.** A new or renamed
/// property then means a new `VersionedSchema` and a stage in
/// `LibraryMigrationPlan` — and read that file's header first, because a new
/// version costs more than it looks like it costs.
///
/// Nothing has shipped, so `Document.pinnedAt` was added here rather than in a
/// V2. That is the rule above being followed, not bent: the whole point of the
/// "once a build has shipped" clause is that there is no store on anyone's
/// device holding data this schema would have to migrate.
public enum LibrarySchemaV1: VersionedSchema {

    /// 1.0.0. Bumped by the *next* schema, never by edits to this one.
    public static var versionIdentifier: Schema.Version {
        Schema.Version(1, 0, 0)
    }

    /// Every persisted type. Order is not significant.
    public static var models: [any PersistentModel.Type] {
        [Document.self, Page.self, Comment.self]
    }
}
