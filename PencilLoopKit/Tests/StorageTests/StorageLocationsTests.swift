//
//  StorageLocationsTests.swift
//  StorageTests
//
//  The path relativisation that keeps a pinned document findable after the app
//  container's absolute path changes.
//

import XCTest
import Foundation
@testable import Storage

final class StorageLocationsTests: XCTestCase {

    func testAPinnedPathIsStoredRelativeToTheDocumentsRoot() {
        let url = StorageLocations
            .documentDirectory(folderName: "2026-08-18-auth-refactor-plan")
            .appendingPathComponent("document.pdf")

        let stored = StorageLocations.storedPath(for: url)

        XCTAssertEqual(stored, "2026-08-18-auth-refactor-plan/document.pdf")
        XCTAssertFalse(stored.hasPrefix("/"), "a relative path is what survives a reinstall")
        XCTAssertEqual(
            StorageLocations.url(forStoredPath: stored)?.standardizedFileURL,
            url.standardizedFileURL
        )
    }

    func testAPathOutsideTheContainerIsStoredAbsolute() {
        let outside = URL(fileURLWithPath: "/private/var/mobile/elsewhere/document.pdf")
        let stored = StorageLocations.storedPath(for: outside)
        XCTAssertEqual(stored, "/private/var/mobile/elsewhere/document.pdf")
        XCTAssertEqual(
            StorageLocations.url(forStoredPath: stored)?.standardizedFileURL,
            outside.standardizedFileURL
        )
    }

    func testAnEmptyPathHasNoURL() {
        // A row recorded by `recordIngestFailure` has no pinned bytes, and the
        // documents root is not an honest stand-in for a document.
        XCTAssertNil(StorageLocations.url(forStoredPath: ""))
    }

    func testOnlyPathsInsideTheDocumentsRootAreDeletable() {
        let inside = StorageLocations.documentDirectory(folderName: "2026-08-18-anything")
        XCTAssertTrue(StorageLocations.isInsideDocumentsRoot(inside))
        XCTAssertFalse(StorageLocations.isInsideDocumentsRoot(URL(fileURLWithPath: "/tmp")))
        XCTAssertFalse(
            StorageLocations.isInsideDocumentsRoot(StorageLocations.documentsRoot()),
            "the root itself is never a deletion target"
        )
    }

    func testByteCountOfAWrittenFile() throws {
        let directory = StorageLocations.documentDirectory(folderName: "2026-08-18-byte-count-test")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let file = directory.appendingPathComponent("document.pdf")
        let bytes = Data(repeating: 0x41, count: 2048)
        try bytes.write(to: file)

        XCTAssertEqual(StorageLocations.fileSize(of: file), 2048)
        XCTAssertEqual(StorageLocations.byteCount(at: directory), 2048)
        XCTAssertEqual(StorageLocations.byteCount(at: directory.appendingPathComponent("missing")), 0)
    }
}
