//
//  DefaultSyncFolderTests.swift
//  SyncTests
//
//  The default sync folder, which is the app's own iCloud container.
//
//  There is no iCloud account in a simulator and there may not be one on a
//  device, so these tests do not assert that a folder is found. They assert the
//  contract the caller actually depends on: whichever way it goes, it goes one
//  of exactly two ways, and the failing way carries a sentence a person can
//  read. `FirstRunView` shows that sentence and then offers the picker, so a
//  third outcome — a crash, an empty message, a URL somewhere unpublished —
//  is a first run with no way out of it.
//

import XCTest
import Foundation
import Core
@testable import Sync

final class DefaultSyncFolderTests: XCTestCase {

    /// The whole fallback story, as one assertion. On a machine with iCloud it
    /// takes the first branch and on a machine without it takes the second;
    /// both are correct and neither may be anything else.
    func testLocateEitherPublishesAFolderOrExplainsWhyItCannot() throws {
        do {
            let url = try DefaultSyncFolder.locate()

            XCTAssertEqual(
                url.lastPathComponent,
                DefaultSyncFolder.publishedDirectoryName,
                "the folder has to be the published one, or the Mac never sees it"
            )
            var isDirectory: ObjCBool = false
            let exists = FileManager.default.fileExists(
                atPath: url.path(percentEncoded: false),
                isDirectory: &isDirectory
            )
            XCTAssertTrue(
                exists && isDirectory.boolValue,
                "locate() creates the directory, because prepareFolder(at:) will not"
            )
        } catch let error as PencilLoopError {
            guard case let .folderUnavailable(reason) = error else {
                return XCTFail(
                    "the caller falls back on .folderUnavailable and shows its reason; \(error) leaves it with nothing to say"
                )
            }
            XCTAssertFalse(
                reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                "an empty reason is a blank first-run screen"
            )
        }
    }

    /// `isAvailable` and `locate()` are asked at different moments — one by a
    /// status row, one by first run — and a user who reads both must not be
    /// told two different things.
    func testAvailabilityAgreesWithWhetherLocateSucceeds() {
        let available = DefaultSyncFolder.isAvailable
        let located = (try? DefaultSyncFolder.locate()) != nil
        XCTAssertEqual(
            available,
            located,
            "one of these says iCloud is there and the other says it is not"
        )
    }

    /// The name is not decorative: `NSUbiquitousContainerIsDocumentScopePublic`
    /// publishes the container's `Documents` and nothing else, so a folder made
    /// anywhere else in the container is invisible to the Mac for ever.
    func testThePublishedDirectoryIsTheOneICloudDriveActuallyShows() {
        XCTAssertEqual(DefaultSyncFolder.publishedDirectoryName, "Documents")
    }
}
