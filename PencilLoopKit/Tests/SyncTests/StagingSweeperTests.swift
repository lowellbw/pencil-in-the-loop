//
//  StagingSweeperTests.swift
//  SyncTests
//
//  What the sweeper is allowed to delete. It removes directories, so the
//  interesting cases are the ones it must leave alone: a real document folder, a
//  provider's own dot-file, and a staging directory that a write happening right
//  now still owns.
//

import XCTest
import Foundation
import Core
@testable import Sync

final class StagingSweeperTests: XCTestCase {

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pencil-loop-sweeper-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @discardableResult
    private func makeDirectory(named name: String, in root: URL, ageSeconds: TimeInterval) throws -> URL {
        let url = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try Data("%PDF-1.4 pretend".utf8).write(to: url.appendingPathComponent("document.pdf"))
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-ageSeconds)],
            ofItemAtPath: url.path
        )
        return url
    }

    func testAnAbandonedStagingDirectoryIsRemoved() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let staging = try makeDirectory(
            named: SyncFileNames.stagingName(for: "2026-08-18-plan", token: "4F2C"),
            in: root,
            ageSeconds: 7200
        )

        let removed = StagingSweeper.sweep(in: root)

        XCTAssertEqual(removed, 1)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: staging.path),
            "a crash mid-write must not leave a copy of a document behind for ever"
        )
    }

    func testAStagingDirectoryYoungEnoughToBeInFlightIsLeftAlone() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let staging = try makeDirectory(
            named: SyncFileNames.stagingName(for: "2026-08-18-plan", token: "4F2C"),
            in: root,
            ageSeconds: 5
        )

        let removed = StagingSweeper.sweep(in: root)

        XCTAssertEqual(removed, 0)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: staging.path),
            "somebody may be writing into it right now, here or in the share extension"
        )
    }

    func testRealDirectoriesAndOtherHiddenEntriesSurvive() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let document = try makeDirectory(named: "2026-08-18-plan", in: root, ageSeconds: 90000)
        let dsStore = root.appendingPathComponent(".DS_Store", isDirectory: false)
        try Data().write(to: dsStore)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-90000)],
            ofItemAtPath: dsStore.path
        )

        let removed = StagingSweeper.sweep(in: root)

        XCTAssertEqual(removed, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: document.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dsStore.path), "hidden is not enough to be deleted")
    }

    func testAMissingRootIsNotAFailure() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)

        XCTAssertEqual(StagingSweeper.sweep(in: missing), 0)
    }

    func testIsStagingNeedsBothHalves() {
        XCTAssertTrue(StagingSweeper.isStaging(SyncFileNames.stagingName(for: "2026-08-18-plan", token: "4F2C")))
        XCTAssertFalse(StagingSweeper.isStaging("2026-08-18-plan.tmp"), "not hidden")
        XCTAssertFalse(StagingSweeper.isStaging(".2026-08-18-plan"), "no staging suffix")
        XCTAssertFalse(StagingSweeper.isStaging(".DS_Store"))
    }
}
