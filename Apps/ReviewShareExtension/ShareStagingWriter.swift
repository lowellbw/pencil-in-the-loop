//
//  ShareStagingWriter.swift
//  ReviewShareExtension
//
//  The extension half of the contract described in
//  Sync/Folder/AppGroupStagingImporter.swift.
//
//  The extension cannot write into the user's sync folder: a security-scoped
//  bookmark is scoped to the process that minted it and this process never ran
//  the folder picker (docs/06-integrations.md § Share extension). So it writes
//  into the shared App Group container, under `staging/`, laid out exactly like
//  an inbox directory, and the app moves it across on next foreground:
//
//      <App Group>/staging/
//        ├─ .2026-08-18-attention-is-all-you-need.<uuid>.tmp/   being written
//        └─ 2026-08-18-attention-is-all-you-need/               finished
//           ├─ document.pdf
//           └─ meta.json                     (origin.kind = "share")
//
//  Directories are built in the hidden `.tmp` sibling and renamed into place.
//  The importer skips dot-prefixed entries, so a half-written directory is
//  invisible to it, and a rename within one volume is atomic — the importer
//  never sees a partial item. That is the same convention every other writer of
//  this folder format uses (SyncFileNames, integrations/README.md
//  § Conventions).
//
//  No network. An extension is killed without ceremony and has a hard memory
//  cap, so the only work here is a `copyItem` — which the filesystem streams —
//  and two files of a few hundred bytes.
//

import Foundation
import Core
import Sync
import os

/// Writes one shared item into `<App Group>/staging/` as a finished inbox
/// directory.
///
/// **On failure:** throws `PencilLoopError.folderUnavailable` when the App
/// Group container cannot be reached, and whatever `FileManager` threw
/// otherwise. In every failure case the half-built `.tmp` directory is removed
/// before the error propagates, so nothing partial is left behind for the
/// importer to find.
struct ShareStagingWriter: Sendable {

    /// What kind of file is being staged, and therefore what it is called
    /// inside the directory.
    ///
    /// A closed set, so that "a format with no file name" cannot be
    /// constructed. `SourceFormat.html` is not here: a link has no file to
    /// copy and goes through `stageWebPage(_:title:)` instead.
    enum Payload: Sendable {
        case pdf
        case markdown
        case plainText

        /// The name this payload takes inside the directory
        /// (`DocumentFileNames`).
        var fileName: String {
            switch self {
            case .pdf: return DocumentFileNames.document
            case .markdown, .plainText: return DocumentFileNames.sourceMarkdown
            }
        }

        /// What `meta.json` records as `sourceFormat`.
        var sourceFormat: SourceFormat {
            switch self {
            case .pdf: return .pdf
            case .markdown: return .markdown
            case .plainText: return .text
            }
        }

        /// The payload a filename extension implies.
        ///
        /// - Returns: nil for anything this extension does not read, which the
        ///   caller reports as an unsupported item rather than guessing.
        static func matching(fileExtension: String) -> Payload? {
            switch fileExtension.lowercased() {
            case "pdf": return .pdf
            case "md", "markdown": return .markdown
            case "txt", "text": return .plainText
            default: return nil
            }
        }
    }

    /// The App Group both processes share. Taken from Sync rather than spelled
    /// again: `ReviewShareExtension.entitlements` and `PencilLoop.entitlements`
    /// carry the same string, and a second copy in Swift is how they drift.
    let appGroupIdentifier: String

    init(appGroupIdentifier: String = AppGroupStagingImporter.defaultAppGroupIdentifier) {
        self.appGroupIdentifier = appGroupIdentifier
    }

    /// How long a `.tmp` directory is left before it is treated as the debris
    /// of a killed extension and removed. Generous: a slow copy over a file
    /// provider is not abandonment.
    static let abandonedStagingAge: TimeInterval = 60 * 60

    /// `<App Group>/staging`, or nil when this build has no access to the
    /// group. Nil is the one failure the user can act on, so it is reported
    /// rather than logged.
    var stagingURL: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier)?
            .appendingPathComponent(AppGroupStagingImporter.stagingDirectoryName, isDirectory: true)
    }

    // MARK: - Staging

    /// Copies a shared file into a new staged directory.
    ///
    /// - Parameters:
    ///   - source: a file the caller can read for the duration of this call —
    ///     an `NSItemProvider` temporary copy, or a security-scoped URL with
    ///     its scope already open. The copy happens before this returns.
    ///   - title: what `meta.json` records. Not the folder name; `Slug` makes
    ///     that.
    /// - Returns: the folder name that landed in `staging/`.
    /// - Throws: `PencilLoopError.folderUnavailable`, or a `FileManager` error.
    @discardableResult
    func stageDocument(copying source: URL, title: String, as payload: Payload) throws -> String {
        try stage(title: title, sourceFormat: payload.sourceFormat) { directory in
            try FileManager.default.copyItem(
                at: source,
                to: directory.appendingPathComponent(payload.fileName, isDirectory: false)
            )
        }
    }

    /// Stages a shared link without touching the network.
    ///
    /// The directory holds a `source.md` standing in for the page — a heading,
    /// the link, and a sentence saying it has not been fetched — and the address
    /// itself goes into `meta.json` as `sourceURL`, for the app to fetch from
    /// later. That field is where it belongs: it used to be a `source.url` file
    /// named by a private constant in this file, which is a format nothing else
    /// in the repo had a name for (Core/Contracts/DocumentMetadata.swift).
    ///
    /// The markdown is what makes this ingestible today: `InboxScanner.item(at:)`
    /// returns nil for a directory with neither `document.pdf` nor `source.md`,
    /// so a link saved as metadata alone would be invisible and lost.
    ///
    /// - Returns: the folder name that landed in `staging/`.
    /// - Throws: as `stageDocument(copying:title:as:)`.
    @discardableResult
    func stageWebPage(_ address: URL, title: String) throws -> String {
        try stage(title: title, sourceFormat: .html, sourceURL: address) { directory in
            let markdown = Data(ShareStagingWriter.placeholderMarkdown(
                title: title,
                address: address,
                savedAt: Date()
            ).utf8)
            try markdown.write(
                to: directory.appendingPathComponent(DocumentFileNames.sourceMarkdown, isDirectory: false),
                options: [.atomic]
            )
        }
    }

    // MARK: - Internals

    /// Builds one directory in a hidden sibling and renames it into place.
    ///
    /// `populate` writes the document files; `meta.json` is written last,
    /// before the rename, so the finished directory is complete the instant it
    /// becomes visible.
    private func stage(
        title: String,
        sourceFormat: SourceFormat,
        sourceURL: URL? = nil,
        populate: (URL) throws -> Void
    ) throws -> String {
        let manager = FileManager.default
        guard let root = stagingURL else {
            throw PencilLoopError.folderUnavailable(
                reason: "The share extension cannot reach the shared \(appGroupIdentifier) container."
            )
        }
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        sweepAbandonedStaging(in: root)

        let created = Date()
        let preferredName = Slug.folderName(date: created, title: title)
        let temporary = root.appendingPathComponent(
            SyncFileNames.stagingName(for: preferredName, token: UUID().uuidString),
            isDirectory: true
        )
        try manager.createDirectory(at: temporary, withIntermediateDirectories: true)

        do {
            try populate(temporary)
            let metadata = DocumentMetadata(
                id: UUID().uuidString,
                title: title,
                createdAt: created,
                origin: Origin(kind: .share),
                sourceFormat: sourceFormat,
                sourceURL: sourceURL
            )
            try MetadataFile.encode(metadata).write(
                to: temporary.appendingPathComponent(DocumentFileNames.metadata, isDirectory: false),
                options: [.atomic]
            )
            let landed = try moveIntoPlace(temporary, preferredName: preferredName, in: root)
            SyncLog.folder.info("Staged a shared item as \(landed, privacy: .public) for the next foreground import.")
            return landed
        } catch {
            try? manager.removeItem(at: temporary)
            throw error
        }
    }

    /// Renames the staged directory to its final name, disambiguating against
    /// whatever is already waiting.
    ///
    /// The app disambiguates again when it moves these into `inbox/`; this pass
    /// only stops two things shared before the next foreground from colliding
    /// with each other. The listing is re-read on each attempt because another
    /// invocation of this extension may have landed in between.
    private func moveIntoPlace(_ temporary: URL, preferredName: String, in root: URL) throws -> String {
        let manager = FileManager.default
        var lastError: (any Error)?
        for _ in 0..<3 {
            let taken = Set((try? manager.contentsOfDirectory(atPath: root.path)) ?? [])
            let landed = Slug.disambiguated(preferredName, existing: taken)
            do {
                try manager.moveItem(at: temporary, to: root.appendingPathComponent(landed, isDirectory: true))
                return landed
            } catch {
                lastError = error
            }
        }
        if let lastError { throw lastError }
        throw PencilLoopError.folderUnavailable(
            reason: "The staged document could not be renamed into \(AppGroupStagingImporter.stagingDirectoryName)."
        )
    }

    /// Removes `.tmp` directories left by an extension that was killed
    /// mid-write.
    ///
    /// They are invisible to the importer, which is what makes them safe — and
    /// also what would let them accumulate unnoticed. Best effort throughout: a
    /// sweep that fails must not stop the share that triggered it.
    private func sweepAbandonedStaging(in root: URL) {
        let manager = FileManager.default
        guard let entries = try? manager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: []
        ) else {
            return
        }
        let cutoff = Date().addingTimeInterval(-ShareStagingWriter.abandonedStagingAge)
        for entry in entries {
            let name = entry.lastPathComponent
            guard SyncFileNames.isHidden(name), name.hasSuffix(SyncFileNames.stagingSuffix) else { continue }
            let modified = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            guard let modified, modified < cutoff else { continue }
            try? manager.removeItem(at: entry)
            SyncLog.folder.notice("Removed an abandoned share-extension staging directory.")
        }
    }

    /// The `source.md` written for a shared link.
    ///
    /// Deliberately honest: it says the page was not fetched, so a user who
    /// opens it before the app has done anything is not left wondering why the
    /// paper is missing.
    static func placeholderMarkdown(title: String, address: URL, savedAt: Date) -> String {
        let heading = title
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let when = savedAt.formatted(date: .long, time: .shortened)
        return """
        # \(heading.isEmpty ? "Shared link" : heading)

        <\(address.absoluteString)>

        Saved from the share sheet on \(when). The page itself has not been fetched — \
        the share extension does no network work — so this stands in for the link above \
        until it is rendered.

        """
    }
}
