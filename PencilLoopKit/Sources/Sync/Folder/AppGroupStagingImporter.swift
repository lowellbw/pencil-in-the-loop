//
//  AppGroupStagingImporter.swift
//  Sync · Folder
//
//  ─── A LIMITATION THE SPEC DOES NOT MENTION ──────────────────────────────────
//  docs/06-integrations.md says the share extension "writes into the same
//  inbox/ via the App Group and file coordination". It cannot. A
//  security-scoped bookmark is scoped to the process that minted it: the
//  extension is a different process, it never ran the folder picker, and
//  resolving the app's bookmark from inside it does not open the scope.
//
//  So the extension writes where it certainly can — the shared App Group
//  container, under `staging/` — and the app moves those directories into the
//  real `inbox/` the next time it is in the foreground, holding its own scope.
//  The user sees a document arrive a moment after switching apps, which is when
//  they were going to look at it anyway.
//
//  This unit owns the app half. The extension half is U11's; the contract
//  between them is this directory layout and nothing else:
//
//      <App Group>/staging/
//        └─ 2026-08-18-attention-is-all-you-need/
//           ├─ document.pdf
//           └─ meta.json                     (origin.kind = "share")
//
//  A dot-prefixed entry is still being written and is skipped, exactly as
//  everywhere else in this folder format (integrations/README.md
//  § Conventions).
//  ─────────────────────────────────────────────────────────────────────────────
//

import Foundation
import Core

/// Moves what the share extension staged into the real `inbox/`.
///
/// **On failure:** throws `.folderUnavailable(reason:)` when the staging
/// container cannot be reached, and returns the names it did manage to import
/// otherwise. One directory that will not copy is logged and skipped — a
/// failed import must not strand the ones behind it, and the source is left in
/// place so the next foreground tries again.
public struct AppGroupStagingImporter: Sendable {

    /// The App Group in `PencilLoop.entitlements` and
    /// `ReviewShareExtension.entitlements`.
    public static let defaultAppGroupIdentifier = "group.com.lowellweisbord.pencilloop"

    /// The directory the extension writes into.
    public static let stagingDirectoryName = "staging"

    /// Which App Group container to look in.
    public let appGroupIdentifier: String

    /// Overrides the container lookup. Tests pass a temp directory; the app
    /// passes nothing.
    public let overrideStagingURL: URL?

    public init(
        appGroupIdentifier: String = AppGroupStagingImporter.defaultAppGroupIdentifier,
        stagingURL: URL? = nil
    ) {
        self.appGroupIdentifier = appGroupIdentifier
        self.overrideStagingURL = stagingURL
    }

    /// `<App Group>/staging`, or the override. Nil when this build has no
    /// access to the group, which is survivable: it means the share extension
    /// path is unavailable and nothing else.
    public var stagingURL: URL? {
        if let overrideStagingURL { return overrideStagingURL }
        let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
        )
        return container?.appendingPathComponent(
            AppGroupStagingImporter.stagingDirectoryName,
            isDirectory: true
        )
    }

    /// What is waiting to be imported, in name order. Empty when the container
    /// is unavailable — never an error.
    public func pendingNames() -> [String] {
        guard let stagingURL else { return [] }
        let manager = FileManager.default
        guard let entries = try? manager.contentsOfDirectory(
            at: stagingURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        return entries
            .map { $0.lastPathComponent }
            .filter { SyncFileNames.isHidden($0) == false }
            .sorted()
    }

    /// Moves everything staged into `inbox/`, atomically, one directory at a
    /// time.
    ///
    /// - Parameter folder: the sync root. The caller must already hold access.
    /// - Returns: the inbox folder names that now exist, which may differ from
    ///   the staged names when a name was already taken — `Slug.disambiguated`
    ///   decides, so two papers shared the same day do not overwrite each
    ///   other.
    @discardableResult
    public func importAll(into folder: SyncFolder) -> [String] {
        guard let stagingURL else { return [] }
        let manager = FileManager.default
        guard let entries = try? manager.contentsOfDirectory(
            at: stagingURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var existing = InboxScanner.folderNames(in: folder)
        var imported: [String] = []

        for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let name = entry.lastPathComponent
            if SyncFileNames.isHidden(name) { continue }
            do {
                let landed = try importOne(at: entry, into: folder, avoiding: existing)
                existing.insert(landed)
                imported.append(landed)
                try? manager.removeItem(at: entry)
            } catch {
                SyncLog.folder.error("Could not import \(name) from the share extension: \(error.localizedDescription)")
            }
        }
        if imported.isEmpty == false {
            SyncLog.folder.info("Imported \(imported.count) shared item(s) into the inbox.")
        }
        return imported
    }

    // MARK: - Internals

    /// One staged entry becomes one inbox directory.
    ///
    /// A staged *directory* is copied as it is. A staged *file* — a bare PDF or
    /// markdown, which is what an extension writing in a hurry produces — is
    /// wrapped into the standard layout with a minimal `meta.json` carrying
    /// `origin.kind = "share"`, because a document that ingests is worth more
    /// than a purist's error.
    private func importOne(at source: URL, into folder: SyncFolder, avoiding existing: Set<String>) throws -> String {
        let manager = FileManager.default
        let values = try? source.resourceValues(forKeys: [.isDirectoryKey, .contentModificationDateKey])
        let isDirectory = values?.isDirectory == true
        let created = values?.contentModificationDate ?? Date()

        let preferredName = isDirectory
            ? source.lastPathComponent
            : Slug.folderName(date: created, title: source.deletingPathExtension().lastPathComponent)
        let landedName = Slug.disambiguated(preferredName, existing: existing)

        let staging = folder.inboxURL.appendingPathComponent(
            SyncFileNames.stagingName(for: landedName, token: UUID().uuidString),
            isDirectory: true
        )
        let destination = folder.inboxURL.appendingPathComponent(landedName, isDirectory: true)

        do {
            if isDirectory {
                try manager.copyItem(at: source, to: staging)
            } else {
                try manager.createDirectory(at: staging, withIntermediateDirectories: true)
                let fileName = AppGroupStagingImporter.inboxFileName(for: source)
                try manager.copyItem(at: source, to: staging.appendingPathComponent(fileName, isDirectory: false))
            }

            let metaURL = staging.appendingPathComponent(DocumentFileNames.metadata, isDirectory: false)
            if manager.fileExists(atPath: metaURL.path) == false {
                let metadata = DocumentMetadata(
                    id: UUID().uuidString,
                    title: MetadataFile.fallbackTitle(forDirectoryNamed: landedName),
                    createdAt: created,
                    origin: Origin(kind: .share),
                    sourceFormat: AppGroupStagingImporter.sourceFormat(for: source, isDirectory: isDirectory)
                )
                try MetadataFile.encode(metadata).write(to: metaURL, options: [.atomic])
            }

            try CoordinatedFileAccess.move(from: staging, to: destination) { movableSource, replaceableDestination in
                if manager.fileExists(atPath: replaceableDestination.path) {
                    _ = try manager.replaceItemAt(replaceableDestination, withItemAt: movableSource)
                    return
                }
                try manager.moveItem(at: movableSource, to: replaceableDestination)
            }
        } catch {
            try? manager.removeItem(at: staging)
            throw error
        }
        return landedName
    }

    /// What a bare staged file should be called inside its new directory.
    static func inboxFileName(for source: URL) -> String {
        let suffix = source.pathExtension.lowercased()
        if suffix == "md" || suffix == "markdown" || suffix == "txt" {
            return DocumentFileNames.sourceMarkdown
        }
        return DocumentFileNames.document
    }

    /// The `sourceFormat` recorded for a staged item that arrived without a
    /// `meta.json`.
    static func sourceFormat(for source: URL, isDirectory: Bool) -> SourceFormat {
        if isDirectory { return .unknown }
        let suffix = source.pathExtension.lowercased()
        if suffix == "md" || suffix == "markdown" { return .markdown }
        if suffix == "txt" { return .text }
        if suffix == "pdf" { return .pdf }
        return .unknown
    }
}
