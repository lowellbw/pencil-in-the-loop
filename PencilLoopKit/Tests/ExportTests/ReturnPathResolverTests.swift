//
//  ReturnPathResolverTests.swift
//  ExportTests
//
//  Every `returnPath.type`, and the two ways each one can fail to be usable:
//  an origin kind that never carried a conversation, and a missing identifier.
//
//  The badge is the thing under test. It is the only place the user learns
//  whether their context is preserved (docs/02-spec.md § S4), so
//  `ResolvedReturnPath.sameThread` has to be true exactly when it is true.
//

import XCTest
import Foundation
import Core
@testable import Export

final class ReturnPathResolverTests: XCTestCase {

    // MARK: - Every type

    func testPokeWithATriggerIsSameThread() {
        let resolved = Self.resolve(kind: .cowork, type: .poke, triggerId: "trig_123")
        XCTAssertEqual(resolved.type, .poke)
        XCTAssertEqual(resolved.displayName, "Cowork")
        XCTAssertEqual(resolved.triggerId, "trig_123")
        XCTAssertTrue(resolved.sameThread)
        XCTAssertEqual(resolved.badgeText, "SAME THREAD")
    }

    /// The v1 default: the session's own scheduled check-in reads the outbox, so
    /// nothing has to be installed and nothing has to be fired.
    func testCheckinIsSameThreadWithNoIdentifiersAtAll() {
        let resolved = Self.resolve(kind: .cowork, type: .checkin)
        XCTAssertEqual(resolved.type, .checkin)
        XCTAssertTrue(resolved.sameThread)
        XCTAssertNil(resolved.triggerId)
    }

    func testResumeWithASessionIsSameThread() {
        let resolved = Self.resolve(kind: .claudeCode, type: .resume, sessionId: "sess_9")
        XCTAssertEqual(resolved.type, .resume)
        XCTAssertEqual(resolved.displayName, "Claude Code")
        XCTAssertEqual(resolved.sessionId, "sess_9")
        XCTAssertTrue(resolved.sameThread)
    }

    func testCloudWithASessionIsSameThread() {
        let resolved = Self.resolve(kind: .claudeCode, type: .cloud, sessionId: "sess_9")
        XCTAssertEqual(resolved.type, .cloud)
        XCTAssertTrue(resolved.sameThread)
    }

    func testCodexResolvesLikeAnyOtherReturningOrigin() {
        let resolved = Self.resolve(kind: .codex, type: .resume, sessionId: "sess_9")
        XCTAssertEqual(resolved.displayName, "Codex")
        XCTAssertTrue(resolved.sameThread)
    }

    /// Never an error. The share sheet into the Claude app works today
    /// (docs/06-integrations.md § The universal fallback).
    func testAnExplicitNoneIsUnresolvedRatherThanFailed() {
        let resolved = Self.resolve(kind: .cowork, type: ReturnPathType.none)
        XCTAssertEqual(resolved, .unresolved)
        XCTAssertEqual(resolved.displayName, "No return path")
        XCTAssertEqual(resolved.badgeText, "NEW THREAD")
        XCTAssertFalse(resolved.sameThread)
    }

    func testEveryReturnPathTypeResolvesToSomething() {
        for type in ReturnPathType.allCases {
            let resolved = ReturnPathResolver().resolve(
                Origin(
                    kind: .cowork,
                    sessionId: "sess_9",
                    threadTitle: "Planning",
                    returnPath: ReturnPath(type: type, triggerId: "trig_1")
                )
            )
            XCTAssertFalse(resolved.displayName.isEmpty, "\(type) produced no destination row")
            XCTAssertFalse(resolved.badgeText.isEmpty)
        }
    }

    // MARK: - Origins that never had a thread

    func testAManuallyAddedDocumentHasNoReturnPath() {
        XCTAssertEqual(ReturnPathResolver().resolve(.manual), .unresolved)
        XCTAssertEqual(ReturnPathResolver().resolve(Origin()), .unresolved)
    }

    func testASharedDocumentHasNoReturnPathEvenIfMetaClaimsOne() {
        let resolved = Self.resolve(kind: .share, type: .poke, triggerId: "trig_1", sessionId: "sess_9")
        XCTAssertEqual(resolved, .unresolved)
    }

    func testAnAbsentReturnPathObjectIsUnresolved() {
        let resolved = ReturnPathResolver().resolve(Origin(kind: .cowork, sessionId: "sess_9"))
        XCTAssertEqual(resolved, .unresolved)
    }

    // MARK: - Types that cannot keep their promise

    /// `sameThread` is not `type.isSameThread`: the type says what the writing
    /// tool intended, this says what the identifiers it recorded can actually
    /// deliver. `ResolvedReturnPath` documents this field as the one to trust.
    func testPokeWithoutATriggerCannotPreserveContext() {
        let resolved = Self.resolve(kind: .cowork, type: .poke, sessionId: "sess_9")
        XCTAssertEqual(resolved.type, .poke)
        XCTAssertTrue(ReturnPathType.poke.isSameThread)
        XCTAssertFalse(resolved.sameThread)
        XCTAssertEqual(resolved.badgeText, "NEW THREAD")
    }

    func testResumeWithoutASessionCannotPreserveContext() {
        let resolved = Self.resolve(kind: .claudeCode, type: .resume, triggerId: "trig_1")
        XCTAssertEqual(resolved.type, .resume)
        XCTAssertFalse(resolved.sameThread)
    }

    func testCloudWithoutASessionCannotPreserveContext() {
        XCTAssertFalse(Self.resolve(kind: .claudeCode, type: .cloud).sameThread)
    }

    /// A blank string in `meta.json` is not an identifier.
    func testWhitespaceIdentifiersAreTreatedAsAbsent() {
        let resolved = Self.resolve(kind: .cowork, type: .poke, triggerId: "   ")
        XCTAssertNil(resolved.triggerId)
        XCTAssertFalse(resolved.sameThread)
    }

    func testIdentifiersAreTrimmed() {
        let resolved = Self.resolve(kind: .claudeCode, type: .cloud, sessionId: "  sess_9\n")
        XCTAssertEqual(resolved.sessionId, "sess_9")
    }

    // MARK: - What the destination row shows

    func testTheThreadTitleIsCarriedThroughForTheDestinationRow() {
        let resolved = ReturnPathResolver().resolve(
            Origin(
                kind: .cowork,
                sessionId: "8f3c1d",
                threadTitle: "Q3 platform planning",
                returnPath: ReturnPath(type: .checkin)
            )
        )
        XCTAssertEqual(resolved.threadTitle, "Q3 platform planning")
        XCTAssertEqual(resolved.sessionId, "8f3c1d")
    }

    /// An unrecognised type in `meta.json` decodes as `.none`, and we would
    /// rather show the share sheet than claim a path that does not exist.
    func testAnUnknownTypeFromMetaJsonDegradesToNoPath() throws {
        let json = Data("""
            { "kind": "cowork", "sessionId": "s", "returnPath": { "type": "carrier-pigeon" } }
            """.utf8)
        let origin = try ContractCoding.decoder().decode(Origin.self, from: json)
        XCTAssertEqual(origin.returnPath?.type, ReturnPathType.none)
        XCTAssertEqual(ReturnPathResolver().resolve(origin), .unresolved)
    }

    // MARK: - Support

    static func resolve(
        kind: OriginKind,
        type: ReturnPathType,
        triggerId: String? = nil,
        sessionId: String? = nil
    ) -> ResolvedReturnPath {
        ReturnPathResolver().resolve(
            Origin(
                kind: kind,
                sessionId: sessionId,
                threadTitle: nil,
                returnPath: ReturnPath(type: type, triggerId: triggerId)
            )
        )
    }
}
