//
//  SlugTests.swift
//  CoreTests
//
//  Folder names are identities. Three modules build them, so they are built in
//  exactly one place (docs/05-file-contracts.md: "Slugs are lowercase,
//  hyphenated, ASCII").
//

import XCTest
import Core

final class SlugTests: XCTestCase {

    func testMakesALowercaseHyphenatedAsciiSlug() {
        XCTAssertEqual(Slug.make(from: "Auth refactor plan"), "auth-refactor-plan")
        XCTAssertEqual(Slug.make(from: "Q3 Platform Planning!"), "q3-platform-planning")
        XCTAssertEqual(Slug.make(from: "  spaced   out  "), "spaced-out")
    }

    func testFoldsAccentsToAscii() {
        XCTAssertEqual(Slug.make(from: "Café résumé"), "cafe-resume")
    }

    func testCollapsesRunsOfPunctuation() {
        XCTAssertEqual(Slug.make(from: "a — b / c & d"), "a-b-c-d")
    }

    func testNeverReturnsAnEmptyName() {
        XCTAssertEqual(Slug.make(from: ""), "document")
        XCTAssertEqual(Slug.make(from: "—…—"), "document")
    }

    func testTruncatesAtAHyphenBoundary() {
        let title = String(repeating: "alpha beta ", count: 20)
        let slug = Slug.make(from: title)
        XCTAssertLessThanOrEqual(slug.count, Slug.maxLength)
        XCTAssertFalse(slug.hasSuffix("-"))
    }

    func testFolderNameIsDatePrefixedInUTC() {
        // 2026-08-18T23:30:00Z — late enough that a local calendar would differ.
        let date = Date(timeIntervalSince1970: 1_787_095_800)
        let name = Slug.folderName(date: date, title: "Auth refactor plan")
        XCTAssertEqual(name, "2026-08-18-auth-refactor-plan")
    }

    func testSplitsAFolderName() throws {
        let parts = try XCTUnwrap(Slug.split(folderName: "2026-08-18-auth-refactor-plan"))
        XCTAssertEqual(parts.datePrefix, "2026-08-18")
        XCTAssertEqual(parts.slug, "auth-refactor-plan")
    }

    /// A user can drop any folder into inbox/ and it must still ingest.
    func testSplitReturnsNilForAnUndatedFolder() {
        XCTAssertNil(Slug.split(folderName: "my-notes"))
        XCTAssertNil(Slug.split(folderName: "2026-8-18-notes"))
    }

    func testDisambiguatesAgainstExistingNames() {
        let existing: Set<String> = ["2026-08-18-plan", "2026-08-18-plan-2"]
        XCTAssertEqual(Slug.disambiguated("2026-08-18-plan", existing: existing), "2026-08-18-plan-3")
        XCTAssertEqual(Slug.disambiguated("2026-08-18-other", existing: existing), "2026-08-18-other")
    }
}
