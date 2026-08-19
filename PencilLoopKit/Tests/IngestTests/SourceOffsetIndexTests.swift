//
//  SourceOffsetIndexTests.swift
//  IngestTests
//
//  The offset convention is the foundation of the source map, so it is tested
//  first and hardest. Everything here is UTF-8 bytes (SourceRange.swift § 2).
//

import XCTest
import Core
@testable import Ingest

final class SourceOffsetIndexTests: XCTestCase {

    func testLineAndColumnAreOneBasedByteOffsets() {
        let source = "alpha\nbeta\ngamma\n"
        let index = SourceOffsetIndex(source: source)

        XCTAssertEqual(index.byteOffset(line: 1, column: 1), 0)
        XCTAssertEqual(index.byteOffset(line: 2, column: 1), 6)
        XCTAssertEqual(index.byteOffset(line: 3, column: 1), 11)
        XCTAssertEqual(index.byteOffset(line: 2, column: 3), 8)
    }

    func testColumnsAreClampedIntoTheirOwnLine() {
        let source = "ab\ncd\n"
        let index = SourceOffsetIndex(source: source)

        // A parser that over-reports a column must not produce an offset
        // sitting inside the following line.
        XCTAssertEqual(index.byteOffset(line: 1, column: 999), 3)
        XCTAssertEqual(index.byteOffset(line: 1, column: 0), 0)
        XCTAssertEqual(index.byteOffset(line: 99, column: 1), 6)
    }

    func testRangeCountsBytesNotCharacters() {
        let source = "café ☕ done"
        let index = SourceOffsetIndex(source: source)

        // "café " is 6 bytes: c a f é(2) space.
        let range = index.range(fromLine: 1, fromColumn: 1, toLine: 1, toColumn: 6)
        XCTAssertEqual(range.start, 0)
        XCTAssertEqual(range.end, 5)
        XCTAssertEqual(range.substring(of: source), "café")
        XCTAssertNotEqual(source.count, source.utf8.count)
    }

    func testSnappingMovesOffScalarBoundariesOutwards() {
        let source = "é"
        let index = SourceOffsetIndex(source: source)

        // Byte 1 is a continuation byte; snapping must not leave a range that
        // cannot be turned back into text.
        let snapped = index.snapped(SourceRange(start: 1, end: 1))
        XCTAssertEqual(snapped.start, 0)
        XCTAssertNotNil(snapped.substring(of: source))
    }

    func testSnappingClampsIntoTheSource() {
        let index = SourceOffsetIndex(source: "abc")
        let snapped = index.snapped(SourceRange(start: 2, end: 99))
        XCTAssertEqual(snapped.start, 2)
        XCTAssertEqual(snapped.end, 3)
    }

    func testLocateReturnsTheRangeUnchangedWhenItAlreadyMatches() {
        let source = "one two three"
        let index = SourceOffsetIndex(source: source)
        let located = index.locate("two", near: SourceRange(start: 4, end: 7))
        XCTAssertEqual(located, SourceRange(start: 4, end: 7))
    }

    func testLocateCorrectsAnOffsetThatDriftedOntoTheSyntax() {
        let source = "a **bold** b"
        let index = SourceOffsetIndex(source: source)
        // A range covering the asterisks as well as the word.
        let located = index.locate("bold", near: SourceRange(start: 2, end: 10))
        XCTAssertEqual(located?.substring(of: source), "bold")
    }

    func testLocateGivesUpRatherThanGuessing() {
        let index = SourceOffsetIndex(source: "nothing like it here")
        XCTAssertNil(index.locate("absent", near: SourceRange(start: 0, end: 6)))
        XCTAssertNil(index.locate("", near: SourceRange(start: 0, end: 0)))
    }

    func testLineBreakRangeFindsTheNewlineBehindTrailingSpaces() {
        let index = SourceOffsetIndex(source: "one  \ntwo")
        XCTAssertEqual(index.lineBreakRange(from: 3), SourceRange(start: 5, end: 6))
        XCTAssertEqual(index.lineBreakRange(from: 5), SourceRange(start: 5, end: 6))
    }

    func testLineBreakRangeCoversBothBytesOfACarriageReturnPair() {
        let index = SourceOffsetIndex(source: "one\r\ntwo")
        XCTAssertEqual(index.lineBreakRange(from: 3), SourceRange(start: 3, end: 5))
    }

    func testLineBreakRangeGivesUpOnAnythingThatIsNotALineEnding() {
        let index = SourceOffsetIndex(source: "one two")
        XCTAssertNil(index.lineBreakRange(from: 0))
        XCTAssertNil(index.lineBreakRange(from: 3))
    }

    func testWholeRangeCoversEveryByte() {
        let source = "naïve ☕"
        let index = SourceOffsetIndex(source: source)
        XCTAssertEqual(index.wholeRange, SourceRange.whole(of: source))
        XCTAssertEqual(index.wholeRange.substring(of: source), source)
    }
}
