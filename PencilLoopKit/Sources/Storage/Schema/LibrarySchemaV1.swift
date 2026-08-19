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
/// property means a new `VersionedSchema` (`LibrarySchemaV2`) and a stage in
/// `LibraryMigrationPlan`.
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
