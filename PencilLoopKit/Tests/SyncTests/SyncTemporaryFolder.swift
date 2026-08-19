//
//  SyncTemporaryFolder.swift
//  SyncTests
//
//  A sync folder in a temp directory, plus the small amount of file writing
//  every test in this target needs.
//
//  Everything here is a real folder on a real filesystem. Nothing in this
//  target touches iCloud, a file provider or the App Group — the point of the
//  tests is the logic around materialisation, not materialisation itself, and a
//  test that needs a provider is a test that never runs.
//

import Foundation
import Core

/// A disposable `<root>/inbox` + `<root>/outbox`, with somewhere to put pinned
/// copies and queued reviews.
final class SyncTemporaryFolder {

    /// The sync root.
    let rootURL: URL

    /// Where `InboxItemPinner` should copy to in this test.
    let pinnedRootURL: URL

    /// Where `OutboxQueue` should hold reviews in this test.
    let queueRootURL: URL

    /// Stands in for the App Group container's `staging/`.
    let stagingURL: URL

    /// The folder under test.
    var folder: SyncFolder { SyncFolder(rootURL: rootURL) }

    init() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("pencil-loop-sync-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        rootURL = base.appendingPathComponent("Sync Folder", isDirectory: true)
        pinnedRootURL = base.appendingPathComponent("pinned", isDirectory: true)
        queueRootURL = base.appendingPathComponent("queue", isDirectory: true)
        stagingURL = base.appendingPathComponent("staging", isDirectory: true)

        let manager = FileManager.default
        try manager.createDirectory(at: folder.inboxURL, withIntermediateDirectories: true)
        try manager.createDirectory(at: folder.outboxURL, withIntermediateDirectories: true)
        try manager.createDirectory(at: pinnedRootURL, withIntermediateDirectories: true)
        try manager.createDirectory(at: queueRootURL, withIntermediateDirectories: true)
        try manager.createDirectory(at: stagingURL, withIntermediateDirectories: true)
    }

    /// Removes everything. Call it from a `defer` in every test.
    func removeAll() {
        try? FileManager.default.removeItem(at: rootURL.deletingLastPathComponent())
    }

    // MARK: - Writing

    /// An `inbox/<folderName>/` with whatever combination of files the test
    /// needs. Passing nil for `metaJSON` writes no `meta.json` at all, which is
    /// the "missing metadata" case from docs/04-flows.md § F1.
    @discardableResult
    func writeInboxDirectory(
        named folderName: String,
        metaJSON: String? = SyncTemporaryFolder.completeMetaJSON,
        pdf: Data? = Data("%PDF-1.4 pretend".utf8),
        markdown: String? = nil,
        sourceMapJSON: String? = nil
    ) throws -> URL {
        let directory = folder.inboxURL.appendingPathComponent(folderName, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let pdf {
            try pdf.write(to: directory.appendingPathComponent("document.pdf"))
        }
        if let markdown {
            try Data(markdown.utf8).write(to: directory.appendingPathComponent("source.md"))
        }
        if let sourceMapJSON {
            try Data(sourceMapJSON.utf8).write(to: directory.appendingPathComponent("sourcemap.json"))
        }
        if let metaJSON {
            try Data(metaJSON.utf8).write(to: directory.appendingPathComponent("meta.json"))
        }
        return directory
    }

    /// A directory in `inbox/` that no watcher should ever look at.
    @discardableResult
    func writeHiddenStagingDirectory(named name: String) throws -> URL {
        let directory = folder.inboxURL.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("%PDF-1.4 half written".utf8).write(to: directory.appendingPathComponent("document.pdf"))
        return directory
    }

    /// An `outbox/<name>.review/` with a `reply.md` in it.
    @discardableResult
    func writeReply(inReviewDirectoryNamed directoryName: String, text: String) throws -> URL {
        let directory = folder.outboxURL.appendingPathComponent(directoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("reply.md")
        try Data(text.utf8).write(to: url)
        return url
    }

    /// A staged item, as the share extension would leave it.
    @discardableResult
    func writeStagedDirectory(named name: String, metaJSON: String? = nil) throws -> URL {
        let directory = stagingURL.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("%PDF-1.4 shared".utf8).write(to: directory.appendingPathComponent("document.pdf"))
        if let metaJSON {
            try Data(metaJSON.utf8).write(to: directory.appendingPathComponent("meta.json"))
        }
        return directory
    }

    // MARK: - Reading

    /// Directory and file names directly inside a directory, sorted, including
    /// hidden ones — a test that cannot see the staging directory cannot prove
    /// it was cleaned up.
    func names(in url: URL) -> [String] {
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
        return contents.sorted()
    }

    /// The visible names in `inbox/`.
    var inboxNames: [String] {
        names(in: folder.inboxURL).filter { $0.hasPrefix(".") == false }
    }

    /// The visible names in `outbox/`.
    var outboxNames: [String] {
        names(in: folder.outboxURL).filter { $0.hasPrefix(".") == false }
    }

    /// Text of a file, or nil.
    func text(at url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // MARK: - Fixtures

    /// The golden `meta.json` from docs/05-file-contracts.md, with a real UUID
    /// so the id round-trips.
    static let completeMetaJSON = """
    {
      "id": "F7A1C0DE-0000-4000-8000-000000000001",
      "title": "Auth refactor plan",
      "createdAt": "2026-08-18T18:22:04Z",
      "origin": {
        "kind": "cowork",
        "sessionId": "8f3c1d",
        "threadTitle": "Q3 platform planning",
        "returnPath": { "type": "poke", "triggerId": "trig_1" }
      },
      "sourceFormat": "markdown",
      "pageCount": 4
    }
    """

    /// A `meta.json` that stops mid-object, which is what a half-synced file
    /// looks like.
    static let truncatedMetaJSON = """
    {
      "id": "F7A1C0DE-0000-4000-8000-000000000002",
      "title": "Half a fi
    """

    /// Valid JSON, entirely the wrong shape.
    static let wrongShapeMetaJSON = """
    { "id": 17, "title": ["not", "a", "string"], "createdAt": "yesterday",
      "origin": "cowork", "sourceFormat": 3, "pageCount": "four" }
    """
}
