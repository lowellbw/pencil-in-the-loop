//
//  SourceRangeTests.swift
//  CoreTests
//

import XCTest
import Core

final class SourceRangeTests: XCTestCase {

    // MARK: - The on-disk shape

    /// review.json says `"sourceRange": [1204, 1268]`.
    func testEncodesAsTwoElementArray() throws {
        let range = SourceRange(start: 1204, end: 1268)
        let data = try JSONEncoder().encode(range)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "[1204,1268]")
    }

    func testDecodesFromTwoElementArray() throws {
        let range = try JSONDecoder().decode(SourceRange.self, from: Data("[1204, 1268]".utf8))
        XCTAssertEqual(range, SourceRange(start: 1204, end: 1268))
    }

    func testDecodingAnInvertedRangeThrows() {
        XCTAssertThrowsError(try JSONDecoder().decode(SourceRange.self, from: Data("[10, 4]".utf8)))
    }

    func testDecodingANegativeStartThrows() {
        XCTAssertThrowsError(try JSONDecoder().decode(SourceRange.self, from: Data("[-1, 4]".utf8)))
    }

    // MARK: - Half-open semantics

    /// `end` is excluded. If this test ever changes, every anchor in every
    /// review bundle ever written shifts by one character.
    func testRangeIsHalfOpen() {
        let range = SourceRange(start: 4, end: 8)
        XCTAssertEqual(range.length, 4)
        XCTAssertTrue(range.contains(offset: 4))
        XCTAssertTrue(range.contains(offset: 7))
        XCTAssertFalse(range.contains(offset: 8))
    }

    func testEmptyRangeContainsNothing() {
        let range = SourceRange(start: 5, end: 5)
        XCTAssertTrue(range.isEmpty)
        XCTAssertFalse(range.contains(offset: 5))
    }

    func testAdjacentRangesDoNotOverlap() {
        let first = SourceRange(start: 0, end: 10)
        let second = SourceRange(start: 10, end: 20)
        XCTAssertFalse(first.overlaps(second))
        XCTAssertTrue(first.overlaps(SourceRange(start: 9, end: 20)))
    }

    // MARK: - UTF-8 bridging

    func testOffsetsAreUTF8Bytes() {
        let text = "abc"
        XCTAssertEqual(SourceRange.whole(of: text), SourceRange(start: 0, end: 3))
    }

    /// The reason the unit is bytes rather than Characters: a Python or Go tool
    /// reading source.md must slice to the same place we did.
    func testMultibyteCharactersCountAsTheirByteLength() {
        let text = "café ☕"
        XCTAssertEqual(text.count, 6)
        XCTAssertEqual(SourceRange.whole(of: text).length, 9)
    }

    func testSubstringRoundTripsThroughAMultibyteString() throws {
        let text = "Une pièce — the migration runs in a single deploy."
        guard let found = text.range(of: "the migration") else {
            return XCTFail("fixture text changed")
        }
        let range = SourceRange.from(found, in: text)
        XCTAssertEqual(range.substring(of: text), "the migration")
    }

    func testRangeOutsideTheStringReturnsNil() {
        let text = "short"
        XCTAssertNil(SourceRange(start: 0, end: 500).range(in: text))
        XCTAssertNil(SourceRange(start: 0, end: 500).substring(of: text))
    }

    func testOffsetShiftsBothEnds() {
        XCTAssertEqual(
            SourceRange(start: 10, end: 20).offset(by: 5),
            SourceRange(start: 15, end: 25)
        )
    }

    func testUnionCoversBoth() {
        let union = SourceRange(start: 10, end: 20).union(SourceRange(start: 40, end: 45))
        XCTAssertEqual(union, SourceRange(start: 10, end: 45))
    }
}
