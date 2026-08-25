//
//  RelayStagingUploader.swift
//  Sync · HTTP
//
//  The share extension's hand-off, for the relay transport.
//
//  ─── WHY THIS FILE EXISTS ────────────────────────────────────────────────────
//  The share extension cannot write into the sync folder. A security-scoped
//  bookmark belongs to the process that minted it, and the extension never ran
//  the picker, so it writes into the App Group container under `staging/`
//  instead (`ShareStagingWriter`). Something in the *app* has to pick those up.
//
//  Exactly one thing did: `SyncCoordinator.scanOnce()`, the folder coordinator.
//  `HTTPSyncCoordinator` had no equivalent, so on the relay transport a shared
//  PDF landed in staging and stayed there — no error, no row, no trace. It only
//  ever worked because the folder transport happened to be the default. Making
//  the relay the default without this would have traded one silent drop for
//  another.
//
//  ─── WHY IT IMPORTS LOCALLY FIRST ────────────────────────────────────────────
//  Turning a staged entry into a bundle is not trivial — a bare PDF has to be
//  wrapped in the standard layout with a minimal `meta.json`, names have to be
//  disambiguated — and `AppGroupStagingImporter` already does all of it,
//  correctly, against a `SyncFolder`. So this gives it one: a private inbox
//  inside the app container, which it then uploads from and empties.
//
//  That local inbox is **durable, not temporary**, and that is the whole design.
//  `importAll` deletes the staged entry once it has landed locally, so if the
//  upload then failed against a temporary directory the document would be gone —
//  a shared file destroyed by a flaky network. Keeping it means a failed upload
//  simply leaves it here for the next poll to retry.
//

import Foundation
import Core

/// Moves anything the share extension staged up to the relay.
///
/// **On failure:** never throws to the caller. A document that cannot be
/// uploaded stays in the local inbox and is retried on the next poll, and the
/// reason is logged. Sharing something must not be able to break the poll loop
/// that also delivers everything else.
public struct RelayStagingUploader: Sendable {

    private let client: SyncServerClient
    private let importer: AppGroupStagingImporter
    private let localRootURL: URL

    /// - Parameters:
    ///   - client: the relay this device is on.
    ///   - importer: the App Group reader. Injectable so a test can point it at
    ///     a directory instead of a real App Group, which no test has.
    ///   - localRootURL: where bundles wait between being imported and being
    ///     uploaded. Defaults to a private directory in the app container.
    public init(
        client: SyncServerClient,
        importer: AppGroupStagingImporter = AppGroupStagingImporter(),
        localRootURL: URL = RelayStagingUploader.defaultRootURL()
    ) {
        self.client = client
        self.importer = importer
        self.localRootURL = localRootURL
    }

    /// Where shared items wait to go up.
    ///
    /// Inside the app container, so it is backed up with everything else and
    /// never visible to the user as a folder they might tidy away.
    public static func defaultRootURL() -> URL {
        DocumentContainer.containerRoot()
            .appendingPathComponent("share-staging-server", isDirectory: true)
    }

    /// Imports whatever is staged, then uploads everything waiting.
    ///
    /// Both halves run every time, not just when something new was staged: the
    /// second half is also the retry for anything a previous pass could not
    /// send.
    ///
    /// - Returns: the folder names the relay accepted this pass.
    @discardableResult
    public func importAndUpload() async -> [String] {
        guard let folder = try? makeLocalFolder() else { return [] }

        // Empties the App Group. Anything it returns is now on disk here, and
        // is this method's responsibility from now on.
        importer.importAll(into: folder)

        let manager = FileManager.default
        guard let waiting = try? manager.contentsOfDirectory(
            at: folder.inboxURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var uploaded: [String] = []
        for directory in waiting.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let name = directory.lastPathComponent
            if SyncFileNames.isHidden(name) { continue }
            do {
                try await upload(directory)
                try? manager.removeItem(at: directory)
                uploaded.append(name)
            } catch {
                SyncLog.coordinator.error(
                    "Could not send the shared item \(name) to the relay; it stays queued. \(error.localizedDescription)"
                )
            }
        }
        if uploaded.isEmpty == false {
            SyncLog.coordinator.info("Sent \(uploaded.count) shared item(s) to the relay.")
        }
        return uploaded
    }

    // MARK: - Internals

    /// The private inbox, created if it is not there yet.
    ///
    /// `SyncFolder(rootURL:)` derives the layout, so `inbox`/`outbox` stay
    /// spelled in exactly one place (DTOs.swift § SyncFolder).
    private func makeLocalFolder() throws -> SyncFolder {
        let folder = SyncFolder(rootURL: localRootURL)
        try FileManager.default.createDirectory(
            at: folder.inboxURL,
            withIntermediateDirectories: true
        )
        return folder
    }

    /// One bundle: declare it, then upload every file the relay says it wants.
    ///
    /// Declaring is idempotent on `documentId`, so a pass that uploaded some
    /// files and then lost the network re-declares to the same folder rather
    /// than making a duplicate (`POST /v1/documents` § existing).
    private func upload(_ directory: URL) async throws {
        let manager = FileManager.default
        let meta = MetadataFile.read(at: directory.appendingPathComponent(DocumentFileNames.metadata))

        let markdownURL = directory.appendingPathComponent(DocumentFileNames.sourceMarkdown)
        let markdown = try? String(contentsOf: markdownURL, encoding: .utf8)

        // Every file that is not one the relay writes itself. `meta.json` and
        // `source.md` are rebuilt server-side from the declaration, so
        // declaring them changes nothing and uploading them is refused.
        let names = (try? manager.contentsOfDirectory(atPath: directory.path)) ?? []
        let payloads: [(name: String, data: Data)] = names
            .filter { $0 != DocumentFileNames.metadata && $0 != DocumentFileNames.sourceMarkdown }
            .filter { SyncFileNames.isHidden($0) == false }
            .sorted()
            .compactMap { name in
                guard let data = try? Data(contentsOf: directory.appendingPathComponent(name)) else {
                    return nil
                }
                return (name, data)
            }

        var declaration: [String: Any] = [
            "expectedFiles": payloads.map { ["name": $0.name, "bytes": $0.data.count] }
        ]
        if let title = meta.title, title.isEmpty == false {
            declaration["title"] = title
        }
        // The two shapes the relay accepts. Markdown carries its own content;
        // a shared PDF has none, and says so, or it would be rejected as an
        // empty document rather than accepted as a PDF.
        if let markdown, markdown.isEmpty == false {
            declaration["content"] = markdown
        } else {
            declaration["sourceFormat"] = "pdf"
        }
        if let kind = meta.origin?.kind.rawValue {
            declaration["originKind"] = kind
        }

        let body = try JSONSerialization.data(withJSONObject: declaration)
        let response = try await client.post(body, to: "/v1/documents")
        guard let object = try JSONSerialization.jsonObject(with: response) as? [String: Any],
              let folderName = object["folderName"] as? String else {
            throw PencilLoopError.outboxWriteFailed(
                reason: "The relay accepted the shared item but did not say where it put it."
            )
        }

        for payload in payloads {
            _ = try await client.put(
                payload.data,
                to: "/v1/documents/\(folderName)/files/\(payload.name)",
                contentType: RelayStagingUploader.contentType(for: payload.name)
            )
        }
    }

    /// Enough of a guess for the files a share can produce.
    static func contentType(for name: String) -> String {
        if name.hasSuffix(".pdf") { return "application/pdf" }
        if name.hasSuffix(".json") { return "application/json" }
        if name.hasSuffix(".md") { return "text/markdown" }
        if name.hasSuffix(".png") { return "image/png" }
        return "application/octet-stream"
    }
}
