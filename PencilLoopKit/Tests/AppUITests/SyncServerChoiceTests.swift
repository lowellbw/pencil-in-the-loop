//
//  SyncServerChoiceTests.swift
//  AppUITests
//
//  The one place a relay address is checked. Everything here is something a
//  person typed, so every rejection has to be a sentence they can act on rather
//  than a refusal.
//

import XCTest
import Foundation
import Core
@testable import AppUI

final class SyncServerChoiceTests: XCTestCase {

    func testAnOrdinaryAddressIsAccepted() throws {
        let url = try SyncServerChoice.validate(
            urlText: "https://relay.example.com",
            token: "a-token"
        )
        XCTAssertEqual(url.absoluteString, "https://relay.example.com")
    }

    func testABareHostIsReadAsHttps() throws {
        /// What people actually type. Refusing it on a technicality would be
        /// pedantry, not safety — the scheme it gets is the safe one.
        let url = try SyncServerChoice.validate(
            urlText: "relay.example.com",
            token: "a-token"
        )
        XCTAssertEqual(url.scheme, "https")
        XCTAssertEqual(url.host(), "relay.example.com")
    }

    func testATrailingSlashIsRemovedSoPathsCannotDoubleUp() throws {
        let url = try SyncServerChoice.validate(
            urlText: "https://relay.example.com/",
            token: "a-token"
        )
        XCTAssertEqual(url.absoluteString, "https://relay.example.com")
    }

    func testSurroundingWhitespaceFromAPasteIsIgnored() throws {
        let url = try SyncServerChoice.validate(
            urlText: "  https://relay.example.com  ",
            token: "  a-token  "
        )
        XCTAssertEqual(url.absoluteString, "https://relay.example.com")
        XCTAssertEqual(SyncServerChoice.cleaned(token: "  a-token  "), "a-token")
    }

    /// The reason there is no App Transport Security exception in `Info.plist`.
    /// Rejecting this here costs one person with a box on their desk a
    /// certificate; the exception would cost every connection the app ever
    /// makes.
    func testPlainHttpIsRefusedRatherThanWeakeningTheWholeApp() {
        XCTAssertThrowsError(
            try SyncServerChoice.validate(
                urlText: "http://relay.example.com",
                token: "a-token"
            )
        ) { error in
            XCTAssertTrue(
                SyncServerChoice.describe(error).contains("https"),
                "the message has to say what to change"
            )
        }
    }

    func testAnAddressWithNoServerNameIsRefused() {
        for text in ["https://", "https:///path", "::::"] {
            XCTAssertThrowsError(
                try SyncServerChoice.validate(urlText: text, token: "a-token"),
                text
            )
        }
    }

    func testAnEmptyAddressAsksForOneRatherThanFailing() {
        XCTAssertThrowsError(
            try SyncServerChoice.validate(urlText: "   ", token: "a-token")
        ) { error in
            let message = SyncServerChoice.describe(error)
            XCTAssertFalse(message.isEmpty)
            XCTAssertTrue(message.lowercased().contains("relay"), message)
        }
    }

    func testABlankTokenIsRefusedBeforeAnythingIsContacted() {
        for token in ["", "   ", "\n"] {
            XCTAssertThrowsError(
                try SyncServerChoice.validate(
                    urlText: "https://relay.example.com",
                    token: token
                ),
                "a blank token would fail later, and less clearly"
            )
        }
    }

    func testEveryRefusalIsASentenceAPersonCanAct0n() {
        let cases: [(String, String)] = [
            ("", "a-token"),
            ("http://relay.example.com", "a-token"),
            ("https://", "a-token"),
            ("https://relay.example.com", ""),
        ]
        for (urlText, token) in cases {
            do {
                _ = try SyncServerChoice.validate(urlText: urlText, token: token)
                XCTFail("expected \(urlText.isEmpty ? "empty" : urlText) to be refused")
            } catch {
                let message = SyncServerChoice.describe(error)
                XCTAssertGreaterThan(message.count, 20, message)
                XCTAssertTrue(message.hasSuffix("."), "\(message) should read as a sentence")
            }
        }
    }
}
