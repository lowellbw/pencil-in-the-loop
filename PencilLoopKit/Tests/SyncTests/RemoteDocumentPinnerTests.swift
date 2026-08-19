//
//  RemoteDocumentPinnerTests.swift
//  SyncTests
//
//  The executable form of CLAUDE.md non-negotiable 2 for the relay transport.
//
//  The test that matters most here is not the happy path: it is that a hash
//  mismatch throws **and leaves the previously pinned copy byte-identical**. A
//  relay serving a truncated or a wrong file must cost the new revision and
//  nothing else, because the document that is already on the iPad is the one
//  the user is reading on a plane.
//
//  What to check by hand on device, because no test here can:
//
//    · Pull to refresh on a real relay, then aeroplane mode: every document
//      still opens and nothing shows a spinner.
//    · Kill the app mid-download and refresh again: the document arrives whole,
//      and no `.tmp` directory is left in the container.
//

import XCTest
import Foundation
import Core
@testable import Sync

final class RemoteDocumentPinnerTests: XCTestCase {

    private let base = URL(string: "https://relay.example.com") ?? URL(fileURLWithPath: "/")

    // MARK: - The happy path

    func testEveryFileIsDownloadedVerifiedAndPinnedIntoTheContainer() async throws {
        let temp = try SyncTemporaryFolder()
        defer { temp.removeAll() }
        let pdf = Data("%PDF-1.4 pretend".utf8)
        let meta = Data(SyncTemporaryFolder.completeMetaJSON.utf8)
        let transport = SyncTestHTTPTransport()
        await serve(transport, folderName: "2026-08-19-auth", files: ["document.pdf": pdf, "meta.json": meta])
        let pinner = RemoteDocumentPinner(
            client: SyncServerClient(baseURL: base, token: "t", transport: transport),
            writer: PinnedDocumentWriter(destinationRoot: temp.pinnedRootURL)
        )
        let document = Self.document(
            folderName: "2026-08-19-auth",
            seq: 7,
            files: ["document.pdf": pdf, "meta.json": meta]
        )

        let item = try await pinner.pin(document)

        XCTAssertTrue(
            item.directoryURL.path.hasPrefix(temp.pinnedRootURL.path),
            "Ingest must never be handed a URL that points at a server"
        )
        let pdfURL = try XCTUnwrap(item.pdfURL)
        XCTAssertEqual(temp.text(at: pdfURL), "%PDF-1.4 pretend")
        XCTAssertNotNil(item.metaURL)
        XCTAssertNil(item.sourceMarkdownURL, "a file the server did not offer has no URL")
        XCTAssertEqual(item.byteCount, Int64(pdf.count + meta.count))
        let snapshot = try XCTUnwrap(pinner.writer.pinnedSnapshot(forFolderNamed: "2026-08-19-auth"))
        XCTAssertEqual(snapshot.revision, "7")
        XCTAssertEqual(snapshot.fileNames, ["document.pdf", "meta.json"])
        XCTAssertTrue(pinner.isPinnedAndCurrent(document))
        XCTAssertFalse(
            pinner.isPinnedAndCurrent(Self.document(
                folderName: "2026-08-19-auth",
                seq: 8,
                files: ["document.pdf": pdf, "meta.json": meta]
            )),
            "a new sequence number is a new revision, and it has to be fetched"
        )
        XCTAssertFalse(
            temp.names(in: temp.pinnedRootURL).contains { $0.hasPrefix(".") },
            "staging must not survive a successful pin"
        )
    }

    func testAFileTheServerOffersUnderAnUnknownNameIsSkipped() async throws {
        let temp = try SyncTemporaryFolder()
        defer { temp.removeAll() }
        let pdf = Data("%PDF-1.4 pretend".utf8)
        let transport = SyncTestHTTPTransport()
        await serve(transport, folderName: "2026-08-19-future", files: ["document.pdf": pdf])
        await transport.route(
            "/v1/documents/2026-08-19-future/files/notes.txt",
            bytes: Data("a fifth file this build has never heard of".utf8)
        )
        let pinner = RemoteDocumentPinner(
            client: SyncServerClient(baseURL: base, token: "t", transport: transport),
            writer: PinnedDocumentWriter(destinationRoot: temp.pinnedRootURL)
        )
        var document = Self.document(folderName: "2026-08-19-future", seq: 1, files: ["document.pdf": pdf])
        document.files.append(RemoteDocument.File(name: "notes.txt", bytes: 42, sha256: "ff"))

        let item = try await pinner.pin(document)

        XCTAssertEqual(
            temp.names(in: item.directoryURL).filter { $0.hasPrefix(".") == false },
            ["document.pdf"],
            "a relay that starts serving a fifth file must not break this build of the app"
        )
    }

    // MARK: - Verification

    func testAHashMismatchLeavesThePreviousPinnedCopyByteIdentical() async throws {
        let temp = try SyncTemporaryFolder()
        defer { temp.removeAll() }
        let good = Data("%PDF-1.4 the readable one".utf8)
        let transport = SyncTestHTTPTransport()
        await serve(transport, folderName: "2026-08-19-kept", files: ["document.pdf": good])
        let writer = PinnedDocumentWriter(destinationRoot: temp.pinnedRootURL)
        let pinner = RemoteDocumentPinner(
            client: SyncServerClient(baseURL: base, token: "t", transport: transport),
            writer: writer
        )
        _ = try await pinner.pin(Self.document(folderName: "2026-08-19-kept", seq: 1, files: ["document.pdf": good]))
        let pinnedPDF = writer.pinnedDirectory(forFolderNamed: "2026-08-19-kept")
            .appendingPathComponent("document.pdf")
        let before = try Data(contentsOf: pinnedPDF)

        // The server now serves different bytes than the ones it described,
        // which is what a stale proxy or a corrupted volume looks like.
        await transport.route(
            "/v1/documents/2026-08-19-kept/files/document.pdf",
            bytes: Data("%PDF-1.4 something else entirely".utf8)
        )
        var revised = Self.document(folderName: "2026-08-19-kept", seq: 2, files: ["document.pdf": good])
        revised.files = [RemoteDocument.File(
            name: "document.pdf",
            bytes: Int64("%PDF-1.4 something else entirely".utf8.count),
            sha256: RemoteDocumentPinner.sha256Hex(good)
        )]

        do {
            _ = try await pinner.pin(revised)
            XCTFail("bytes that do not match their checksum must never become a document")
        } catch let error as PencilLoopError {
            guard case let .materialisationFailed(folderName, reason) = error else {
                return XCTFail("a mismatch is a materialisation failure")
            }
            XCTAssertEqual(folderName, "2026-08-19-kept")
            XCTAssertTrue(reason.lowercased().contains("checksum"))
        }

        XCTAssertEqual(
            try Data(contentsOf: pinnedPDF),
            before,
            "a document readable a moment ago is readable now, whatever the relay is serving"
        )
        XCTAssertEqual(
            writer.pinnedSnapshot(forFolderNamed: "2026-08-19-kept")?.revision,
            "1",
            "the failed revision must not be recorded as pinned"
        )
        XCTAssertFalse(
            temp.names(in: temp.pinnedRootURL).contains { $0.hasPrefix(".") },
            "a failed pin cleans up after itself"
        )
    }

    func testAShortDownloadIsRefused() async throws {
        let temp = try SyncTemporaryFolder()
        defer { temp.removeAll() }
        let served = Data("%PDF-1.4 half of it".utf8)
        let transport = SyncTestHTTPTransport()
        await transport.route("/v1/documents/2026-08-19-short/files/document.pdf", bytes: served)
        let pinner = RemoteDocumentPinner(
            client: SyncServerClient(baseURL: base, token: "t", transport: transport),
            writer: PinnedDocumentWriter(destinationRoot: temp.pinnedRootURL)
        )
        let document = RemoteDocument(
            folderName: "2026-08-19-short",
            seq: 1,
            files: [RemoteDocument.File(
                name: "document.pdf",
                bytes: Int64(served.count) + 100,
                sha256: RemoteDocumentPinner.sha256Hex(served)
            )]
        )

        do {
            _ = try await pinner.pin(document)
            XCTFail("a short download must not become a document")
        } catch let error as PencilLoopError {
            XCTAssertTrue(error.message.lowercased().contains("short"))
        }
        XCTAssertNil(pinner.writer.pinnedSnapshot(forFolderNamed: "2026-08-19-short"))
    }

    func testAFileOfferedWithoutASizeOrHashCannotBePinned() async throws {
        let temp = try SyncTemporaryFolder()
        defer { temp.removeAll() }
        let transport = SyncTestHTTPTransport()
        await transport.route(
            "/v1/documents/2026-08-19-undeclared/files/document.pdf",
            bytes: Data("%PDF-1.4 pretend".utf8)
        )
        let pinner = RemoteDocumentPinner(
            client: SyncServerClient(baseURL: base, token: "t", transport: transport),
            writer: PinnedDocumentWriter(destinationRoot: temp.pinnedRootURL)
        )
        let document = RemoteDocument(
            folderName: "2026-08-19-undeclared",
            seq: 1,
            files: [RemoteDocument.File(name: "document.pdf")]
        )

        do {
            _ = try await pinner.pin(document)
            XCTFail("bytes nobody described cannot be verified, so they cannot be trusted")
        } catch let error as PencilLoopError {
            XCTAssertTrue(error.message.lowercased().contains("verified"))
        }
    }

    func testTheMismatchRuleIsAPureFunction() {
        let file = RemoteDocument.File(name: "document.pdf", bytes: 1024, sha256: "AB12")

        XCTAssertNil(RemoteDocumentPinner.mismatchReason(
            for: file,
            downloadedBytes: 1024,
            downloadedHash: "ab12"
        ), "a hash is hex, and its case is not part of it")
        XCTAssertNotNil(RemoteDocumentPinner.mismatchReason(
            for: file,
            downloadedBytes: 1023,
            downloadedHash: "ab12"
        ))
        XCTAssertNotNil(
            RemoteDocumentPinner.mismatchReason(
                for: file,
                downloadedBytes: 1024,
                downloadedHash: "0000"
            ),
            "the right length and the wrong bytes is exactly what a stale cache serves"
        )
        XCTAssertNotNil(RemoteDocumentPinner.mismatchReason(
            for: RemoteDocument.File(name: "document.pdf"),
            downloadedBytes: 1024,
            downloadedHash: "ab12"
        ))
    }

    // MARK: - What must never be written

    func testAFolderNameWithAPathInItIsRefusedBeforeAnythingIsWritten() async throws {
        let temp = try SyncTemporaryFolder()
        defer { temp.removeAll() }
        let transport = SyncTestHTTPTransport()
        let pinner = RemoteDocumentPinner(
            client: SyncServerClient(baseURL: base, token: "t", transport: transport),
            writer: PinnedDocumentWriter(destinationRoot: temp.pinnedRootURL)
        )

        for folderName in ["../escape", ".hidden", "", "a/b"] {
            do {
                _ = try await pinner.pin(RemoteDocument(
                    folderName: folderName,
                    seq: 1,
                    files: [RemoteDocument.File(name: "document.pdf", bytes: 1, sha256: "aa")]
                ))
                XCTFail("`\(folderName)` must never become a directory name")
            } catch let error as PencilLoopError {
                XCTAssertTrue(error.message.contains("folder name"))
            }
        }
        let requested = await transport.requestedPaths
        XCTAssertTrue(requested.isEmpty, "nothing is even downloaded for a name that will not be written")
    }

    func testADocumentWithNothingToReadIsRefused() async throws {
        let temp = try SyncTemporaryFolder()
        defer { temp.removeAll() }
        let pinner = RemoteDocumentPinner(
            client: SyncServerClient(baseURL: base, token: "t", transport: SyncTestHTTPTransport()),
            writer: PinnedDocumentWriter(destinationRoot: temp.pinnedRootURL)
        )

        do {
            _ = try await pinner.pin(RemoteDocument(
                folderName: "2026-08-19-empty",
                seq: 1,
                files: [RemoteDocument.File(name: "meta.json", bytes: 2, sha256: "aa")]
            ))
            XCTFail("a directory with only metadata is not a document")
        } catch let error as PencilLoopError {
            XCTAssertTrue(error.message.lowercased().contains("no document"))
        }
    }

    func testATombstoneIsNotSomethingToPin() async throws {
        let temp = try SyncTemporaryFolder()
        defer { temp.removeAll() }
        let pinner = RemoteDocumentPinner(
            client: SyncServerClient(baseURL: base, token: "t", transport: SyncTestHTTPTransport()),
            writer: PinnedDocumentWriter(destinationRoot: temp.pinnedRootURL)
        )

        do {
            _ = try await pinner.pin(RemoteDocument(
                folderName: "2026-08-19-deleted",
                seq: 9,
                deletedAt: Date(timeIntervalSince1970: 1_000_000),
                files: []
            ))
            XCTFail("a deletion is not a download")
        } catch let error as PencilLoopError {
            XCTAssertTrue(error.message.lowercased().contains("deleted"))
        }
    }

    // MARK: - A failure that is not the server's

    func testAnUnreachableServerLeavesNothingBehind() async throws {
        let temp = try SyncTemporaryFolder()
        defer { temp.removeAll() }
        let transport = SyncTestHTTPTransport(mode: .offline)
        let pinner = RemoteDocumentPinner(
            client: SyncServerClient(baseURL: base, token: "t", transport: transport),
            writer: PinnedDocumentWriter(destinationRoot: temp.pinnedRootURL)
        )

        do {
            _ = try await pinner.pin(RemoteDocument(
                folderName: "2026-08-19-offline",
                seq: 1,
                files: [RemoteDocument.File(name: "document.pdf", bytes: 4, sha256: "aa")]
            ))
            XCTFail("a download that never happened is not a pin")
        } catch let error as PencilLoopError {
            guard case .folderUnavailable = error else {
                return XCTFail("being offline is transient, and the next poll retries it")
            }
        }
        XCTAssertTrue(
            temp.names(in: temp.pinnedRootURL).isEmpty,
            "not even a staging directory survives a failed pin"
        )
    }

    // MARK: - Helpers

    /// Routes every file of a document at the path the client will ask for.
    private func serve(
        _ transport: SyncTestHTTPTransport,
        folderName: String,
        files: [String: Data]
    ) async {
        for (name, data) in files {
            await transport.route("/v1/documents/\(folderName)/files/\(name)", bytes: data)
        }
    }

    /// A feed entry describing exactly those bytes.
    private static func document(
        folderName: String,
        seq: Int64,
        files: [String: Data]
    ) -> RemoteDocument {
        RemoteDocument(
            folderName: folderName,
            documentId: UUID(uuidString: "F7A1C0DE-0000-4000-8000-000000000001"),
            title: "Auth refactor plan",
            createdAt: Date(timeIntervalSince1970: 1_755_000_000),
            seq: seq,
            files: files.keys.sorted().map { name in
                let data = files[name] ?? Data()
                return RemoteDocument.File(
                    name: name,
                    bytes: Int64(data.count),
                    sha256: RemoteDocumentPinner.sha256Hex(data)
                )
            }
        )
    }
}
