//
//  SyncCursorStoreTests.swift
//  SyncTests
//
//  The cursor is one number, and every test here is about the cases where
//  keeping it would be worse than losing it.
//
//  A sequence number is meaningful only against the relay that allocated it and
//  the index generation it was allocated in. Carry it across either boundary and
//  the device silently skips every document numbered below it — which is the
//  one failure this project cannot see and cannot recover from without the user
//  noticing a document never arrived.
//

import XCTest
import Foundation
import Core
@testable import Sync

final class SyncCursorStoreTests: XCTestCase {

    private let relay = URL(string: "https://relay.example.com") ?? URL(fileURLWithPath: "/")
    private let other = URL(string: "https://relay.example.net") ?? URL(fileURLWithPath: "/")

    func testACursorSurvivesBeingWrittenAndReadBack() throws {
        let temp = try SyncTemporaryFolder()
        defer { temp.removeAll() }
        let store = SyncCursorStore(rootURL: temp.queueRootURL)

        store.save(cursor: 412, epoch: "9c1f", forBaseURL: relay)

        let state = try XCTUnwrap(store.state(forBaseURL: relay))
        XCTAssertEqual(state.cursor, 412)
        XCTAssertEqual(state.epoch, "9c1f")
        XCTAssertEqual(store.cursor(forBaseURL: relay, epoch: "9c1f"), 412)
    }

    func testChangingTheServerResetsTheCursor() throws {
        let temp = try SyncTemporaryFolder()
        defer { temp.removeAll() }
        let store = SyncCursorStore(rootURL: temp.queueRootURL)
        store.save(cursor: 412, epoch: "9c1f", forBaseURL: relay)

        XCTAssertNil(
            store.state(forBaseURL: other),
            "412 on one relay means nothing on another, and using it would skip everything below it"
        )
        XCTAssertNil(store.cursor(forBaseURL: other, epoch: "9c1f"))
    }

    func testANewEpochResetsTheCursor() throws {
        let temp = try SyncTemporaryFolder()
        defer { temp.removeAll() }
        let store = SyncCursorStore(rootURL: temp.queueRootURL)
        store.save(cursor: 412, epoch: "9c1f", forBaseURL: relay)

        XCTAssertNil(
            store.cursor(forBaseURL: relay, epoch: "rebuilt"),
            "a rebuilt index re-allocates sequence numbers, so the whole feed is re-listed"
        )
        XCTAssertEqual(
            store.cursor(forBaseURL: relay, epoch: nil),
            412,
            "before any page has arrived there is no epoch to disagree with"
        )
    }

    func testNothingRecordedMeansListEverything() throws {
        let temp = try SyncTemporaryFolder()
        defer { temp.removeAll() }
        let store = SyncCursorStore(rootURL: temp.queueRootURL)

        XCTAssertNil(store.state(forBaseURL: relay))
        XCTAssertNil(store.cursor(forBaseURL: relay, epoch: "9c1f"))
    }

    func testAnUnreadableCursorCostsARelistAndNothingElse() throws {
        let temp = try SyncTemporaryFolder()
        defer { temp.removeAll() }
        let store = SyncCursorStore(rootURL: temp.queueRootURL)
        store.save(cursor: 412, epoch: "9c1f", forBaseURL: relay)
        try Data("{ this is not the file it was".utf8).write(to: store.fileURL)

        XCTAssertNil(
            store.state(forBaseURL: relay),
            "a sync layer that refused to run because its bookkeeping file was corrupt would be worse than the corruption"
        )
    }

    func testClearingForgetsEverything() throws {
        let temp = try SyncTemporaryFolder()
        defer { temp.removeAll() }
        let store = SyncCursorStore(rootURL: temp.queueRootURL)
        store.save(cursor: 412, epoch: "9c1f", forBaseURL: relay)

        store.clear()

        XCTAssertNil(store.state(forBaseURL: relay))
    }

    func testTheCursorLivesInTheSameContainerRootAsTheQueue() {
        XCTAssertEqual(
            SyncCursorStore.defaultRootURL().deletingLastPathComponent().path,
            OutboxQueue.defaultRootURL().deletingLastPathComponent().path,
            "one container layout, not two: three modules once invented three (DocumentContainer.swift)"
        )
        XCTAssertEqual(SyncCursorStore.defaultRootURL().lastPathComponent, "http-sync")
        XCTAssertEqual(
            SyncCursorStore(rootURL: SyncCursorStore.defaultRootURL()).fileURL.lastPathComponent,
            "cursor.json"
        )
    }
}
