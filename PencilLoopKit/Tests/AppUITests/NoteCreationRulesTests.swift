//
//  NoteCreationRulesTests.swift
//  AppUITests
//
//  The one rule on the new-document sheet, as opposed to the layout.
//
//  Views are not tested in this target as a rule, and the sheet's appearance
//  was checked by rendering it and looking at it. Whether the Create button is
//  live is not an appearance question though: it decides whether an empty
//  document can be made, and a typed document cannot be edited afterwards, so
//  an empty one is a row that can never become anything.
//

import XCTest
@testable import AppUI

final class NoteCreationRulesTests: XCTestCase {

    /// Blank paper with no title is an ordinary thing to want.
    func testANotebookCanAlwaysBeCreated() {
        XCTAssertTrue(NoteCreationView.canCreate(kind: .notebook, markdown: ""))
    }

    func testAWrittenDocumentNeedsWords() {
        XCTAssertFalse(NoteCreationView.canCreate(kind: .written, markdown: ""))
        XCTAssertTrue(NoteCreationView.canCreate(kind: .written, markdown: "# Notes"))
    }

    /// Whitespace is not words. Without this, pressing Create after tapping
    /// into the field and hitting return makes a document with one empty page.
    func testWhitespaceAloneIsNotEnough() {
        XCTAssertFalse(NoteCreationView.canCreate(kind: .written, markdown: "   \n\t\n  "))
    }
}
