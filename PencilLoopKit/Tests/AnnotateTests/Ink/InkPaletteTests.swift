import XCTest
import UIKit
import Core
@testable import Annotate

/// The five ink colours, which are the only hardcoded palette in the app
/// (docs/01-design-principles.md § 1).
final class InkPaletteTests: XCTestCase {

    func testThereAreExactlyFiveInks() {
        XCTAssertEqual(InkPalette.allCases.count, 5)
    }

    func testTheDefaultMatchesTheStoredDefault() {
        // InkDefaults.standard.tintHex is frozen in Core; the palette must
        // agree with it or the app opens on a colour that is not in its own
        // palette.
        XCTAssertEqual(InkPalette.standard.tintHex, InkDefaults.standard.tintHex)
    }

    func testEveryHexRoundTripsThroughATint() {
        for ink in InkPalette.allCases {
            let hex = InkPalette.hex(fromTint: ink.uiTint)
            XCTAssertEqual(hex, ink.tintHex, "\(ink.displayName) does not survive a round trip.")
        }
    }

    func testEveryInkIsDistinct() {
        XCTAssertEqual(Set(InkPalette.allCases.map(\.tintHex)).count, InkPalette.allCases.count)
    }

    func testAPersistedHexResolvesBackToItsEntry() {
        XCTAssertEqual(InkPalette.palette(forHex: "#FF3B30"), .red)
        XCTAssertEqual(InkPalette.palette(forHex: "ff3b30"), .red)
        XCTAssertNil(InkPalette.palette(forHex: "#123456"))
    }

    func testShorthandAndCasingAreAccepted() {
        XCTAssertEqual(InkPalette.canonicalHex("#fff"), "#FFFFFF")
        XCTAssertEqual(InkPalette.canonicalHex("00ff00"), "#00FF00")
    }

    func testNonsenseFallsBackToGraphiteRatherThanToInvisibleInk() {
        XCTAssertEqual(InkPalette.canonicalHex("not a colour value"), InkPalette.graphite.tintHex)
        let tint = InkPalette.tint(fromHex: "")
        XCTAssertEqual(InkPalette.hex(fromTint: tint), InkPalette.graphite.tintHex)
    }

    func testOnlyTheHighlighterIsTranslucent() {
        let translucent = InkPalette.allCases.filter(\.isTranslucent)
        XCTAssertEqual(translucent, [.highlighter])
    }

    func testEveryInkHasAVoiceOverLabel() {
        for ink in InkPalette.allCases {
            XCTAssertFalse(ink.displayName.isEmpty)
        }
    }
}
