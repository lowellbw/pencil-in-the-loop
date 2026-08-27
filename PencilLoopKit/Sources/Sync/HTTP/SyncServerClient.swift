//
//  SyncServerClient.swift
//  Sync · HTTP
//
//  The relay, as the rest of Sync sees it: a base URL, a bearer token, and
//  **one** place where an HTTP status becomes a `PencilLoopError`.
//
//  ─── WHY THE STATUS TABLE IS A PURE FUNCTION ─────────────────────────────────
//  docs/12-relay.md fixes what each code means, and every one of them has to
//  land on a case the app already models — `LibraryModel` and `ReviewSheetModel`
//  switch exhaustively over `SyncEvent`, and no new error case is being added
//  for a word (the plan, § 7). So the whole table is `failure(forStatusCode:in:)`,
//  it takes no network, and `SyncServerClientTests` can walk every row of it.
//
//  The shape of the table:
//
//    · unreachable, 5xx, 408, 429, 503 → `.folderUnavailable`. Transient. The
//      poll retries, the queue holds, and every pinned document opens exactly
//      as fast as it did yesterday.
//    · 401 / 403                       → `.folderUnavailable`, with a sentence
//      that names the token, because that is the one the user can act on.
//    · other 4xx on an upload          → `.outboxWriteFailed`. The review sheet
//      already offers copy, share and save for exactly this.
//    · 404 on a reply fetch            → not an error at all: there is no reply
//      yet, which is the normal state of most reviews.
//
//  Nothing here throws on a reading path. Nothing here is called from one.
//

import Foundation
import Core

/// Talks to the relay described in docs/12-relay.md.
///
/// **On failure:** every method throws `PencilLoopError` and nothing else —
/// `.folderUnavailable` for anything transient or any credential problem,
/// `.outboxWriteFailed` for an upload the server refused on its merits. A
/// failure never costs a document that is already pinned: this type is only
/// ever on the path that *acquires* documents and sends reviews, never on the
/// path that reads one (CLAUDE.md non-negotiable 1).
public struct SyncServerClient: Sendable {

    /// What the caller was trying to do, which is what decides how a 4xx reads.
    ///
    /// The same 422 means "this build sends something the server does not
    /// understand" either way; the difference is that a failed upload has a
    /// review in hand to tell the user about, and a failed fetch just means no
    /// new documents this poll.
    public enum Call: Sendable, Hashable {

        /// Reading from the relay: the change feed, a document's bytes, a
        /// reply.
        case fetch

        /// Sending to the relay: a review bundle and its files.
        case upload
    }

    /// One page of `GET /v1/changes` — documents *and* replies, which is why
    /// there is only one feed.
    public struct ChangePage: Sendable, Hashable, Decodable {

        /// A review whose `reply.md` has arrived.
        public struct Reply: Sendable, Hashable, Decodable {

            /// The document's folder name; the review bundle is
            /// `<folderName>.review`.
            public var folderName: String

            /// The relay's sequence number for the reply.
            public var seq: Int64

            public init(folderName: String, seq: Int64) {
                self.folderName = folderName
                self.seq = seq
            }

            private enum CodingKeys: String, CodingKey {
                case folderName, seq
            }

            public init(from decoder: any Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                folderName = try container.decodeIfPresent(String.self, forKey: .folderName) ?? ""
                seq = try container.decodeIfPresent(Int64.self, forKey: .seq) ?? 0
            }
        }

        /// Changes when the relay rebuilds its index. A device that sees an
        /// unfamiliar epoch resets its cursor and re-lists — which costs a
        /// re-list of documents it mostly already has pinned, and nothing else.
        public var epoch: String

        /// Where to resume from. Advanced only on a clean page: a duplicate is
        /// free, a miss is not.
        public var cursor: Int64

        /// True when this page hit the server's limit and there is more behind
        /// it.
        public var hasMore: Bool

        /// The documents newer than the cursor, oldest first.
        public var documents: [RemoteDocument]

        /// The replies newer than the cursor.
        public var replies: [Reply]

        public init(
            epoch: String,
            cursor: Int64,
            hasMore: Bool = false,
            documents: [RemoteDocument] = [],
            replies: [Reply] = []
        ) {
            self.epoch = epoch
            self.cursor = cursor
            self.hasMore = hasMore
            self.documents = documents
            self.replies = replies
        }

        private enum CodingKeys: String, CodingKey {
            case epoch, cursor, hasMore, documents, replies
        }

        /// Decoded with the same tolerance as `RemoteDocument`: an entry this
        /// build cannot read is dropped, never the page.
        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            func text(_ key: CodingKeys) -> String? {
                guard let value = try? container.decodeIfPresent(String.self, forKey: key) else { return nil }
                return value
            }
            func number(_ key: CodingKeys) -> Int64? {
                guard let value = try? container.decodeIfPresent(Int64.self, forKey: key) else { return nil }
                return value
            }
            func flag(_ key: CodingKeys) -> Bool? {
                guard let value = try? container.decodeIfPresent(Bool.self, forKey: key) else { return nil }
                return value
            }
            // The element type is inferred from what it is assigned to, which
            // keeps the metatype out of the signature.
            func list<Wrapped: Decodable & Sendable>(_ key: CodingKeys) -> [Wrapped] {
                guard let value = try? container.decodeIfPresent(
                    [RemoteDocument.LenientElement<Wrapped>].self,
                    forKey: key
                ) else {
                    return []
                }
                return value.compactMap(\.value)
            }

            // The relay mints the epoch as a string and the cursor as a number.
            // Both are read either way, because an envelope field that changed
            // representation would otherwise stop a device syncing entirely.
            epoch = text(.epoch) ?? number(.epoch).map { String($0) } ?? ""
            cursor = number(.cursor) ?? text(.cursor).flatMap { Int64($0) } ?? 0
            hasMore = flag(.hasMore) ?? false
            documents = list(.documents)
            replies = list(.replies)
        }
    }

    /// Where the relay lives. `https` only — checked once, where the user types
    /// it, rather than by weakening App Transport Security for the whole app.
    public var baseURL: URL

    /// The shared bearer credential. It is injected by `LiveEnvironment` from
    /// the Keychain; `Sync` never reads the Keychain and never logs this.
    public var token: String

    /// The network, or a double.
    public var transport: any SyncServerTransporting

    public init(
        baseURL: URL,
        token: String,
        transport: any SyncServerTransporting = URLSessionServerTransport()
    ) {
        self.baseURL = baseURL
        self.token = token
        self.transport = transport
    }

    // MARK: - The status table

    /// What a status code means, or nil when it means "fine".
    ///
    /// Pure, and the only place a code is interpreted. `nil` for 2xx, and for
    /// the 404 a reply fetch treats as "not yet" — that one is decided by
    /// `reply(forReviewNamed:)`, which is the only caller that can tell the
    /// difference between an absent reply and a missing document.
    public static func failure(forStatusCode statusCode: Int, in call: Call) -> PencilLoopError? {
        if (200..<300).contains(statusCode) { return nil }

        switch statusCode {
        case 401, 403:
            return .folderUnavailable(
                reason: "The access token was refused. Enter it again in Settings. "
                    + "Documents already on this iPad are unaffected."
            )
        case 408, 429:
            return .folderUnavailable(
                reason: "The server is busy. This will be retried automatically."
            )
        case 507:
            if call == .upload {
                return .outboxWriteFailed(
                    reason: "The server has run out of space, so it could not accept the review. "
                        + "It is still on this iPad, and can be shared or saved from the review sheet."
                )
            }
            return .folderUnavailable(
                reason: "The server has run out of space. This will be retried automatically."
            )
        case 500...599:
            return .folderUnavailable(
                reason: "The server is unavailable right now. This will be retried automatically."
            )
        default:
            break
        }

        if (400..<500).contains(statusCode) {
            if call == .upload {
                return .outboxWriteFailed(
                    reason: "The server would not accept the review (\(statusCode)). "
                        + "It is still on this iPad, and can be shared or saved from the review sheet."
                )
            }
            return .folderUnavailable(
                reason: "The server would not answer this request (\(statusCode))."
            )
        }
        return .folderUnavailable(
            reason: "The server answered with \(statusCode), which this app does not understand."
        )
    }

    /// What a thrown transport error means.
    ///
    /// Always `.folderUnavailable`, always transient-sounding, because from the
    /// app's point of view it always is: aeroplane mode, a captive portal and a
    /// relay being redeployed are the same event, and all three are fixed by
    /// waiting.
    public static func failure(forTransportError error: any Error) -> PencilLoopError {
        if let known = error as? PencilLoopError { return known }
        if let urlError = error as? URLError {
            return .folderUnavailable(
                reason: "The server could not be reached. \(urlError.localizedDescription)"
            )
        }
        return .folderUnavailable(
            reason: "The server could not be reached. \(error.localizedDescription)"
        )
    }

    // MARK: - Reading

    /// `GET /v1/groups` — which group each document should be filed under.
    ///
    /// A suggestion, not an instruction. The caller applies it through
    /// `DocumentGrouping.adoptGroupName`, which files a document that has no
    /// group and never overrides one the reader chose by hand.
    ///
    /// This exists because `meta.json`'s `group` is read once, at ingest: a
    /// document already in the library never sees it again, so there would
    /// otherwise be no way to file something sent last week.
    ///
    /// - Returns: folder name to group name. Empty when the relay has none,
    ///   which is the normal answer.
    /// - Throws: `.folderUnavailable`.
    public func groupAssignments() async throws -> [String: String] {
        let request = signed(.get, path: "v1/groups")
        let (data, response) = try await perform(request)
        if let failure = SyncServerClient.failure(forStatusCode: response.statusCode, in: .fetch) {
            throw failure
        }
        // A relay that predates this route answers 404, which `failure(for:)`
        // turns into a throw the caller already treats as "nothing to do".
        return (try? ContractCoding.decoder().decode(GroupAssignments.self, from: data))?.assignments ?? [:]
    }

    /// The body of `GET /v1/groups`.
    private struct GroupAssignments: Decodable {
        let assignments: [String: String]
    }

    /// `GET /v1/changes?since=<cursor>` — the only feed a device needs.
    ///
    /// - Parameter cursor: where to resume. Nil means look at everything again,
    ///   which is what pull-to-refresh does.
    /// - Throws: `.folderUnavailable`.
    public func changes(since cursor: Int64?) async throws -> ChangePage {
        let request = signed(
            .get,
            path: "v1/changes",
            query: [URLQueryItem(name: "since", value: String(cursor ?? 0))]
        )
        let (data, response) = try await perform(request)
        if let failure = SyncServerClient.failure(forStatusCode: response.statusCode, in: .fetch) {
            throw failure
        }
        do {
            return try ContractCoding.decoder().decode(ChangePage.self, from: data)
        } catch {
            throw PencilLoopError.folderUnavailable(
                reason: "The server's list of changes could not be read. \(error.localizedDescription)"
            )
        }
    }

    /// `GET /v1/documents/{folderName}/files/{name}` — straight to a file.
    ///
    /// The bytes never all exist in memory, and nothing verifies them here:
    /// checking them against the size and hash the feed declared is
    /// `RemoteDocumentPinner`'s job, because it is the type that knows what to
    /// do when they do not match.
    ///
    /// - Throws: `.folderUnavailable`.
    public func downloadDocumentFile(
        named name: String,
        inDocumentNamed folderName: String,
        to destination: URL
    ) async throws {
        let request = signed(.get, path: "v1/documents/\(folderName)/files/\(name)")
        let response: HTTPURLResponse
        do {
            response = try await transport.download(request, to: destination)
        } catch {
            throw SyncServerClient.failure(forTransportError: error)
        }
        if let failure = SyncServerClient.failure(forStatusCode: response.statusCode, in: .fetch) {
            throw failure
        }
    }

    /// `GET /v1/reviews/{folderName}/files/reply.md`.
    ///
    /// - Returns: the reply's markdown, or **nil when there is none yet** —
    ///   which is the normal state of a review nobody has answered. A 404 here
    ///   is an answer, not a failure, and treating it as one would put an error
    ///   row on every review the moment it was sent.
    /// - Throws: `.folderUnavailable` for anything else.
    public func reply(forReviewNamed folderName: String) async throws -> String? {
        let request = signed(
            .get,
            path: "v1/reviews/\(folderName)/files/\(DocumentFileNames.reply)"
        )
        let (data, response) = try await perform(request)
        if response.statusCode == 404 { return nil }
        if let failure = SyncServerClient.failure(forStatusCode: response.statusCode, in: .fetch) {
            throw failure
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw PencilLoopError.folderUnavailable(
                reason: "The reply could not be read as text."
            )
        }
        return text
    }

    // MARK: - Writing

    /// `POST` a JSON body — declaring a document or a review bundle.
    ///
    /// - Returns: the response body, which is what says which files the server
    ///   is still missing.
    /// - Throws: `.outboxWriteFailed` when the server refused it on its merits,
    ///   `.folderUnavailable` when it could not be reached.
    @discardableResult
    public func post(_ body: Data, to path: String) async throws -> Data {
        var request = signed(.post, path: path)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        let (data, response) = try await perform(request)
        if let failure = SyncServerClient.failure(forStatusCode: response.statusCode, in: .upload) {
            throw failure
        }
        return data
    }

    /// `PUT` raw bytes — one file of a declared bundle.
    ///
    /// - Throws: `.outboxWriteFailed` when the server refused it,
    ///   `.folderUnavailable` when it could not be reached.
    @discardableResult
    public func put(
        _ body: Data,
        to path: String,
        contentType: String = "application/octet-stream"
    ) async throws -> Data {
        var request = signed(.put, path: path)
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        let (data, response) = try await perform(request)
        if let failure = SyncServerClient.failure(forStatusCode: response.statusCode, in: .upload) {
            throw failure
        }
        return data
    }

    // MARK: - Requests

    /// The verbs this client uses. Spelled out so a call site cannot invent a
    /// method name in a string.
    enum Method: String, Sendable {
        case get = "GET"
        case post = "POST"
        case put = "PUT"
    }

    /// A request with the bearer credential on it.
    ///
    /// The header name is a string literal and the credential is interpolated
    /// into it; neither is ever logged, and the token is not part of the URL,
    /// so it cannot end up in an access log.
    func signed(_ method: Method, path: String, query: [URLQueryItem] = []) -> URLRequest {
        var request = URLRequest(url: SyncServerClient.url(base: baseURL, path: path, query: query))
        request.httpMethod = method.rawValue
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    /// `base` + `path` + `query`, without ever building a URL from a string
    /// that could fail to parse.
    static func url(base: URL, path: String, query: [URLQueryItem]) -> URL {
        var url = base
        for component in path.split(separator: "/") {
            url = url.appendingPathComponent(String(component), isDirectory: false)
        }
        guard query.isEmpty == false,
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url
        }
        components.queryItems = query
        return components.url ?? url
    }

    private func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            return try await transport.data(for: request)
        } catch {
            throw SyncServerClient.failure(forTransportError: error)
        }
    }
}
