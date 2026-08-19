//
//  SyncGatewayEventTests.swift
//  AppUITests
//
//  The two ways a consumer used to miss an event it was entitled to.
//
//  1. It started listening after the event was emitted — which at launch is
//     every consumer, because the bookmark is resolved before the library
//     exists (`SyncEventRelay`).
//  2. It started listening before, and still missed it: `events()` registered
//     its continuation in a `Task`, so an event emitted between the call
//     returning and that task getting its turn went to a list the listener was
//     not in yet.
//

import Foundation
import XCTest
@testable import AppUI
import Core

final class SyncGatewayEventTests: XCTestCase {

    /// The launch case: the folder problem happens first, the library listens
    /// second, and the sentence still reaches the status line.
    func testAFolderProblemFromBeforeTheLibraryExistedStillArrives() async {
        let gateway = SyncGateway()
        await gateway.reportFolderUnavailable("That folder is not there any more.")

        var received: SyncEvent?
        for await event in gateway.events() {
            received = event
            break
        }

        XCTAssertEqual(received, .folderUnavailable(reason: "That folder is not there any more."))
    }

    /// The registration gap: emitting immediately after `events()` returns must
    /// reach the stream it returned.
    func testAnEventEmittedRightAfterEventsReturnsIsNotMissed() async {
        let gateway = SyncGateway()
        let stream = gateway.events()

        await gateway.reportFolderUnavailable("The provider is signed out.")

        var received: SyncEvent?
        for await event in stream {
            received = event
            break
        }

        XCTAssertEqual(received, .folderUnavailable(reason: "The provider is signed out."))
    }

    /// Two consumers, one stream each (Protocols.swift § SyncCoordinating).
    func testEveryListenerGetsTheEvent() async {
        let gateway = SyncGateway()
        let first = gateway.events()
        let second = gateway.events()

        await gateway.reportFolderUnavailable("The volume is not mounted.")

        var firstReceived: SyncEvent?
        for await event in first {
            firstReceived = event
            break
        }
        var secondReceived: SyncEvent?
        for await event in second {
            secondReceived = event
            break
        }

        XCTAssertEqual(firstReceived, .folderUnavailable(reason: "The volume is not mounted."))
        XCTAssertEqual(secondReceived, firstReceived)
    }
}
