//
//  SyncServerTransporting.swift
//  Sync · HTTP
//
//  The seam a test substitutes for the network.
//
//  It lives in Sync rather than Core/Contracts on purpose. STYLE.md § 1 freezes
//  Core for names that *cross a module boundary*; nothing outside Sync ever
//  holds one of these, and nothing outside Sync should learn that a URLRequest
//  exists. This is a seam inside one module, which is a local decision.
//
//  Two methods, because there are two shapes of transfer and the difference
//  matters: a change page is small and wanted in memory, and a 100MB PDF must
//  go straight to a file and never become a `Data` sitting in an actor's
//  mailbox.
//

import Foundation

/// Performs one HTTP request against the relay.
///
/// **On failure:** throws whatever the network threw — a `URLError` for
/// everything from aeroplane mode to a refused handshake — and returns nothing
/// partial. Interpreting it is the caller's job: `SyncServerClient` turns a
/// thrown error into `.folderUnavailable`, and every document already pinned
/// stays readable, because nothing on a reading path ever waits on this.
///
/// **An HTTP status is not a failure here.** 404, 401 and 503 are returned as
/// responses. A transport that threw on them would put the status table in two
/// places, and the whole point of `SyncServerClient` is that there is exactly
/// one.
public protocol SyncServerTransporting: Sendable {

    /// Sends `request` and reads the whole body into memory.
    ///
    /// For JSON only. Anything that could be a document's bytes goes through
    /// `download(_:to:)` instead.
    ///
    /// - Throws: a transport error. A reply that is not HTTP at all — which
    ///   should not happen against an `https` base URL — is also a throw
    ///   rather than a made-up status code.
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)

    /// Sends `request` and streams the body to a file.
    ///
    /// - Parameter destination: where the bytes end up. A 2xx replaces
    ///   whatever was there; anything else — a thrown transport error, or a
    ///   status whose body is an error page — leaves `destination` untouched,
    ///   so a failed re-download cannot replace a good file with the words
    ///   "not found".
    /// - Throws: a transport error, or a failure to write the file.
    func download(_ request: URLRequest, to destination: URL) async throws -> HTTPURLResponse
}
