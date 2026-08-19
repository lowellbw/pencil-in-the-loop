//
//  SyncTestHTTPTransport.swift
//  SyncTests
//
//  A `SyncServerTransporting` that answers from a table, so a test can say what
//  the relay replied rather than run one.
//
//  Hand-written, following `SyncTestStore`, rather than a `URLProtocol`
//  subclass. A `URLProtocol` double registers itself globally, runs on
//  URLSession's own queues, and tests the real session's caching and redirect
//  behaviour as a side effect — none of which is what these tests are about.
//  This is the seam the protocol exists for, and using it is the point.
//
//  It is an actor because the protocol is `Sendable` and the recorded requests
//  are mutable state; every assertion about what was sent is therefore an
//  `await`.
//

import Foundation
import Core
@testable import Sync

/// A relay that only exists in memory.
actor SyncTestHTTPTransport: SyncServerTransporting {

    /// What the network is doing to every request, regardless of the table.
    enum Mode: Sendable, Hashable {

        /// Answer from the route table; an unrouted path is a 404.
        case routed

        /// Throw, as aeroplane mode does.
        case offline

        /// Answer every request with this status and an error body, which is
        /// how the status table is exercised end to end.
        case everythingFails(status: Int)
    }

    /// One request as it arrived.
    struct Sent: Sendable, Hashable {
        var method: String
        var path: String
        var query: String?
        var bearer: String?
        var bodyByteCount: Int
    }

    /// Path to the status and body it answers with.
    private var routes: [String: (status: Int, body: Data)] = [:]

    /// Every request, in order.
    private(set) var sent: [Sent] = []

    /// The current failure mode.
    private(set) var mode: Mode = .routed

    init(mode: Mode = .routed) {
        self.mode = mode
    }

    // MARK: - Arranging

    /// Answers `path` with a JSON body.
    func route(_ path: String, json: String, status: Int = 200) {
        routes[path] = (status, Data(json.utf8))
    }

    /// Answers `path` with raw bytes — a document's, usually.
    func route(_ path: String, bytes: Data, status: Int = 200) {
        routes[path] = (status, bytes)
    }

    /// Stops answering `path`, which then 404s.
    func removeRoute(_ path: String) {
        routes.removeValue(forKey: path)
    }

    /// Puts the whole transport into a failure mode.
    func set(mode: Mode) {
        self.mode = mode
    }

    // MARK: - Asserting

    /// The paths that were requested, in order.
    var requestedPaths: [String] {
        sent.map(\.path)
    }

    // MARK: - SyncServerTransporting

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let answer = try record(request)
        return (answer.body, try response(for: request, status: answer.status))
    }

    func download(_ request: URLRequest, to destination: URL) async throws -> HTTPURLResponse {
        let answer = try record(request)
        let http = try response(for: request, status: answer.status)
        guard (200..<300).contains(answer.status) else { return http }
        try answer.body.write(to: destination, options: [.atomic])
        return http
    }

    // MARK: - Internals

    private func record(_ request: URLRequest) throws -> (status: Int, body: Data) {
        let components = request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }
        let path = components?.path ?? ""
        sent.append(Sent(
            method: request.httpMethod ?? "GET",
            path: path,
            query: components?.query,
            bearer: request.value(forHTTPHeaderField: "Authorization"),
            bodyByteCount: request.httpBody?.count ?? 0
        ))

        switch mode {
        case .offline:
            throw URLError(.notConnectedToInternet)
        case let .everythingFails(status):
            return (status, Data(#"{"error":"nope","message":"no"}"#.utf8))
        case .routed:
            guard let answer = routes[path] else {
                return (404, Data(#"{"error":"not_found","message":"nothing here"}"#.utf8))
            }
            return answer
        }
    }

    private func response(for request: URLRequest, status: Int) throws -> HTTPURLResponse {
        let url = request.url ?? URL(fileURLWithPath: "/")
        guard let http = HTTPURLResponse(
            url: url,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        ) else {
            throw URLError(.badServerResponse)
        }
        return http
    }
}
