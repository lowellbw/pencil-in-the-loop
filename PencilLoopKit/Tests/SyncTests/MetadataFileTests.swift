//
//  MetadataFileTests.swift
//  SyncTests
//
//  `meta.json` reading, which per docs/04-flows.md § F1 has exactly one
//  failure mode: none. Every one of these tests is a way the file can be wrong,
//  and the assertion in every case is that the document still ingests.
//

import XCTest
import Foundation
import Core
@testable import Sync

final class MetadataFileTests: XCTestCase {

    func testACompleteMetaJSONReadsEveryField() throws {
        let temp = try SyncTemporaryFolder()
        defer { temp.removeAll() }
        let directory = try temp.writeInboxDirectory(named: "2026-08-18-auth-refactor-plan")

        let metadata = MetadataFile.read(inDirectory: directory)

        XCTAssertEqual(metadata.title, "Auth refactor plan")
        XCTAssertEqual(metadata.sourceFormat, .markdown)
        XCTAssertEqual(metadata.pageCount, 4)
        XCTAssertEqual(metadata.resolvedOrigin.kind, .cowork)
        XCTAssertEqual(metadata.resolvedOrigin.sessionId, "8f3c1d")
        XCTAssertEqual(metadata.resolvedOrigin.returnPath?.type, .poke)
        XCTAssertEqual(metadata.resolvedOrigin.returnPath?.triggerId, "trig_1")
        XCTAssertNotNil(metadata.uuid)
    }

    func testAMissingMetaJSONIsEmptyAndManual() throws {
        let temp = try SyncTemporaryFolder()
        defer { temp.removeAll() }
        let directory = try temp.writeInboxDirectory(named: "2026-08-18-none", metaJSON: nil)

        let metadata = MetadataFile.read(inDirectory: directory)

        XCTAssertEqual(metadata, .empty)
        XCTAssertEqual(metadata.resolvedOrigin.kind, .manual)
        XCTAssertNil(metadata.title)
    }

    func testATruncatedMetaJSONIsEmptyAndManual() throws {
        let temp = try SyncTemporaryFolder()
        defer { temp.removeAll() }
        let directory = try temp.writeInboxDirectory(
            named: "2026-08-18-truncated",
            metaJSON: SyncTemporaryFolder.truncatedMetaJSON
        )

        let metadata = MetadataFile.read(inDirectory: directory)

        XCTAssertEqual(metadata.resolvedOrigin.kind, .manual)
    }

    func testAMetaJSONOfTheWrongShapeDegradesFieldByField() throws {
        let temp = try SyncTemporaryFolder()
        defer { temp.removeAll() }
        let directory = try temp.writeInboxDirectory(
            named: "2026-08-18-wrong-shape",
            metaJSON: SyncTemporaryFolder.wrongShapeMetaJSON
        )

        let metadata = MetadataFile.read(inDirectory: directory)

        XCTAssertNil(metadata.title, "an array where a string belongs is dropped, not fatal")
        XCTAssertNil(metadata.createdAt, "\"yesterday\" is not a date")
        XCTAssertEqual(metadata.resolvedOrigin.kind, .manual)
    }

    func testAnUnknownOriginKindDegradesToManual() throws {
        let temp = try SyncTemporaryFolder()
        defer { temp.removeAll() }
        let directory = try temp.writeInboxDirectory(
            named: "2026-08-18-future-tool",
            metaJSON: """
            {
              "id": "abc",
              "title": "From a tool that does not exist yet",
              "createdAt": "2026-08-18T18:22:04Z",
              "origin": { "kind": "some-future-tool", "returnPath": { "type": "telepathy" } }
            }
            """
        )

        let metadata = MetadataFile.read(inDirectory: directory)

        XCTAssertEqual(metadata.title, "From a tool that does not exist yet")
        XCTAssertEqual(metadata.resolvedOrigin.kind, .manual)
        XCTAssertEqual(metadata.resolvedOrigin.returnPath?.type, ReturnPathType.none)
        XCTAssertEqual(metadata.id, "abc", "a non-UUID id is kept verbatim")
        XCTAssertNil(metadata.uuid)
    }

    func testEncodeRoundTrips() throws {
        let metadata = DocumentMetadata(
            id: "F7A1C0DE-0000-4000-8000-000000000001",
            title: "Auth refactor plan",
            createdAt: Date(timeIntervalSince1970: 1_787_000_000),
            origin: Origin(
                kind: .cowork,
                sessionId: "8f3c1d",
                threadTitle: "Q3 platform planning",
                returnPath: ReturnPath(type: .poke, triggerId: "trig_1")
            ),
            sourceFormat: .markdown,
            pageCount: 4
        )

        let data = try MetadataFile.encode(metadata)
        let decoded = try ContractCoding.decoder().decode(DocumentMetadata.self, from: data)

        XCTAssertEqual(decoded, metadata)
        let text = String(data: data, encoding: .utf8) ?? ""
        XCTAssertTrue(text.contains("\"createdAt\""))
        XCTAssertTrue(
            text.contains(ContractCoding.string(from: Date(timeIntervalSince1970: 1_787_000_000))),
            "dates are written as the file contract spells them, not as the platform default"
        )
    }

    func testInheritedOriginCarriesTheWholeThread() {
        let origin = Origin(
            kind: .cowork,
            sessionId: "8f3c1d",
            threadTitle: "Q3 platform planning",
            returnPath: ReturnPath(type: .poke, triggerId: "trig_1")
        )
        let metadata = DocumentMetadata(origin: origin)

        XCTAssertEqual(MetadataFile.inheritedOrigin(from: metadata), origin)
        XCTAssertEqual(MetadataFile.inheritedOrigin(from: .empty), .manual)
    }

    func testFallbackTitleIsTheFolderNameMadeReadable() {
        XCTAssertEqual(
            MetadataFile.fallbackTitle(forDirectoryNamed: "2026-08-18-auth-refactor-plan"),
            "Auth refactor plan"
        )
        XCTAssertEqual(
            MetadataFile.fallbackTitle(forDirectoryNamed: "something-a-user-dropped-in"),
            "Something a user dropped in"
        )
    }
}
