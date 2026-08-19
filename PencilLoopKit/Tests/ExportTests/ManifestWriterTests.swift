//
//  ManifestWriterTests.swift
//  ExportTests
//
//  `manifest.json` against contracts/schema/manifest.schema.json, and against
//  the rule the Mac-side watcher actually applies: a bundle is only acted on
//  when the manifest parses, does not say `"complete": false`, `review.md`
//  exists, and *every file the manifest lists* exists
//  (integrations/mac-watcher § Completeness).
//
//  So the list has to be exhaustive. A manifest that omits an ink PNG is a
//  review delivered before its images have finished syncing.
//

import XCTest
import Foundation
import Core
@testable import Export

final class ManifestWriterTests: XCTestCase {

    // MARK: - Completeness

    /// Every file in the bundle is listed, so the watcher waits for all of them.
    func testEveryBundleFileIsListed() {
        let manifest = Self.writer().manifest(
            files: Self.files,
            documentId: ExportTestFixtures.externalDocumentId,
            reviewFolder: Self.reviewFolder,
            createdAt: ExportTestFixtures.reviewedAt
        )
        XCTAssertEqual(
            manifest.files.map { $0.path },
            ["ink/page-01.png", "ink/page-03.png", "review.json", "review.md"]
        )
    }

    /// `manifest.json` cannot list its own hash, so it does not list itself —
    /// and the watcher does not need it to, because it reads the file to get
    /// the list in the first place.
    func testTheManifestDoesNotListItself() {
        let withSelf = Self.files + [BundleFile(relativePath: "manifest.json", data: Data([0]))]
        let manifest = Self.writer().manifest(
            files: withSelf,
            documentId: "id",
            reviewFolder: Self.reviewFolder,
            createdAt: ExportTestFixtures.reviewedAt
        )
        XCTAssertFalse(manifest.files.contains { $0.path == BundleManifest.fileName })
    }

    func testFilesAreSortedByPath() {
        let shuffled: [BundleFile] = [
            BundleFile(relativePath: "review.md", data: Data([1])),
            BundleFile(relativePath: "ink/page-03.png", data: Data([2])),
            BundleFile(relativePath: "review.json", data: Data([3])),
            BundleFile(relativePath: "ink/page-01.png", data: Data([4]))
        ]
        let manifest = Self.writer().manifest(
            files: shuffled,
            documentId: "id",
            reviewFolder: Self.reviewFolder,
            createdAt: ExportTestFixtures.reviewedAt
        )
        XCTAssertEqual(manifest.files.map { $0.path }, manifest.files.map { $0.path }.sorted())
    }

    func testByteCountsAreExact() {
        let manifest = Self.writer().manifest(
            files: Self.files,
            documentId: "id",
            reviewFolder: Self.reviewFolder,
            createdAt: ExportTestFixtures.reviewedAt
        )
        for file in manifest.files {
            let original = Self.files.first { $0.relativePath == file.path }
            XCTAssertEqual(file.bytes, Int64(original?.data.count ?? -1))
        }
        XCTAssertEqual(manifest.totalBytes, Int64(Self.files.reduce(0) { $0 + $1.data.count }))
    }

    // MARK: - Hashes

    /// Lowercase hex, 64 characters, as the schema's pattern requires. The
    /// vector is the one everyone knows, so a wrong answer is obviously wrong.
    func testSha256IsLowercaseHexOfTheRightLength() {
        let digest = ManifestWriter.sha256Hex(Data("abc".utf8))
        XCTAssertEqual(digest, "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(digest.count, 64)
        XCTAssertEqual(digest, digest.lowercased())
    }

    func testTheEmptyFileHashesToTheEmptyDigest() {
        XCTAssertEqual(
            ManifestWriter.sha256Hex(Data()),
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        )
    }

    /// The point of the hash: a re-sent bundle is a new entry in the watcher's
    /// ledger, a re-synced one is not.
    func testChangedContentChangesTheHash() {
        let one = Self.writer().manifest(
            files: [BundleFile(relativePath: "review.md", data: Data("one".utf8))],
            documentId: "id",
            reviewFolder: Self.reviewFolder,
            createdAt: ExportTestFixtures.reviewedAt
        )
        let two = Self.writer().manifest(
            files: [BundleFile(relativePath: "review.md", data: Data("two".utf8))],
            documentId: "id",
            reviewFolder: Self.reviewFolder,
            createdAt: ExportTestFixtures.reviewedAt
        )
        XCTAssertNotEqual(one.files[0].sha256, two.files[0].sha256)
        XCTAssertEqual(one.files[0].bytes, two.files[0].bytes)
    }

    func testEveryHashMatchesTheSchemaPattern() throws {
        let object = try Self.encodedObject()
        let files = object["files"] as? [[String: Any]] ?? []
        XCTAssertFalse(files.isEmpty)
        for file in files {
            let digest = file["sha256"] as? String ?? ""
            XCTAssertEqual(digest.count, 64)
            XCTAssertTrue(digest.allSatisfy { "0123456789abcdef".contains($0) }, digest)
        }
    }

    // MARK: - Schema conformance

    func testEveryRequiredKeyIsPresent() throws {
        let object = try Self.encodedObject()
        for key in ["version", "documentId", "reviewFolder", "createdAt", "generator", "files"] {
            XCTAssertNotNil(object[key], "manifest.json is missing \(key)")
        }
        XCTAssertEqual(object["version"] as? Int, BundleManifest.currentVersion)
        XCTAssertGreaterThanOrEqual(object["version"] as? Int ?? 0, 1)
    }

    func testTheReviewFolderEndsInDotReview() throws {
        let object = try Self.encodedObject()
        let folder = object["reviewFolder"] as? String ?? ""
        XCTAssertTrue(folder.hasSuffix(OutboxPayload.reviewDirectorySuffix), folder)
    }

    func testTheDateMatchesTheFrozenFormat() throws {
        XCTAssertEqual(try Self.encodedObject()["createdAt"] as? String, "2026-08-18T21:14:00Z")
    }

    func testTheGeneratorNamesThisApp() throws {
        let generator = try Self.encodedObject()["generator"] as? [String: Any]
        XCTAssertEqual(generator?["name"] as? String, GeneratorInfo.appName)
        XCTAssertEqual(generator?["version"] as? String, "1.0")
        XCTAssertEqual(generator?["build"] as? String, "1")
    }

    /// A `build` nobody recorded is omitted, not written as null — the schema
    /// makes it optional and a null is a value.
    func testAnAbsentBuildIsOmitted() throws {
        let writer = ManifestWriter(generator: GeneratorInfo(version: "1.0"))
        let manifest = writer.manifest(
            files: Self.files,
            documentId: "id",
            reviewFolder: Self.reviewFolder,
            createdAt: ExportTestFixtures.reviewedAt
        )
        let parsed = try JSONSerialization.jsonObject(with: writer.data(for: manifest))
        let generator = (parsed as? [String: Any])?["generator"] as? [String: Any]
        XCTAssertNil(generator?["build"])
        XCTAssertFalse(generator?.keys.contains("build") ?? true)
    }

    /// A test bundle has no version info, and a manifest that cannot be written
    /// is a review that cannot be sent.
    func testAHostWithNoVersionInfoStillProducesAValidGenerator() {
        let generator = ManifestWriter.hostGenerator(bundle: Bundle(for: Self.self))
        XCTAssertEqual(generator.name, GeneratorInfo.appName)
        XCTAssertFalse(generator.version.isEmpty)
    }

    // MARK: - Determinism

    /// Two runs over the same bundle must produce the same bytes, or the
    /// checksums in a manifest mean nothing.
    func testEncodingIsDeterministic() throws {
        let writer = Self.writer()
        let manifest = writer.manifest(
            files: Self.files,
            documentId: "id",
            reviewFolder: Self.reviewFolder,
            createdAt: ExportTestFixtures.reviewedAt
        )
        XCTAssertEqual(try writer.data(for: manifest), try writer.data(for: manifest))
    }

    // MARK: - Support

    static let reviewFolder = ExportTestFixtures.folderName + OutboxPayload.reviewDirectorySuffix

    static let files: [BundleFile] = [
        BundleFile(relativePath: "review.md", data: Data("# Review\n".utf8)),
        BundleFile(relativePath: "review.json", data: Data("{}\n".utf8)),
        BundleFile(relativePath: "ink/page-01.png", data: Data([0x89, 0x50, 0x4E, 0x47])),
        BundleFile(relativePath: "ink/page-03.png", data: Data([0x89, 0x50, 0x4E, 0x47, 0x0D]))
    ]

    static func writer() -> ManifestWriter {
        ManifestWriter(generator: GeneratorInfo(version: "1.0", build: "1"))
    }

    static func encodedObject() throws -> [String: Any] {
        let writer = Self.writer()
        let manifest = writer.manifest(
            files: Self.files,
            documentId: ExportTestFixtures.externalDocumentId,
            reviewFolder: Self.reviewFolder,
            createdAt: ExportTestFixtures.reviewedAt
        )
        let parsed = try JSONSerialization.jsonObject(with: writer.data(for: manifest))
        return parsed as? [String: Any] ?? [:]
    }
}
