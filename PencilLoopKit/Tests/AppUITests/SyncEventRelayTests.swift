//
//  SyncEventRelayTests.swift
//  AppUITests
//
//  The listener list, and the one event it is allowed to remember.
//
//  `AsyncStream` does not replay, and the folder problem that matters most is
//  emitted before any view exists: `RootModel.start()` resolves the bookmark in
//  the same continuation that sets `phase = .library`, so a stale bookmark or an
//  ejected volume reaches `reportFolderUnavailable` before SwiftUI has built the
//  library and run its `.task`. It used to be emitted to nobody and lost, and
//  the user got a silent empty library with no explanation.
//

import Foundation
import XCTest
@testable import AppUI
import Core

final class SyncEventRelayTests: XCTestCase {

    // MARK: - Remembering

    func testAFolderProblemIsReplayedToAListenerThatArrivesAfterIt() async {
        let relay = SyncEventRelay()
        relay.emit(.folderUnavailable(reason: "The volume is not mounted."))

        let (stream, continuation) = AsyncStream<SyncEvent>.makeStream()
        relay.add(UUID(), continuation)

        var received: SyncEvent?
        for await event in stream {
            received = event
            break
        }
        XCTAssertEqual(received, .folderUnavailable(reason: "The volume is not mounted."))
    }

    func testAListenerArrivingWithNoProblemOutstandingIsToldNothing() async {
        let relay = SyncEventRelay()
        let (stream, continuation) = AsyncStream<SyncEvent>.makeStream()
        relay.add(UUID(), continuation)

        // Finishing is what makes "nothing was replayed" observable: the loop
        // ends without a first element rather than waiting for one.
        continuation.finish()
        var received: [SyncEvent] = []
        for await event in stream {
            received.append(event)
        }
        XCTAssertTrue(received.isEmpty)
    }

    // MARK: - Forgetting

    func testAnyOtherEventClearsTheProblem() {
        let relay = SyncEventRelay()
        relay.emit(.folderUnavailable(reason: "The volume is not mounted."))
        relay.emit(.scanFinished(ingestedCount: 0))

        XCTAssertNil(
            relay.folderProblem,
            "A scan that ran is proof the folder answered; replaying the old sentence would be a lie."
        )
    }

    func testAResolvedFolderClearsTheProblem() {
        let relay = SyncEventRelay()
        relay.emit(.folderUnavailable(reason: "The volume is not mounted."))
        relay.clearFolderProblem()

        XCTAssertNil(relay.folderProblem)
    }

    // MARK: - Listeners

    func testARemovedListenerStopsReceiving() async {
        let relay = SyncEventRelay()
        let identifier = UUID()
        let (stream, continuation) = AsyncStream<SyncEvent>.makeStream()
        relay.add(identifier, continuation)
        relay.remove(identifier)

        relay.emit(.scanStarted(pending: 3))
        continuation.finish()

        var received: [SyncEvent] = []
        for await event in stream {
            received.append(event)
        }
        XCTAssertTrue(received.isEmpty)
    }
}
