//
//  OriginDecodingTests.swift
//  CoreTests
//
//  docs/04-flows.md § F1: "a malformed meta.json must never block ingest — fall
//  back to filename as title and origin.kind = manual". These tests are that
//  sentence, executable.
//

import XCTest
import Core

final class OriginDecodingTests: XCTestCase {

    private func decodeMetadata(_ json: String) throws -> DocumentMetadata {
        try ContractCoding.decoder().decode(DocumentMetadata.self, from: Data(json.utf8))
    }

    // MARK: - The happy path, exactly as the spec shows it

    func testDecodesTheSpecExample() throws {
        let meta = try decodeMetadata("""
        {
          "id": "F7A1",
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
        """)
        XCTAssertEqual(meta.id, "F7A1")
        XCTAssertEqual(meta.title, "Auth refactor plan")
        XCTAssertEqual(meta.pageCount, 4)
        XCTAssertEqual(meta.sourceFormat, .markdown)
        XCTAssertEqual(meta.resolvedOrigin.kind, .cowork)
        XCTAssertEqual(meta.resolvedOrigin.sessionId, "8f3c1d")
        XCTAssertEqual(meta.resolvedOrigin.returnPath?.type, .poke)
        XCTAssertEqual(meta.resolvedOrigin.returnPath?.triggerId, "trig_1")
        XCTAssertTrue(meta.resolvedOrigin.canReturn)
    }

    /// The hyphen is the whole reason OriginKind has explicit raw values.
    func testClaudeCodeKeepsItsHyphen() throws {
        let meta = try decodeMetadata(#"{"origin":{"kind":"claude-code"}}"#)
        XCTAssertEqual(meta.resolvedOrigin.kind, .claudeCode)
        XCTAssertEqual(OriginKind.claudeCode.rawValue, "claude-code")
    }

    /// Appending a case is cheap and this list is expected to grow; renaming
    /// one breaks every tool that ever wrote our folder format, which is what
    /// this is here to stop. So a failure that *reorders* or *renames* is a
    /// bug, and a failure that only adds to the end is this test asking to be
    /// told about it.
    func testEveryOriginKindRawValueIsStable() {
        XCTAssertEqual(
            OriginKind.allCases.map(\.rawValue),
            ["cowork", "claude-code", "codex", "share", "manual", "note"]
        )
        // Persisted in note.json, so a rename silently unrules every notebook
        // somebody already has.
        XCTAssertEqual(
            PaperStyle.allCases.map(\.rawValue),
            ["plain", "lined", "grid"]
        )
        XCTAssertEqual(
            ReturnPathType.allCases.map(\.rawValue),
            ["poke", "checkin", "resume", "cloud", "none"]
        )
        XCTAssertEqual(
            CommentSource.allCases.map(\.rawValue),
            ["voice", "handwriting", "typed"]
        )
        XCTAssertEqual(
            DocState.allCases.map(\.rawValue),
            ["unread", "reviewing", "read", "archived"]
        )
    }

    // MARK: - Degrading rather than throwing

    func testUnknownOriginKindBecomesManual() throws {
        let meta = try decodeMetadata(#"{"origin":{"kind":"telepathy"}}"#)
        XCTAssertEqual(meta.resolvedOrigin.kind, .manual)
        XCTAssertFalse(meta.resolvedOrigin.canReturn)
    }

    func testUnknownReturnPathTypeBecomesNone() throws {
        let meta = try decodeMetadata(
            #"{"origin":{"kind":"cowork","returnPath":{"type":"carrier-pigeon"}}}"#
        )
        XCTAssertEqual(meta.resolvedOrigin.returnPath?.type, ReturnPathType.none)
        XCTAssertFalse(meta.resolvedOrigin.canReturn)
    }

    func testOriginOfTheWrongTypeDoesNotThrow() throws {
        let meta = try decodeMetadata(#"{"title":"Notes","origin":"cowork"}"#)
        XCTAssertEqual(meta.title, "Notes")
        XCTAssertEqual(meta.resolvedOrigin.kind, .manual)
    }

    func testReturnPathOfTheWrongTypeDoesNotThrow() throws {
        let meta = try decodeMetadata(#"{"origin":{"kind":"cowork","returnPath":42}}"#)
        XCTAssertEqual(meta.resolvedOrigin.kind, .cowork)

        // Not nil, and that is the tolerance working rather than failing.
        // `ReturnPath.init(from:)` never throws: handed something that is not a
        // keyed container it degrades to `.none` (Origin.swift), so
        // `decodeIfPresent` on a key that *is* present returns that value and
        // `try?` has nothing to turn into nil. The nil case is a return path
        // that was not in the JSON at all.
        //
        // Both shapes mean the same thing downstream — `canReturn` is false
        // either way — so do not "fix" this by making the decoder throw. The
        // never-throwing guarantee is what docs/04-flows.md § F1 leans on: a
        // malformed `meta.json` must never cost the document.
        XCTAssertEqual(meta.resolvedOrigin.returnPath?.type, ReturnPathType.none)
        XCTAssertFalse(meta.resolvedOrigin.canReturn)
    }

    func testAnAbsentReturnPathIsNil() throws {
        let meta = try decodeMetadata(#"{"origin":{"kind":"cowork"}}"#)
        XCTAssertNil(meta.resolvedOrigin.returnPath, "absent is the only thing that decodes to nil")
        XCTAssertFalse(meta.resolvedOrigin.canReturn)
    }

    func testMissingFieldsAreNilRatherThanFatal() throws {
        let meta = try decodeMetadata("{}")
        XCTAssertNil(meta.id)
        XCTAssertNil(meta.title)
        XCTAssertNil(meta.createdAt)
        XCTAssertNil(meta.origin)
        XCTAssertEqual(meta.resolvedOrigin, Origin.manual)
    }

    func testATopLevelArrayDegradesToEmpty() throws {
        let meta = try decodeMetadata("[]")
        XCTAssertEqual(meta, DocumentMetadata.empty)
    }

    func testFieldsOfTheWrongTypeAreDropped() throws {
        let meta = try decodeMetadata(#"{"id":1234,"title":true,"pageCount":"four"}"#)
        XCTAssertNil(meta.id)
        XCTAssertNil(meta.title)
        XCTAssertNil(meta.pageCount)
    }

    func testANumericSessionIdIsReadAsAString() throws {
        let meta = try decodeMetadata(#"{"origin":{"kind":"codex","sessionId":8153}}"#)
        XCTAssertEqual(meta.resolvedOrigin.sessionId, "8153")
    }

    func testAnEmptySessionIdIsTreatedAsAbsent() throws {
        let meta = try decodeMetadata(#"{"origin":{"kind":"cowork","sessionId":""}}"#)
        XCTAssertNil(meta.resolvedOrigin.sessionId)
    }

    func testUnknownKeysAreIgnored() throws {
        let meta = try decodeMetadata(
            #"{"title":"Plan","futureField":{"a":1},"origin":{"kind":"cowork","mood":"brisk"}}"#
        )
        XCTAssertEqual(meta.title, "Plan")
        XCTAssertEqual(meta.resolvedOrigin.kind, .cowork)
    }

    // MARK: - Dates

    func testCreatedAtParsesISO8601WithZ() throws {
        let meta = try decodeMetadata(#"{"createdAt":"2026-08-18T18:22:04Z"}"#)
        XCTAssertEqual(meta.createdAt, ContractCoding.date(from: "2026-08-18T18:22:04Z"))
    }

    func testCreatedAtParsesFractionalSeconds() throws {
        let meta = try decodeMetadata(#"{"createdAt":"2026-08-18T18:22:04.512Z"}"#)
        XCTAssertNotNil(meta.createdAt)
    }

    func testCreatedAtParsesAUnixTimestamp() throws {
        let meta = try decodeMetadata(#"{"createdAt":1787000000}"#)
        XCTAssertEqual(meta.createdAt, Date(timeIntervalSince1970: 1_787_000_000))
    }

    func testNonsenseDateIsNilRatherThanFatal() throws {
        let meta = try decodeMetadata(#"{"createdAt":"last Tuesday"}"#)
        XCTAssertNil(meta.createdAt)
    }

    // MARK: - Encoding

    func testEncodingOmitsAbsentOriginFields() throws {
        let meta = DocumentMetadata(id: "F7A1", title: "Plan", origin: Origin(kind: .share))
        let data = try ContractCoding.encoder().encode(meta)
        let json = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(json.contains("\"kind\" : \"share\""))
        XCTAssertFalse(json.contains("sessionId"))
        XCTAssertFalse(json.contains("null"))
    }

    func testEncodingUsesISO8601WithZ() throws {
        let date = Date(timeIntervalSince1970: 1_787_000_524)
        let meta = DocumentMetadata(createdAt: date)
        let data = try ContractCoding.encoder().encode(meta)
        let json = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(json.contains(ContractCoding.string(from: date)))
        XCTAssertTrue(json.contains("Z"))
    }
}
