//
//  SyncFolderAccessTests.swift
//  SyncTests
//
//  Folder preparation, bookmarks and the balance of the security scope.
//
//  A temp directory is not security-scoped, so
//  `startAccessingSecurityScopedResource()` returns false throughout. That is
//  the case these tests exist to pin down: false must mean "no scope needed",
//  not "access denied", or the App Group path and every test in this target
//  break.
//

import XCTest
import Foundation
import Core
@testable import Sync

final class SyncFolderAccessTests: XCTestCase {

    func testPrepareFolderCreatesInboxAndOutbox() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        let folder = try SyncFolderAccess().prepareFolder(at: base)

        XCTAssertEqual(folder.rootURL, base)
        XCTAssertEqual(folder.inboxURL.lastPathComponent, SyncFolder.inboxDirectoryName)
        XCTAssertEqual(folder.outboxURL.lastPathComponent, SyncFolder.outboxDirectoryName)
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.inboxURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.outboxURL.path))
    }

    func testPrepareFolderIsIdempotent() throws {
        let temp = try SyncTemporaryFolder()
        defer { temp.removeAll() }

        XCTAssertNoThrow(try SyncFolderAccess().prepareFolder(at: temp.rootURL))
        XCTAssertNoThrow(try SyncFolderAccess().prepareFolder(at: temp.rootURL))
    }

    func testPreparingAFolderThatIsNotThereFails() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("not-there", isDirectory: true)

        XCTAssertThrowsError(try SyncFolderAccess().prepareFolder(at: missing)) { error in
            XCTAssertTrue(error is PencilLoopError)
        }
    }

    func testWithAccessReturnsTheBodysValueAndBalancesTheScope() throws {
        let temp = try SyncTemporaryFolder()
        defer { temp.removeAll() }
        let access = SyncFolderAccess()

        let name = try access.withAccess(to: temp.folder) { scoped in
            scoped.inboxURL.lastPathComponent
        }

        XCTAssertEqual(name, SyncFolder.inboxDirectoryName)
        // A second call proves the first one did not leave a scope open in a
        // state that refuses the next.
        XCTAssertNoThrow(try access.withAccess(to: temp.folder) { _ in })
    }

    func testWithAccessClosesTheScopeWhenTheBodyThrows() throws {
        let temp = try SyncTemporaryFolder()
        defer { temp.removeAll() }
        let access = SyncFolderAccess()

        XCTAssertThrowsError(
            try access.withAccess(to: temp.folder) { _ in
                throw PencilLoopError.bundleBuildFailed(reason: "on purpose")
            }
        )
        XCTAssertNoThrow(try access.withAccess(to: temp.folder) { _ in })
    }

    func testIsReachableAnswersHonestly() throws {
        let temp = try SyncTemporaryFolder()
        let access = SyncFolderAccess()

        XCTAssertTrue(access.isReachable(temp.folder))
        temp.removeAll()
        XCTAssertFalse(access.isReachable(temp.folder))
    }

    func testEndAccessDoesNothingWhenNothingWasStarted() throws {
        let temp = try SyncTemporaryFolder()
        defer { temp.removeAll() }
        let access = SyncFolderAccess()

        // The whole point: a plain file URL never opened a scope, and stopping
        // one that was never started is what corrupts the count.
        let started = access.beginAccess(to: temp.folder)
        access.endAccess(to: temp.folder, wasStarted: started)
        XCTAssertTrue(access.isReachable(temp.folder))
    }

    func testResolvingRubbishIsFolderUnavailable() {
        let rubbish = Data("this is not a bookmark".utf8)

        XCTAssertThrowsError(try SyncFolderAccess().resolveFolder(bookmark: rubbish)) { error in
            guard let known = error as? PencilLoopError, case .folderUnavailable = known else {
                return XCTFail("expected .folderUnavailable, got \(error)")
            }
        }
    }

    func testABookmarkRoundTrips() throws {
        let temp = try SyncTemporaryFolder()
        defer { temp.removeAll() }
        let access = SyncFolderAccess()
        let prepared = try access.prepareFolder(at: temp.rootURL)
        let bookmark = try XCTUnwrap(prepared.bookmark)

        let resolved = try access.resolveFolder(bookmark: bookmark)

        XCTAssertEqual(resolved.rootURL.standardizedFileURL, temp.rootURL.standardizedFileURL)
        XCTAssertEqual(resolved.displayName, temp.rootURL.lastPathComponent)
    }

    func testEnsureDirectoriesRecreatesWhatAProviderRemoved() throws {
        let temp = try SyncTemporaryFolder()
        defer { temp.removeAll() }
        try FileManager.default.removeItem(at: temp.folder.inboxURL)

        try SyncFolderAccess().ensureDirectories(in: temp.folder)

        XCTAssertTrue(FileManager.default.fileExists(atPath: temp.folder.inboxURL.path))
    }
}
