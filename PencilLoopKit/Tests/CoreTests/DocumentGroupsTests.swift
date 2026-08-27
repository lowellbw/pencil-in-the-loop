//
//  DocumentGroupsTests.swift
//  CoreTests
//
//  The rules a group name obeys, and the four transforms the settings store
//  applies through them (docs/02-spec.md § S1).
//
//  A group is identified by its name and by nothing else, so every question
//  worth asking here is about when two names are the same name. The display
//  spelling is a separate question from the matching key, and the tests below
//  keep the two apart on purpose: a user who types "attention papers" should
//  join the group already on screen without renaming it.
//

import Foundation
import XCTest
import Core

final class DocumentGroupsTests: XCTestCase {

    private typealias Groups = AppSettings.DocumentGroups

    // MARK: - Names

    func testAWholeNameSurvivesUntouched() {
        XCTAssertEqual(Groups.normalised("Attention Papers"), "Attention Papers")
    }

    func testSurroundingAndRepeatedWhitespaceIsCollapsed() {
        XCTAssertEqual(
            Groups.normalised("  Attention   Papers\n"),
            "Attention Papers",
            "A trailing space is the commonest way to mint a second group by accident."
        )
    }

    func testANameOfNothingButSpacesIsNoGroupRatherThanAnEmptyOne() {
        XCTAssertNil(Groups.normalised("   "))
        XCTAssertNil(Groups.normalised(""))
        XCTAssertNil(Groups.normalised(nil))
    }

    func testAControlCharacterIsRefused() {
        XCTAssertNil(Groups.normalised("Attention\u{0}Papers"))
    }

    func testAnOverLongNameIsShortenedRatherThanRefused() {
        let long = String(repeating: "a", count: Groups.maximumNameCharacters + 40)
        let normalised = Groups.normalised(long)

        XCTAssertEqual(
            normalised?.count,
            Groups.maximumNameCharacters,
            "A truncated heading is visible and fixable; a document that silently arrives ungrouped is not."
        )
    }

    // MARK: - What counts as the same group

    func testCaseAccentsAndPunctuationDoNotMakeASecondGroup() {
        let filed = Groups()
            .setting("Attention Papers", forFolderName: "a")
            .setting("attention papers", forFolderName: "b")
            .setting("Attention-Papers", forFolderName: "c")

        XCTAssertEqual(filed.sortedNames, ["Attention Papers"])
        XCTAssertEqual(
            filed.name(forFolderName: "b"),
            "Attention Papers",
            "Joining a group must not rename it out from under the documents already in it."
        )
    }

    func testTwoDifferentSubjectsStayTwoGroups() {
        let filed = Groups()
            .setting("ML Papers", forFolderName: "a")
            .setting("Machine Learning Papers", forFolderName: "b")

        XCTAssertEqual(
            filed.sortedNames.count,
            2,
            "Typographic variance is this type's job; deciding that two subjects are one is not."
        )
    }

    func testANameInAScriptWithNoASCIIFormKeepsItsOwnGroup() {
        let filed = Groups()
            .setting("注意機構の論文", forFolderName: "a")
            .setting("Θεωρία παιγνίων", forFolderName: "b")

        XCTAssertEqual(
            filed.sortedNames.count,
            2,
            "Folding, not transliterating — a rule that strips to ASCII merges every such name into one group."
        )
    }

    /// The same table `GroupKeyAgreementTests` asserts in Python.
    ///
    /// One matching rule, three implementations — this one, the MCP server's
    /// `group_key`, and the skill script's. `integrations/mcp-server/README.md`
    /// records what it cost to implement the slug rules twice and never diff
    /// them; this is the diff the slugs never got. Change a case here and change
    /// it in `scripts/test_send_to_reader.py` in the same commit.
    func testTheMatchingRuleAgreesWithTheOneTheSendersUse() {
        let cases: [(String, String)] = [
            ("Attention Papers", "attention papers"),
            ("attention papers", "attention papers"),
            ("Attention-Papers", "attention papers"),
            ("  Attention   Papers  ", "attention papers"),
            ("Áttention Papers", "attention papers"),
            ("Q3 Planning", "q3 planning"),
            ("ML Papers", "ml papers"),
            ("Machine Learning Papers", "machine learning papers"),
            ("注意機構の論文", "注意機構の論文"),
            ("!!!", "")
        ]

        for (name, expected) in cases {
            XCTAssertEqual(Groups.matchingKey(for: name), expected, name)
        }
    }

    // MARK: - Filing

    func testClearingTakesADocumentOutOfItsGroup() {
        let filed = Groups()
            .setting("Attention Papers", forFolderName: "a")
            .setting(nil, forFolderName: "a")

        XCTAssertNil(filed.name(forFolderName: "a"))
        XCTAssertEqual(filed.sortedNames, [], "A group nothing is in is not a group.")
    }

    func testASenderMayFileADocumentItHasNotSeenBefore() {
        let filed = Groups().adopting("Attention Papers", forFolderName: "a")

        XCTAssertEqual(filed.name(forFolderName: "a"), "Attention Papers")
    }

    func testASenderMayNotMoveADocumentTheUserHasFiled() {
        let filed = Groups()
            .setting("Q3 Planning", forFolderName: "a")
            .adopting("Attention Papers", forFolderName: "a")

        XCTAssertEqual(
            filed.name(forFolderName: "a"),
            "Q3 Planning",
            "A re-send must not drag a document back into the sender's group."
        )
    }

    func testASenderThatNamesNoGroupCannotUnGroupAnything() {
        let filed = Groups()
            .setting("Q3 Planning", forFolderName: "a")
            .adopting(nil, forFolderName: "a")

        XCTAssertEqual(filed.name(forFolderName: "a"), "Q3 Planning")
    }

    // MARK: - Renaming

    func testRenamingMovesEveryDocumentInTheGroupAndNothingElse() {
        let filed = Groups()
            .setting("Attention Papers", forFolderName: "a")
            .setting("Attention Papers", forFolderName: "b")
            .setting("Q3 Planning", forFolderName: "c")
            .renaming("Attention Papers", to: "Transformers")

        XCTAssertEqual(filed.name(forFolderName: "a"), "Transformers")
        XCTAssertEqual(filed.name(forFolderName: "b"), "Transformers")
        XCTAssertEqual(filed.name(forFolderName: "c"), "Q3 Planning")
    }

    func testRenamingOntoAnExistingNameMergesTheTwo() {
        let filed = Groups()
            .setting("ML Papers", forFolderName: "a")
            .setting("Machine Learning Papers", forFolderName: "b")
            .renaming("ML Papers", to: "Machine Learning Papers")

        XCTAssertEqual(
            filed.sortedNames,
            ["Machine Learning Papers"],
            "When a group is its name, two groups with one name are one group."
        )
    }

    func testRenamingAGroupNothingIsFiledUnderChangesNothing() {
        let filed = Groups().setting("Q3 Planning", forFolderName: "a")

        XCTAssertEqual(filed.renaming("Attention Papers", to: "Transformers"), filed)
    }

    func testANewNameThatIsNoNameLeavesEverythingWhereItIs() {
        let filed = Groups().setting("Q3 Planning", forFolderName: "a")

        XCTAssertEqual(
            filed.renaming("Q3 Planning", to: "   "),
            filed,
            "A rename that cannot be spelled must not un-group what it was renaming."
        )
    }

    // MARK: - Section order

    func testGroupsNobodyHasPlacedAreAlphabetical() {
        let filed = Groups()
            .setting("Zoning", forFolderName: "a")
            .setting("Attention Papers", forFolderName: "b")

        XCTAssertEqual(filed.orderedNames, ["Attention Papers", "Zoning"])
    }

    func testAPlacedGroupComesBeforeTheAlphabet() {
        let filed = Groups()
            .setting("Zoning", forFolderName: "a")
            .setting("Attention Papers", forFolderName: "b")
            .reordering(["Zoning"])

        XCTAssertEqual(
            filed.orderedNames,
            ["Zoning", "Attention Papers"],
            "A group somebody dragged outranks one nobody has touched."
        )
    }

    func testTheOrderSurvivesARename() {
        let filed = Groups()
            .setting("Attention Papers", forFolderName: "a")
            .setting("Zoning", forFolderName: "b")
            .reordering(["Zoning", "Attention Papers"])
            .renaming("Zoning", to: "Planning")

        XCTAssertEqual(
            filed.orderedNames,
            ["Planning", "Attention Papers"],
            "The order is stored as keys, so renaming a group does not send it back to the alphabet."
        )
    }

    func testAPlaceIsKeptForAGroupThatIsEmptiedAndFilledAgain() {
        let placed = Groups()
            .setting("Zoning", forFolderName: "a")
            .setting("Attention Papers", forFolderName: "b")
            .reordering(["Zoning", "Attention Papers"])

        let emptied = placed.setting(nil, forFolderName: "a")
        XCTAssertEqual(emptied.orderedNames, ["Attention Papers"], "an empty group is not a group")

        let refilled = emptied.setting("Zoning", forFolderName: "c")
        XCTAssertEqual(
            refilled.orderedNames,
            ["Zoning", "Attention Papers"],
            "and it comes back where it was put, not where the alphabet would put it."
        )
    }

    func testReorderingAnUnusableNameChangesNothing() {
        let filed = Groups().setting("Attention Papers", forFolderName: "a")

        XCTAssertEqual(filed.reordering(["!!!"]).orderedNames, ["Attention Papers"])
    }

    func testAnOrderWrittenInAShapeThisBuildCannotReadIsIgnored() throws {
        let json = Data(#"{"assignments": {"a": "Zoning"}, "order": 7}"#.utf8)

        let decoded = try JSONDecoder().decode(AppSettings.DocumentGroups.self, from: json)

        XCTAssertEqual(decoded.assignments, ["a": "Zoning"], "a bad order costs the arrangement only")
        XCTAssertEqual(decoded.order, [])
    }

    // MARK: - Pruning

    func testPruningDropsOnlyDocumentsTheLibraryNoLongerHolds() {
        let filed = Groups()
            .setting("Attention Papers", forFolderName: "a")
            .setting("Q3 Planning", forFolderName: "b")
            .pruned(keeping: ["a"])

        XCTAssertEqual(filed.assignments, ["a": "Attention Papers"])
    }

    // MARK: - Ordering

    func testGroupsAreListedTheWayASidebarReadsThem() {
        let filed = Groups()
            .setting("Zoning", forFolderName: "a")
            .setting("attention papers", forFolderName: "b")
            .setting("Q3 Planning", forFolderName: "c")

        XCTAssertEqual(filed.sortedNames, ["attention papers", "Q3 Planning", "Zoning"])
    }

    // MARK: - Decoding

    func testAGroupMapWrittenInAShapeThisBuildCannotReadIsEmptyRatherThanAThrow() throws {
        // The whole point of the hand-written `init(from:)`. A throw here is
        // caught by `AppSettingsStore.load` as `AppSettings.initial`, which
        // costs the user the sync folder they chose.
        let json = Data(#"{"assignments": "not a map"}"#.utf8)

        let decoded = try JSONDecoder().decode(AppSettings.DocumentGroups.self, from: json)

        XCTAssertEqual(decoded, .empty)
    }

    func testAGroupMapRoundTrips() throws {
        let filed = Groups().setting("Attention Papers", forFolderName: "a")

        let data = try JSONEncoder().encode(filed)
        let decoded = try JSONDecoder().decode(AppSettings.DocumentGroups.self, from: data)

        XCTAssertEqual(decoded, filed)
    }
}
