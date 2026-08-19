//
//  SyncServerClientTests.swift
//  SyncTests
//
//  The status table, walked row by row, plus the feed's tolerance.
//
//  The table is the reason this file exists. Every code the relay can answer
//  with has to land on an error case the app already models — the alternative
//  is a `switch` in `LibraryModel` growing a branch it will not have — and the
//  mapping is a pure function precisely so that "what does a 429 do?" is
//  answerable without a server.
//
//  What to check by hand on device, because no test here can:
//
//    · Wrong token → the sentence names the token, and every pinned document
//      still opens as fast as it ever did.
//    · Aeroplane mode → the poll fails in seconds rather than hanging, and
//      nothing in the library shows a spinner.
//

import XCTest
import Foundation
import Core
@testable import Sync

final class SyncServerClientTests: XCTestCase {

    private let base = URL(string: "https://relay.example.com") ?? URL(fileURLWithPath: "/")

    // MARK: - The status table

    func testEverySuccessCodeIsSilent() {
        for status in [200, 201, 204, 299] {
            XCTAssertNil(SyncServerClient.failure(forStatusCode: status, in: .fetch))
            XCTAssertNil(SyncServerClient.failure(forStatusCode: status, in: .upload))
        }
    }

    func testARefusedTokenSaysSoAndIsNotFatal() throws {
        for status in [401, 403] {
            let failure = try XCTUnwrap(SyncServerClient.failure(forStatusCode: status, in: .fetch))
            guard case let .folderUnavailable(reason) = failure else {
                return XCTFail("\(status) must stay a folderUnavailable: every `guard case` in the app expects it")
            }
            XCTAssertTrue(
                reason.lowercased().contains("token"),
                "the one thing the user can act on is the token, so the sentence has to name it"
            )
        }
    }

    func testTransientServerConditionsAreRetriedRatherThanShown() throws {
        for status in [408, 429, 500, 502, 503, 504] {
            let failure = try XCTUnwrap(SyncServerClient.failure(forStatusCode: status, in: .fetch))
            guard case .folderUnavailable = failure else {
                return XCTFail("\(status) is transient and must not be reported as a lost review")
            }
        }
    }

    func testAnUploadTheServerRefusedOnItsMeritsIsAnOutboxFailure() throws {
        for status in [400, 404, 409, 422] {
            let failure = try XCTUnwrap(SyncServerClient.failure(forStatusCode: status, in: .upload))
            guard case .outboxWriteFailed = failure else {
                return XCTFail("\(status) on an upload must reach the review sheet's copy/share/save fallback")
            }
        }
    }

    func testTheSameCodeOnAFetchCostsNewDocumentsOnly() throws {
        for status in [400, 404, 409, 422] {
            let failure = try XCTUnwrap(SyncServerClient.failure(forStatusCode: status, in: .fetch))
            guard case .folderUnavailable = failure else {
                return XCTFail("\(status) on a fetch is not a review that could not be written")
            }
        }
    }

    func testAFullServerIsLoudAboutTheReviewItRefused() throws {
        let failure = try XCTUnwrap(SyncServerClient.failure(forStatusCode: 507, in: .upload))
        guard case let .outboxWriteFailed(reason) = failure else {
            return XCTFail("507 is the one that loses data if it is treated as transient")
        }
        XCTAssertTrue(reason.lowercased().contains("space"))
    }

    func testBeingUnreachableIsNeverFatal() throws {
        let failure = SyncServerClient.failure(forTransportError: URLError(.notConnectedToInternet))

        guard case .folderUnavailable = failure else {
            return XCTFail("aeroplane mode must cost new documents and nothing else")
        }
    }

    func testAPencilLoopErrorPassesThroughTheTransportMapping() throws {
        let original = PencilLoopError.outboxWriteFailed(reason: "already mapped")

        XCTAssertEqual(SyncServerClient.failure(forTransportError: original), original)
    }

    // MARK: - Request building

    func testTheBaseURLIsJoinedWithoutBuildingAURLFromAString() {
        let plain = SyncServerClient.url(base: base, path: "v1/changes", query: [])
        XCTAssertEqual(plain.absoluteString, "https://relay.example.com/v1/changes")

        let trailing = URL(string: "https://relay.example.com/pencil/") ?? base
        XCTAssertEqual(
            SyncServerClient.url(base: trailing, path: "v1/changes", query: []).absoluteString,
            "https://relay.example.com/pencil/v1/changes"
        )

        let withQuery = SyncServerClient.url(
            base: base,
            path: "v1/changes",
            query: [URLQueryItem(name: "since", value: "12")]
        )
        XCTAssertEqual(withQuery.absoluteString, "https://relay.example.com/v1/changes?since=12")
    }

    func testEveryRequestCarriesTheBearerCredential() async throws {
        let transport = SyncTestHTTPTransport()
        await transport.route("/v1/changes", json: Self.emptyPage)
        let client = SyncServerClient(baseURL: base, token: "s3cret", transport: transport)

        _ = try await client.changes(since: nil)

        let recorded = await transport.sent
        let sent = try XCTUnwrap(recorded.first)
        XCTAssertEqual(sent.bearer, "Bearer s3cret")
        XCTAssertEqual(sent.query, "since=0", "no cursor means look at everything again")
    }

    func testACursorBecomesTheSinceParameter() async throws {
        let transport = SyncTestHTTPTransport()
        await transport.route("/v1/changes", json: Self.emptyPage)
        let client = SyncServerClient(baseURL: base, token: "t", transport: transport)

        _ = try await client.changes(since: 412)

        let sent = await transport.sent
        XCTAssertEqual(sent.first?.query, "since=412")
    }

    // MARK: - Reading the feed

    func testAPageDecodesDocumentsAndReplies() async throws {
        let transport = SyncTestHTTPTransport()
        await transport.route("/v1/changes", json: """
        {
          "epoch": "9c1f",
          "cursor": 12,
          "hasMore": true,
          "documents": [
            {
              "folderName": "2026-08-19-auth-refactor-plan",
              "documentId": "F7A1C0DE-0000-4000-8000-000000000001",
              "title": "Auth refactor plan",
              "createdAt": "2026-08-19T09:00:00Z",
              "seq": 11,
              "deletedAt": null,
              "files": [
                { "name": "document.pdf", "bytes": 1024, "sha256": "aa" },
                { "name": "meta.json", "bytes": 200, "sha256": "bb" }
              ]
            }
          ],
          "replies": [ { "folderName": "2026-08-01-earlier", "seq": 12 } ]
        }
        """)
        let client = SyncServerClient(baseURL: base, token: "t", transport: transport)

        let page = try await client.changes(since: nil)

        XCTAssertEqual(page.epoch, "9c1f")
        XCTAssertEqual(page.cursor, 12)
        XCTAssertTrue(page.hasMore)
        XCTAssertEqual(page.documents.count, 1)
        XCTAssertEqual(page.documents.first?.folderName, "2026-08-19-auth-refactor-plan")
        XCTAssertEqual(page.documents.first?.files.count, 2)
        XCTAssertEqual(page.documents.first?.revision, "11")
        XCTAssertEqual(page.replies.first?.folderName, "2026-08-01-earlier")
    }

    func testAMalformedEntryCostsThatEntryAndNotThePage() async throws {
        let transport = SyncTestHTTPTransport()
        await transport.route("/v1/changes", json: """
        {
          "epoch": "9c1f",
          "cursor": 4,
          "unknownFutureKey": { "anything": true },
          "documents": [
            "this is not a document at all",
            { "folderName": "2026-08-19-good", "seq": 4, "createdAt": "the day before yesterday",
              "documentId": "not-a-uuid", "files": [ { "name": "document.pdf", "bytes": 8, "sha256": "cc" } ] }
          ],
          "replies": [ 17 ]
        }
        """)
        let client = SyncServerClient(baseURL: base, token: "t", transport: transport)

        let page = try await client.changes(since: nil)

        XCTAssertEqual(
            page.documents.map(\.folderName),
            ["2026-08-19-good"],
            "one bad row must not hide the good ones behind it"
        )
        XCTAssertNil(page.documents.first?.createdAt, "an unreadable date costs the date, not the document")
        XCTAssertNil(page.documents.first?.documentId)
        XCTAssertEqual(page.documents.first?.files.count, 1)
        XCTAssertTrue(page.replies.isEmpty)
    }

    func testAnUnreadableBodyIsTransientRatherThanFatal() async throws {
        let transport = SyncTestHTTPTransport()
        await transport.route("/v1/changes", json: "not json at all")
        let client = SyncServerClient(baseURL: base, token: "t", transport: transport)

        do {
            _ = try await client.changes(since: nil)
            XCTFail("a body that will not decode has to be reported")
        } catch let error as PencilLoopError {
            guard case .folderUnavailable = error else {
                return XCTFail("a bad body is a server problem, not a lost review")
            }
        }
    }

    func testARefusedTokenReachesTheCaller() async throws {
        let transport = SyncTestHTTPTransport(mode: .everythingFails(status: 401))
        let client = SyncServerClient(baseURL: base, token: "stale", transport: transport)

        do {
            _ = try await client.changes(since: nil)
            XCTFail("401 must be reported")
        } catch let error as PencilLoopError {
            XCTAssertTrue(error.message.lowercased().contains("token"))
        }
    }

    func testAnOfflineTransportIsFolderUnavailable() async throws {
        let transport = SyncTestHTTPTransport(mode: .offline)
        let client = SyncServerClient(baseURL: base, token: "t", transport: transport)

        do {
            _ = try await client.changes(since: nil)
            XCTFail("being offline must be reported")
        } catch let error as PencilLoopError {
            guard case .folderUnavailable = error else {
                return XCTFail("offline is the most ordinary condition there is")
            }
        }
    }

    // MARK: - Replies

    func testAReviewWithNoReplyYetIsNotAFailure() async throws {
        let transport = SyncTestHTTPTransport()
        let client = SyncServerClient(baseURL: base, token: "t", transport: transport)

        let reply = try await client.reply(forReviewNamed: "2026-08-19-unanswered")

        XCTAssertNil(
            reply,
            "most reviews have no reply for twenty minutes; a 404 here is an answer, not an error"
        )
    }

    func testAReplyComesBackAsMarkdown() async throws {
        let transport = SyncTestHTTPTransport()
        await transport.route(
            "/v1/reviews/2026-08-19-answered/files/reply.md",
            bytes: Data("# Thanks\n\nAll three applied.\n".utf8)
        )
        let client = SyncServerClient(baseURL: base, token: "t", transport: transport)

        let reply = try await client.reply(forReviewNamed: "2026-08-19-answered")

        XCTAssertEqual(reply, "# Thanks\n\nAll three applied.\n")
    }

    // MARK: - Downloading and uploading

    func testADownloadWritesTheBytesAndReportsAFailedOne() async throws {
        let temp = try SyncTemporaryFolder()
        defer { temp.removeAll() }
        let transport = SyncTestHTTPTransport()
        await transport.route(
            "/v1/documents/2026-08-19-doc/files/document.pdf",
            bytes: Data("%PDF-1.4 pretend".utf8)
        )
        let client = SyncServerClient(baseURL: base, token: "t", transport: transport)
        let destination = temp.pinnedRootURL.appendingPathComponent("document.pdf")

        try await client.downloadDocumentFile(
            named: "document.pdf",
            inDocumentNamed: "2026-08-19-doc",
            to: destination
        )
        XCTAssertEqual(temp.text(at: destination), "%PDF-1.4 pretend")

        await transport.set(mode: .everythingFails(status: 503))
        do {
            try await client.downloadDocumentFile(
                named: "document.pdf",
                inDocumentNamed: "2026-08-19-doc",
                to: destination
            )
            XCTFail("a 503 download must be reported")
        } catch let error as PencilLoopError {
            guard case .folderUnavailable = error else {
                return XCTFail("a redeploy is transient")
            }
        }
        XCTAssertEqual(
            temp.text(at: destination),
            "%PDF-1.4 pretend",
            "a failed re-download must not replace a good file with an error page"
        )
    }

    func testAnUploadTheServerRejectsBecomesAnOutboxFailure() async throws {
        let transport = SyncTestHTTPTransport(mode: .everythingFails(status: 422))
        let client = SyncServerClient(baseURL: base, token: "t", transport: transport)

        do {
            _ = try await client.post(Data("{}".utf8), to: "v1/documents/2026-08-19-doc/review")
            XCTFail("422 must be reported")
        } catch let error as PencilLoopError {
            guard case .outboxWriteFailed = error else {
                return XCTFail("a manifest mismatch is a review that did not land")
            }
        }
        let sent = await transport.sent
        XCTAssertEqual(sent.first?.method, "POST")
    }

    func testAPutCarriesItsBytesAndItsCredential() async throws {
        let transport = SyncTestHTTPTransport()
        await transport.route("/v1/reviews/2026-08-19-doc/files/ink/page-01.png", json: "{}")
        let client = SyncServerClient(baseURL: base, token: "t", transport: transport)

        _ = try await client.put(
            Data(repeating: 7, count: 64),
            to: "v1/reviews/2026-08-19-doc/files/ink/page-01.png",
            contentType: "image/png"
        )

        let recorded = await transport.sent
        let sent = try XCTUnwrap(recorded.first)
        XCTAssertEqual(sent.method, "PUT")
        XCTAssertEqual(sent.bodyByteCount, 64)
        XCTAssertEqual(sent.bearer, "Bearer t")
    }

    // MARK: - Fixtures

    private static let emptyPage = """
    { "epoch": "9c1f", "cursor": 0, "hasMore": false, "documents": [], "replies": [] }
    """
}
