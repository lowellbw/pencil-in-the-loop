//
//  TransportChoiceTests.swift
//  AppUITests
//
//  Whether the relay a build ships pointed at may still speak.
//
//  This is the rule that stranded a device. `RootModel` adopts the shipped
//  relay once, for installs that predate it, and it used to decide "have they
//  already been offered this?" by asking whether `serverBaseURLString` was set.
//  An install that had the address recorded while sitting on `.folder` looked
//  like somebody who had considered the relay and declined it, so it was never
//  offered again — and documents stopped arriving with nothing on screen to say
//  why, because from the app's point of view nothing was wrong.
//
//  The rule is wrong in two directions and both are silent. Too strict and a
//  device never reaches the relay it was built for; too loose and it overrides
//  a folder somebody deliberately chose, on every launch.
//

import XCTest
import Foundation
import Core
@testable import AppUI

final class TransportChoiceTests: XCTestCase {

    /// Every install that predates the question, which is the case that broke.
    func testAnUnansweredBlobIsNotAChoice() {
        var settings = AppSettings.initial
        settings.hasCompletedFirstRun = true
        settings.syncTransport = .folder

        XCTAssertNil(settings.transportChosenByUser)
        XCTAssertNotEqual(
            settings.transportChosenByUser, true,
            "nobody has chosen, so the shipped relay may still be adopted"
        )
    }

    /// The exact shape the stranded iPad was in: the address recorded, the
    /// transport still folder, nothing ever chosen.
    func testAnAddressOnItsOwnIsNotAChoice() {
        var settings = AppSettings.initial
        settings.hasCompletedFirstRun = true
        settings.syncTransport = .folder
        settings.serverBaseURLString = "https://relay.example.com"
        settings.serverDisplayName = "relay.example.com"

        XCTAssertNotEqual(
            settings.transportChosenByUser, true,
            "recording an address is not the same as choosing a transport"
        )
        XCTAssertEqual(settings.transport, .folder)
    }

    /// The other direction: once it is said, it is respected.
    func testAStatedChoiceIsAChoice() {
        var settings = AppSettings.initial
        settings.hasCompletedFirstRun = true
        settings.syncTransport = .folder
        settings.transportChosenByUser = true

        XCTAssertEqual(settings.transportChosenByUser, true)
    }

    /// It has to survive the round trip, or the answer is forgotten on the next
    /// launch and the relay is adopted over a folder somebody chose.
    func testTheChoiceSurvivesEncoding() throws {
        var settings = AppSettings.initial
        settings.transportChosenByUser = true
        settings.syncTransport = .folder

        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)

        XCTAssertEqual(decoded.transportChosenByUser, true)
        XCTAssertEqual(decoded.transport, .folder)
    }

    /// A blob from before the field existed decodes as nil rather than as a
    /// choice — the same guarantee `syncTransport` needed for the same reason.
    func testABlobWithoutTheFieldDecodesAsUnanswered() throws {
        let older = """
        { "hasCompletedFirstRun" : true, "syncTransport" : "folder" }
        """
        let decoded = try JSONDecoder().decode(AppSettings.self, from: Data(older.utf8))

        XCTAssertNil(decoded.transportChosenByUser)
        XCTAssertEqual(decoded.transport, .folder, "and the transport itself still decodes")
    }
}
