//
//  NoteAutoTitleTests.swift
//  AppUITests
//
//  The rule that names a note nobody named.
//
//  Handwriting recognition cannot be tested here and neither can a Pencil, but
//  what a recognised page *means* for the title is a pure function of a string,
//  and it is the part that can be wrong in ways somebody would have to live
//  with: a library full of rows called "Note", or a row called "the".
//

import XCTest
@testable import AppUI

final class NoteAutoTitleTests: XCTestCase {

    func testTheFirstSentenceBecomesTheTitle() {
        XCTAssertEqual(
            NoteAutoTitle.title(fromRecognisedInk: "Cutover plan for the auth service. Ask Dan about the token."),
            "Cutover plan for the auth service"
        )
    }

    /// Handwriting frequently has no full stop anywhere in it. The line break
    /// is the sentence.
    func testALineBreakEndsASentence() {
        XCTAssertEqual(
            NoteAutoTitle.title(fromRecognisedInk: "Reading notes\nchapter one is the argument"),
            "Reading notes"
        )
    }

    /// Nothing to end on at all: the whole of a short note is the title.
    func testAShortNoteWithNoTerminatorIsTheWholeThing() {
        XCTAssertEqual(NoteAutoTitle.title(fromRecognisedInk: "Ideas for Thursday"), "Ideas for Thursday")
    }

    /// A title is not a sentence, so the full stop goes. A question mark stays,
    /// because dropping it changes what the note is about.
    func testAQuestionKeepsItsMark() {
        XCTAssertEqual(
            NoteAutoTitle.title(fromRecognisedInk: "Why is the cache cold on deploy? Two theories."),
            "Why is the cache cold on deploy?"
        )
    }

    /// Recognised handwriting arrives with the layout in it — stroke groups
    /// separated by newlines and runs of spaces.
    func testWhitespaceIsCollapsed() {
        XCTAssertEqual(
            NoteAutoTitle.title(fromRecognisedInk: "  Two   things \t worth  saying. And a third."),
            "Two things worth saying"
        )
    }

    func testAnEmptyPageNamesNothing() {
        XCTAssertNil(NoteAutoTitle.title(fromRecognisedInk: ""))
        XCTAssertNil(NoteAutoTitle.title(fromRecognisedInk: "   \n\t "))
    }

    /// One recognised character is a stray mark, and a note called "a" is worse
    /// than a note called "Note".
    func testASingleCharacterIsNotATitle() {
        XCTAssertNil(NoteAutoTitle.title(fromRecognisedInk: "a"))
    }

    func testALongSentenceIsCutAtAWordBoundary() throws {
        let long = String(repeating: "argument ", count: 20) + "and so on."
        let title = try XCTUnwrap(NoteAutoTitle.title(fromRecognisedInk: long))

        XCTAssertLessThanOrEqual(title.count, NoteAutoTitle.maximumLength)
        XCTAssertFalse(title.hasSuffix(" "), "a title that ends mid-space reads as a truncation bug")
        XCTAssertTrue(title.hasPrefix("argument argument"))
    }

    /// A page whose first line is blank, or that starts with a stray dot,
    /// should keep looking rather than stop on nothing.
    func testALeadingBlankLineIsSkipped() {
        XCTAssertEqual(
            NoteAutoTitle.title(fromRecognisedInk: "\n\nCutover plan\nthen the rest"),
            "Cutover plan"
        )
    }

    // MARK: - Whether a note has ever been named

    func testTheDefaultNameCountsAsUnnamed() {
        XCTAssertTrue(NoteAutoTitle.isUnnamed("Note", untitled: "Note"))
        XCTAssertTrue(NoteAutoTitle.isUnnamed("  note  ", untitled: "Note"))
    }

    func testAnythingElseIsANameSomebodyChose() {
        XCTAssertFalse(NoteAutoTitle.isUnnamed("Note to self", untitled: "Note"))
        XCTAssertFalse(NoteAutoTitle.isUnnamed("Cutover plan", untitled: "Note"))
    }
}
