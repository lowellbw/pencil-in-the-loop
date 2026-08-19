//
//  StagingSweeper.swift
//  Sync · Support
//
//  Every writer in this module assembles a directory in a hidden `.tmp` sibling
//  and renames it into place (integrations/README.md § Conventions). The rename
//  is what makes the write atomic; the sibling is what is left behind when the
//  process dies between the two.
//
//  Nothing else removes those siblings. Every scan in this module skips hidden
//  entries by design, so a crash mid-pin leaves a full copy of a document inside
//  the app's documents root for ever — invisible to the library, counted in the
//  Settings storage row (`DocumentStore.storageBytes()`) — and a crash mid-write
//  leaves one in the user's own `inbox/`, which is somebody else's folder.
//
//  So each writer sweeps its own root before it stages. The age cut-off is what
//  makes that safe: an entry younger than `minimumAge` may belong to a write
//  happening right now, here or in the share extension.
//

import Foundation

/// Removes staging directories that were abandoned by a process that died.
///
/// **Never fails and never throws.** A root that cannot be listed, an entry
/// whose age cannot be read and an entry that will not delete are all skipped:
/// this is housekeeping, and housekeeping that can fail a write would be worse
/// than the debris it removes.
public enum StagingSweeper {

    /// How old an entry must be before it is assumed abandoned.
    ///
    /// One hour: far longer than any write this app performs, and far shorter
    /// than "until the user reinstalls".
    public static let minimumAge: TimeInterval = 3600

    /// Removes every abandoned staging directory directly inside `root`.
    ///
    /// - Parameters:
    ///   - root: the directory staging siblings are created in — the documents
    ///     root for the pinner, `inbox/` for the coordinator, the queue root
    ///     for the queue.
    ///   - minimumAge: how old an entry must be to count as abandoned.
    ///   - now: the clock, so a test does not have to wait an hour.
    /// - Returns: how many entries were removed. Zero is the normal answer, and
    ///   the only one on a device that has never crashed mid-write.
    @discardableResult
    public static func sweep(
        in root: URL,
        olderThan minimumAge: TimeInterval = StagingSweeper.minimumAge,
        now: Date = Date()
    ) -> Int {
        let manager = FileManager.default
        guard let entries = try? manager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey, .creationDateKey],
            options: []
        ) else {
            return 0
        }

        var removed = 0
        for entry in entries {
            guard isStaging(entry.lastPathComponent) else { continue }
            guard let age = age(of: entry, now: now), age >= minimumAge else { continue }
            do {
                try manager.removeItem(at: entry)
                removed += 1
            } catch {
                SyncLog.folder.notice(
                    "Left \(entry.lastPathComponent) in place: \(error.localizedDescription)"
                )
            }
        }
        if removed > 0 {
            SyncLog.folder.info("Swept \(removed) abandoned staging director(ies) from \(root.lastPathComponent).")
        }
        return removed
    }

    /// Whether a name is one of this module's staging directories: hidden, and
    /// carrying `SyncFileNames.stagingSuffix`.
    ///
    /// Both halves matter. Hidden alone would match `.DS_Store` and a provider's
    /// own bookkeeping, and this type deletes what it matches.
    public static func isStaging(_ name: String) -> Bool {
        SyncFileNames.isHidden(name) && name.hasSuffix(SyncFileNames.stagingSuffix)
    }

    /// How long ago an entry was last written.
    ///
    /// - Returns: nil when the filesystem reports no date at all, which is
    ///   treated as "leave it alone" rather than "delete it" — an entry we know
    ///   nothing about might be a write in flight.
    private static func age(of url: URL, now: Date) -> TimeInterval? {
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .creationDateKey])
        guard let stamp = values?.contentModificationDate ?? values?.creationDate else { return nil }
        return now.timeIntervalSince(stamp)
    }
}
