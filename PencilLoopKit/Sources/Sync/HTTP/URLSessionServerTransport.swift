//
//  URLSessionServerTransport.swift
//  Sync · HTTP
//
//  The live transport: one `URLSession`, configured for a poll loop that must
//  fail fast and never lie about what is on disk.
//
//  Three configuration choices are decisions rather than defaults:
//
//  · **Ephemeral.** A default session caches responses on disk, and a cached
//    200 for `/v1/changes` is the same class of bug as the URL-resource caching
//    that made a scanned folder look unchanged after it had changed. The relay
//    answers authoritatively; caching its answers throws that away.
//  · **`waitsForConnectivity = false`.** In aeroplane mode a poll must fail in
//    seconds so the queue can say "will send when online". Waiting means a task
//    hanging for the resource timeout with nothing to show for it.
//  · **Not a background session.** A background `URLSession` hands transfers to
//    a system daemon and calls back into a delegate after relaunch, which is a
//    different lifecycle for the app to model. v1 does not need it: every
//    download happens while the app is in the foreground, and one that does not
//    finish is retried by the next poll.
//

import Foundation

/// `SyncServerTransporting` over a foreground `URLSession`.
///
/// **On failure:** throws the `URLError` `URLSession` threw. Timeouts are 30
/// seconds for a request to start producing and 300 for a whole resource, so a
/// large PDF on a slow connection still arrives and a dead connection does not
/// hold a poll open indefinitely.
public struct URLSessionServerTransport: SyncServerTransporting {

    private let session: URLSession

    /// - Parameters:
    ///   - requestTimeout: how long a request may stall before it is abandoned.
    ///   - resourceTimeout: how long a whole transfer may take. Generous, for
    ///     the 100MB PDF the relay's own size cap allows.
    public init(requestTimeout: TimeInterval = 30, resourceTimeout: TimeInterval = 300) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = resourceTimeout
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: configuration)
    }

    public func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        return (data, http)
    }

    public func download(_ request: URLRequest, to destination: URL) async throws -> HTTPURLResponse {
        // `download(for:)` streams to a temporary file, so the bytes never all
        // exist in memory at once. The move happens only after the transfer
        // finished, which is what lets a failed download leave the previous
        // copy alone.
        let (temporary, response) = try await session.download(for: request)
        guard let http = response as? HTTPURLResponse else {
            try? FileManager.default.removeItem(at: temporary)
            throw URLError(.badServerResponse)
        }

        let manager = FileManager.default
        guard (200..<300).contains(http.statusCode) else {
            // An error page is a body too, and writing it over the destination
            // would replace a good file with the words "not found". The status
            // still goes back — reading it is the client's job.
            try? manager.removeItem(at: temporary)
            return http
        }

        do {
            if manager.fileExists(atPath: destination.path) {
                try manager.removeItem(at: destination)
            }
            try manager.moveItem(at: temporary, to: destination)
        } catch {
            try? manager.removeItem(at: temporary)
            throw error
        }
        return http
    }
}
