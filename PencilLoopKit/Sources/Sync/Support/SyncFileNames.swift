//
//  SyncFileNames.swift
//  Sync · Support
//
//  The staging convention every writer of the sync folder shares.
//
//  The file *names* inside a directory — `document.pdf`, `source.md`,
//  `sourcemap.json`, `meta.json`, `reply.md` — used to be here as well. They
//  now live in `DocumentFileNames` (Core/Contracts), because Ingest, Storage
//  and Export spell them too and a folder layout is a public contract
//  (docs/05-file-contracts.md, STYLE.md § 9). What remains here is the part
//  that is genuinely Sync's: how a directory is staged before it is renamed
//  into place, and what a scan must ignore.
//

import Foundation

/// How this module stages a directory before renaming it into place, and what
/// it ignores while scanning.
///
/// The names of the files inside a directory are in `DocumentFileNames`
/// (Core/Contracts).
///
/// **Never fails.** Everything here is a pure string operation; there is no
/// filesystem access and nothing to be unavailable.
public enum SyncFileNames {

    /// The suffix every staging directory carries.
    ///
    /// The shared convention across all four writers of this folder is that a
    /// bundle is assembled in a **hidden sibling** directory and renamed into
    /// place, and that "dot-prefixed entries are staging and must be ignored by
    /// every watcher" (integrations/README.md § Conventions).
    public static let stagingSuffix = ".tmp"

    /// `.2026-08-18-auth-refactor-plan.4F2C….tmp` — a hidden sibling of the
    /// directory being built.
    ///
    /// - Parameters:
    ///   - finalName: the name the directory will have after the rename.
    ///   - token: anything unique to this attempt; a UUID string in practice,
    ///     so two processes staging the same bundle cannot collide.
    public static func stagingName(for finalName: String, token: String) -> String {
        ".\(finalName).\(token)\(stagingSuffix)"
    }

    /// Whether a directory entry is somebody's staging, and therefore invisible
    /// to every scan in this module.
    ///
    /// Dot-prefixed rather than suffix-matched on purpose: it also skips
    /// `.DS_Store`, `.Trash`, provider bookkeeping and anything else a
    /// filesystem leaves lying about.
    public static func isHidden(_ name: String) -> Bool {
        name.hasPrefix(".")
    }
}
