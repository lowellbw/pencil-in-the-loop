//
//  SourceSpanTests.swift
//  IngestTests
//
//  The per-run narrowing that makes the source map fine-grained rather than
//  paragraph-shaped.
//

import XCTest
import Core
@testable import Ingest

final class SourceSpanTests: XCTestCase {

    func testARunCoveringPartOfASpanNarrowsToItsOwnBytes() {
        let source = "Hello world"
        let span = SourceSpan(
            text: source,
            range: SourceRange(start: 0, end: 11),
            utf16Start: 0,
            offsets: SourceOffsetIndex(source: source)
        )

        // "Hello" — the first five UTF-16 units of the span.
        XCTAssertEqual(span.sourceRange(forUTF16: 0, length: 5), SourceRange(start: 0, end: 5))
        // "world" — the last five.
        XCTAssertEqual(span.sourceRange(forUTF16: 6, length: 5), SourceRange(start: 6, end: 11))
        XCTAssertEqual(span.sourceRange(forUTF16: 6, length: 5).substring(of: source), "world")
    }

    func testNarrowingCountsBytesForMultibyteText() {
        let source = "café bar"
        let span = SourceSpan(
            text: source,
            range: SourceRange(start: 0, end: source.utf8.count),
            utf16Start: 0,
            offsets: SourceOffsetIndex(source: source)
        )

        // "bar" starts at UTF-16 offset 5 but byte offset 6.
        let range = span.sourceRange(forUTF16: 5, length: 3)
        XCTAssertEqual(range, SourceRange(start: 6, end: 9))
        XCTAssertEqual(range.substring(of: source), "bar")
    }

    func testASpanOffsetIntoTheComposedStringStillNarrowsCorrectly() {
        let source = "one two"
        let span = SourceSpan(
            text: "two",
            range: SourceRange(start: 4, end: 7),
            utf16Start: 12,
            offsets: SourceOffsetIndex(source: source)
        )
        XCTAssertEqual(span.sourceRange(forUTF16: 12, length: 3), SourceRange(start: 4, end: 7))
        XCTAssertEqual(span.sourceRange(forUTF16: 13, length: 2), SourceRange(start: 5, end: 7))
    }

    func testAMisplacedRangeIsCorrectedAgainstTheSource() {
        let source = "a **bold** b"
        // A range that swallowed the asterisks.
        let span = SourceSpan(
            text: "bold",
            range: SourceRange(start: 2, end: 10),
            utf16Start: 0,
            offsets: SourceOffsetIndex(source: source)
        )
        XCTAssertEqual(span.range.substring(of: source), "bold")
    }

    func testTextThatCannotBeFoundKeepsTheWholeSpanRange() {
        let source = "nothing like it"
        let claimed = SourceRange(start: 0, end: 4)
        let span = SourceSpan(
            text: "absent text",
            range: claimed,
            utf16Start: 0,
            offsets: SourceOffsetIndex(source: source)
        )
        XCTAssertEqual(span.range, claimed)
        // No per-code-unit table, so every run reports the whole span.
        XCTAssertEqual(span.sourceRange(forUTF16: 1, length: 2), claimed)
    }

    func testAMarkerSpanAlwaysReportsItsNodeRange() {
        let range = SourceRange(start: 10, end: 24)
        let span = SourceSpan(markerFor: range, utf16Start: 0)
        XCTAssertEqual(span.range, range)
        XCTAssertEqual(span.sourceRange(forUTF16: 0, length: 2), range)
    }

    func testOutOfBoundsRunsFallBackRatherThanTrap() {
        let source = "short"
        let span = SourceSpan(
            text: source,
            range: SourceRange(start: 0, end: 5),
            utf16Start: 0,
            offsets: SourceOffsetIndex(source: source)
        )
        XCTAssertEqual(span.sourceRange(forUTF16: 0, length: 99), span.range)
        XCTAssertEqual(span.sourceRange(forUTF16: -3, length: 2), span.range)
    }
}
