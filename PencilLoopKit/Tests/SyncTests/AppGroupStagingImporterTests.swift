//
//  AppGroupStagingImporterTests.swift
//  SyncTests
//
//  The share extension's hand-off. A temp directory stands in for the App Group
//  container, which is what the `stagingURL:` override exists for — an App
//  Group is unavailable to a test bundle, and a test that needs one never runs.
//

import XCTest
import Foundation
import Core
@testable import Sync

final class AppGroupStagingImporterTests: XCTestCase {

    func testAStagedDirectoryMovesIntoTheInbox() throws {
        let temp = try SyncTemporaryFolder()
        defer { temp.removeAll() }
        try temp.writeStagedDirectory(named: "2026-08-18-attention-is-all-you-need")
        let importer = AppGroupStagingImporter(stagingURL: temp.stagingURL)

        let imported = importer.importAll(into: temp.folder)

        XCTAssertEqual(imported, ["2026-08-18-attention-is-all-you-need"])
        XCTAssertEqual(temp.inboxNames, ["2026-08-18-attention-is-all-you-need"])
        XCTAssertTrue(importer.pendingNames().isEmpty, "an imported item must not be imported twice")
    }

    func testTheImportedDirectoryKeepsItsFiles() throws {
        let temp = try SyncTemporaryFolder()
        defer { temp.removeAll() }
        try temp.writeStagedDirectory(
            named: "2026-08-18-shared",
            metaJSON: SyncTemporaryFolder.completeMetaJSON
        )
        let importer = AppGroupStagingImporter(stagingURL: temp.stagingURL)

        _ = importer.importAll(into: temp.folder)

        let directory = temp.folder.inboxURL.appendingPathComponent("2026-08-18-shared", isDirectory: true)
        XCTAssertEqual(temp.names(in: directory).sorted(), ["document.pdf", "meta.json"])
        XCTAssertEqual(MetadataFile.read(inDirectory: directory).title, "Auth refactor plan")
    }

    func testACollidingNameIsDisambiguatedRatherThanOverwritten() throws {
        let temp = try SyncTemporaryFolder()
        defer { temp.removeAll() }
        try temp.writeInboxDirectory(named: "2026-08-18-shared")
        try temp.writeStagedDirectory(named: "2026-08-18-shared")
        let importer = AppGroupStagingImporter(stagingURL: temp.stagingURL)

        let imported = importer.importAll(into: temp.folder)

        XCTAssertEqual(imported, ["2026-08-18-shared-2"])
        XCTAssertEqual(temp.inboxNames.sorted(), ["2026-08-18-shared", "2026-08-18-shared-2"])
    }

    func testAStagedItemStillBeingWrittenIsSkipped() throws {
        let temp = try SyncTemporaryFolder()
        defer { temp.removeAll() }
        let hidden = temp.stagingURL.appendingPathComponent(".2026-08-18-half.tmp", isDirectory: true)
        try FileManager.default.createDirectory(at: hidden, withIntermediateDirectories: true)
        try Data("%PDF-1.4 half".utf8).write(to: hidden.appendingPathComponent("document.pdf"))
        let importer = AppGroupStagingImporter(stagingURL: temp.stagingURL)

        let imported = importer.importAll(into: temp.folder)

        XCTAssertTrue(imported.isEmpty)
        XCTAssertTrue(temp.inboxNames.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: hidden.path), "the extension is still writing it")
    }

    func testABareSharedFileIsWrappedIntoTheStandardLayout() throws {
        let temp = try SyncTemporaryFolder()
        defer { temp.removeAll() }
        let file = temp.stagingURL.appendingPathComponent("Attention Is All You Need.pdf")
        try Data("%PDF-1.4 paper".utf8).write(to: file)
        let importer = AppGroupStagingImporter(stagingURL: temp.stagingURL)

        let imported = importer.importAll(into: temp.folder)

        XCTAssertEqual(imported.count, 1)
        let name = try XCTUnwrap(imported.first)
        XCTAssertTrue(name.hasSuffix("attention-is-all-you-need"))
        let directory = temp.folder.inboxURL.appendingPathComponent(name, isDirectory: true)
        XCTAssertEqual(temp.names(in: directory).sorted(), ["document.pdf", "meta.json"])

        let metadata = MetadataFile.read(inDirectory: directory)
        XCTAssertEqual(metadata.resolvedOrigin.kind, .share)
        XCTAssertEqual(metadata.sourceFormat, .pdf)
    }

    func testAStagedMarkdownFileBecomesSourceMarkdown() throws {
        let temp = try SyncTemporaryFolder()
        defer { temp.removeAll() }
        let file = temp.stagingURL.appendingPathComponent("Some notes.md")
        try Data("# Some notes\n".utf8).write(to: file)
        let importer = AppGroupStagingImporter(stagingURL: temp.stagingURL)

        let imported = importer.importAll(into: temp.folder)
        let name = try XCTUnwrap(imported.first)
        let directory = temp.folder.inboxURL.appendingPathComponent(name, isDirectory: true)

        XCTAssertEqual(temp.names(in: directory).sorted(), ["meta.json", "source.md"])
        XCTAssertEqual(MetadataFile.read(inDirectory: directory).sourceFormat, .markdown)
    }

    func testNoStagingContainerIsNotAFailure() {
        let importer = AppGroupStagingImporter(
            appGroupIdentifier: "group.does.not.exist",
            stagingURL: FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
        )

        XCTAssertTrue(importer.pendingNames().isEmpty)
    }

    func testFileNameMapping() {
        XCTAssertEqual(
            AppGroupStagingImporter.inboxFileName(for: URL(fileURLWithPath: "/tmp/paper.PDF")),
            "document.pdf"
        )
        XCTAssertEqual(
            AppGroupStagingImporter.inboxFileName(for: URL(fileURLWithPath: "/tmp/notes.md")),
            "source.md"
        )
    }
}
