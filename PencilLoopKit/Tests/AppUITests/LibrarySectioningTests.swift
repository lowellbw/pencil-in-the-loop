//
//  LibrarySectioningTests.swift
//  AppUITests
//
//  Which section each row is drawn in, in both grouping modes
//  (docs/02-spec.md § S1).
//
//  The invariant every test here circles is that a row is drawn exactly once.
//  It was already true of pinning, and grouping had to keep it true against a
//  second sectioning built from the same rows — a row in two sections is a row
//  you can tap twice, with a selection highlighting in two places at once.
//
//  `@MainActor` because AppUI is compiled with `.defaultIsolation(MainActor.self)`
//  (Package.swift § AppUI), so building a model is a main-actor act.
//

import Foundation
import XCTest
@testable import AppUI
import Core

@MainActor
final class LibrarySectioningTests: XCTestCase {

    // MARK: - Fixtures

    private func summary(
        _ ordinal: Int,
        title: String,
        state: DocState = .unread,
        isPinned: Bool = false
    ) -> DocumentSummary {
        DocumentSummary(
            id: AppUITestSamples.id(ordinal),
            title: title,
            originDisplayName: "Cowork",
            addedAt: Date(timeIntervalSince1970: 1_787_000_000 + Double(ordinal)),
            pageCount: 4,
            state: state,
            localState: .local,
            commentCount: 0,
            hasInk: false,
            folderName: "folder-\(ordinal)",
            isPinned: isPinned
        )
    }

    private func model(
        _ summaries: [DocumentSummary],
        filed: [String: String] = [:]
    ) -> LibraryModel {
        var settings = AppSettings.initial
        settings.documentGroups = AppSettings.DocumentGroups(assignments: filed)
        return LibraryModel(
            environment: PreviewEnvironment(summaries: summaries, settings: settings)
        )
    }

    // MARK: - Status mode is untouched

    func testStatusModeDrawsTheSectionsItAlwaysHas() async {
        let model = model([
            summary(1, title: "Unread one"),
            summary(2, title: "Reviewing one", state: .reviewing),
            summary(3, title: "Read one", state: .read)
        ])

        await model.load()

        XCTAssertEqual(model.grouping, .status, "Status is the default, and grouping is opt-in.")
        XCTAssertEqual(model.rows(in: .unread).map(\.title), ["Unread one"])
        XCTAssertEqual(model.rows(in: .reviewing).map(\.title), ["Reviewing one"])
        XCTAssertEqual(model.rows(in: .read).map(\.title), ["Read one"])
    }

    func testGroupingChangesNothingAboutTheStatusSections() async {
        let model = model(
            [summary(1, title: "Attention Is All You Need")],
            filed: ["folder-1": "Attention Papers"]
        )

        await model.load()

        XCTAssertEqual(
            model.rows(in: .unread).map(\.title),
            ["Attention Is All You Need"],
            "A group is a place, not a state — filing a document does not move it out of Unread."
        )
    }

    // MARK: - Group mode

    func testEachGroupGetsASectionAndTheRestFallToUngrouped() async {
        let model = model(
            [
                summary(1, title: "Attention Is All You Need"),
                summary(2, title: "FlashAttention"),
                summary(3, title: "Auth refactor plan")
            ],
            filed: [
                "folder-1": "Attention Papers",
                "folder-2": "Attention Papers"
            ]
        )

        await model.load()

        XCTAssertEqual(model.sections.map(\.displayName), ["Attention Papers", "Ungrouped"])
        XCTAssertEqual(model.sections.first?.rows.count, 2)
        XCTAssertEqual(model.sections.last?.rows.map(\.title), ["Auth refactor plan"])
    }

    func testUngroupedIsLastEvenWhenItsNameWouldSortFirst() async {
        let model = model(
            [summary(1, title: "One"), summary(2, title: "Two")],
            filed: ["folder-1": "Zoning"]
        )

        await model.load()

        XCTAssertEqual(
            model.sections.map(\.displayName),
            ["Zoning", "Ungrouped"],
            "Ungrouped is the residue rather than a group, so it does not join the alphabet."
        )
    }

    func testUngroupedDoesNotAppearWhenEverythingIsFiled() async {
        let model = model(
            [summary(1, title: "One")],
            filed: ["folder-1": "Attention Papers"]
        )

        await model.load()

        XCTAssertEqual(model.sections.map(\.displayName), ["Attention Papers"])
    }

    func testGroupsAreOrderedTheWayASidebarReadsThem() async {
        let model = model(
            [summary(1, title: "One"), summary(2, title: "Two"), summary(3, title: "Three")],
            filed: [
                "folder-1": "Zoning",
                "folder-2": "attention papers",
                "folder-3": "Q3 Planning"
            ]
        )

        await model.load()

        XCTAssertEqual(
            model.sections.map(\.displayName),
            ["attention papers", "Q3 Planning", "Zoning"]
        )
    }

    // MARK: - Drawn exactly once

    func testAPinnedDocumentIsDrawnInPinnedAndInNoGroupSection() async {
        let model = model(
            [
                summary(1, title: "Attention Is All You Need", isPinned: true),
                summary(2, title: "FlashAttention")
            ],
            filed: [
                "folder-1": "Attention Papers",
                "folder-2": "Attention Papers"
            ]
        )

        await model.load()

        XCTAssertEqual(model.pinned.map(\.title), ["Attention Is All You Need"])
        XCTAssertEqual(
            model.sections.first?.rows.map(\.title),
            ["FlashAttention"],
            "The Pinned invariant has to survive the second sectioning, or a row appears twice."
        )
        XCTAssertEqual(model.rows(in: .unread).map(\.title), ["FlashAttention"])
    }

    func testAnArchivedDocumentIsDrawnNowhereAtAll() async {
        let model = model(
            [summary(1, title: "Old thing", state: .archived)],
            filed: ["folder-1": "Attention Papers"]
        )

        await model.load()

        XCTAssertEqual(model.sections, [])
        XCTAssertEqual(model.pinned, [])
    }

    // MARK: - The row's group, and the menu's

    func testARowCarriesTheGroupItIsFiledUnder() async {
        let model = model(
            [summary(1, title: "One"), summary(2, title: "Two")],
            filed: ["folder-1": "Attention Papers"]
        )

        await model.load()

        XCTAssertEqual(model.summary(id: AppUITestSamples.id(1))?.groupName, "Attention Papers")
        XCTAssertNil(model.summary(id: AppUITestSamples.id(2))?.groupName)
    }

    func testTheGroupMenuDoesNotShrinkWhileTheUserIsSearching() async {
        let model = model(
            [summary(1, title: "Attention Is All You Need"), summary(2, title: "Auth refactor plan")],
            filed: ["folder-2": "Q3 Planning"]
        )
        model.searchText = "Attention"

        await model.load()

        XCTAssertEqual(model.sections.map(\.displayName), ["Ungrouped"])
        XCTAssertEqual(
            model.groupNames,
            ["Q3 Planning"],
            "The menu offers every group in the library; hiding the one being searched past would be the wrong answer."
        )
    }

    // MARK: - Switching modes

    func testSwitchingTheModeDoesNotAskTheStoreForAnything() async {
        let model = model([summary(1, title: "One")])
        await model.load()
        let before = model.reloadKey

        model.grouping = .group

        XCTAssertEqual(
            model.reloadKey,
            before,
            "Both sectionings are built from the same fetch, so flipping the picker is a re-render."
        )
    }

    // MARK: - Filing from the model

    func testFilingADocumentMovesItWithoutAReload() async {
        let model = model([summary(1, title: "One"), summary(2, title: "Two")])
        await model.load()

        await model.setGroupName("Attention Papers", forFolderName: "folder-1")

        XCTAssertEqual(model.sections.map(\.displayName), ["Attention Papers", "Ungrouped"])
        XCTAssertEqual(model.groupNames, ["Attention Papers"])
    }

    func testRenamingAGroupMovesEveryRowInIt() async {
        let model = model(
            [summary(1, title: "One"), summary(2, title: "Two")],
            filed: ["folder-1": "Attention Papers", "folder-2": "Attention Papers"]
        )
        await model.load()

        await model.renameGroup("Attention Papers", to: "Transformers")

        XCTAssertEqual(model.sections.map(\.displayName), ["Transformers"])
        XCTAssertEqual(model.sections.first?.rows.count, 2)
    }

    func testTakingADocumentOutOfAGroupEmptiesTheSection() async {
        let model = model(
            [summary(1, title: "One")],
            filed: ["folder-1": "Attention Papers"]
        )
        await model.load()

        await model.setGroupName(nil, forFolderName: "folder-1")

        XCTAssertEqual(
            model.sections.map(\.displayName),
            ["Ungrouped"],
            "A group nothing is in is not a group, so its heading goes with it."
        )
    }
}
