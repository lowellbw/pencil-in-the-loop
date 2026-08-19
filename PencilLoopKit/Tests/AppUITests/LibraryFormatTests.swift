//
//  LibraryFormatTests.swift
//  AppUITests
//
//  The strings one library row shows (docs/02-spec.md § S1).
//
//  The relative date is the system's phrasing and is not asserted word for word
//  — that is a locale decision and would make this test a test of Foundation.
//  What is asserted is the shape: which parts appear, in which order, and what
//  the trailing dot says out loud.
//

import Foundation
import XCTest
@testable import AppUI
import Core

@MainActor
final class LibraryFormatTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_787_000_000)

    // MARK: - Subtitle

    func testTheSubtitleIsOriginThenWhenThenPages() {
        let summary = AppUITestSamples.summary(addedAt: now.addingTimeInterval(-480), pageCount: 4)
        let subtitle = LibraryFormat.subtitle(for: summary, now: now)
        let parts = subtitle.components(separatedBy: " · ")

        XCTAssertEqual(parts.count, 3, "Cowork · 8 min ago · 4 pages")
        XCTAssertEqual(parts.first, "Cowork")
        XCTAssertEqual(parts.last, "4 pages")
        XCTAssertFalse(parts[1].isEmpty)
    }

    func testAnOriginWithNoNameIsLeftOutRatherThanLeavingAGap() {
        let summary = AppUITestSamples.summary(originDisplayName: "", addedAt: now)
        let parts = LibraryFormat.subtitle(for: summary, now: now).components(separatedBy: " · ")
        XCTAssertEqual(parts.count, 2)
        XCTAssertEqual(parts.last, "4 pages")
    }

    func testPagesAreSingularWhenThereIsOne() {
        XCTAssertEqual(LibraryFormat.pages(1), "1 page")
        XCTAssertEqual(LibraryFormat.pages(0), "0 pages")
        XCTAssertEqual(LibraryFormat.pages(15), "15 pages")
    }

    // MARK: - The trailing dot, spoken

    func testADocumentThatIsSimplyHereAnnouncesNothing() {
        XCTAssertNil(
            LibraryFormat.localStateDescription(.local),
            "A dot that means 'this is fine' is not worth a word of VoiceOver."
        )
    }

    func testDownloadingIsAnnouncedWithItsProgressWhenThereIsAny() {
        XCTAssertEqual(LibraryFormat.localStateDescription(.downloading(progress: nil)), "Downloading")
        let described = LibraryFormat.localStateDescription(.downloading(progress: 0.4))
        XCTAssertNotNil(described)
        XCTAssertTrue(described?.hasPrefix("Downloading, ") ?? false)
    }

    func testAnUnavailableDocumentSaysWhy() {
        let described = LibraryFormat.localStateDescription(.unavailable(reason: "The folder could not be read."))
        XCTAssertEqual(described, "Unavailable. The folder could not be read.")
    }

    // MARK: - VoiceOver

    func testTheAccessibilityLabelLeadsWithTheTitleAndCarriesTheState() {
        let summary = AppUITestSamples.summary(
            addedAt: now.addingTimeInterval(-3600),
            commentCount: 3,
            localState: .unavailable(reason: "Its folder could not be read.")
        )
        let label = LibraryFormat.accessibilityLabel(for: summary, now: now)

        XCTAssertTrue(label.hasPrefix("Auth refactor plan, "))
        XCTAssertTrue(label.contains("3 comments"))
        XCTAssertTrue(label.contains("Unavailable. Its folder could not be read."))
    }

    // MARK: - The refresh note

    /// The gap this covers: a document that quietly stopped updating read
    /// exactly like one that is fine. The only live surfacing was a transient
    /// `SyncEvent.ingestFailed` in the status line, gone by the next scan.
    func testARowThatDidNotRefreshSaysSoQuietly() {
        let summary = AppUITestSamples.summary(
            addedAt: now,
            refreshFailureReason: "The download did not finish."
        )
        let note = LibraryFormat.refreshNote(for: summary)

        XCTAssertEqual(
            note,
            "Couldn’t update. The download did not finish.",
            "the row still opens, so this reports what is stale rather than what is broken"
        )
    }

    func testARowThatRefreshedFineSaysNothing() {
        let summary = AppUITestSamples.summary(addedAt: now)
        XCTAssertNil(
            LibraryFormat.refreshNote(for: summary),
            "a document that is up to date has no news, and a row of reassurances is noise"
        )
    }

    func testAnEmptyReasonIsNotANote() {
        let summary = AppUITestSamples.summary(addedAt: now, refreshFailureReason: "")
        XCTAssertNil(LibraryFormat.refreshNote(for: summary), "a note with nothing in it says nothing")
    }

    /// The note is drawn small and dim, which VoiceOver cannot convey, so the
    /// label has to carry it (docs/01-design-principles.md § 8).
    func testTheRefreshNoteIsSpoken() {
        let summary = AppUITestSamples.summary(
            addedAt: now,
            commentCount: 2,
            refreshFailureReason: "The download did not finish."
        )
        let label = LibraryFormat.accessibilityLabel(for: summary, now: now)

        XCTAssertTrue(label.hasPrefix("Auth refactor plan, "))
        XCTAssertTrue(label.contains("2 comments"))
        XCTAssertTrue(
            label.hasSuffix("Couldn’t update. The download did not finish."),
            "last, because it is the least of what the row says: \(label)"
        )
    }

    func testACommentCountOfZeroIsNotAnnounced() {
        let summary = AppUITestSamples.summary(addedAt: now, commentCount: 0)
        XCTAssertFalse(LibraryFormat.accessibilityLabel(for: summary, now: now).contains("comment"))
    }

    func testOneCommentIsSingular() {
        let summary = AppUITestSamples.summary(addedAt: now, commentCount: 1)
        XCTAssertTrue(LibraryFormat.accessibilityLabel(for: summary, now: now).contains("1 comment,")
            || LibraryFormat.accessibilityLabel(for: summary, now: now).hasSuffix("1 comment"))
    }
}
