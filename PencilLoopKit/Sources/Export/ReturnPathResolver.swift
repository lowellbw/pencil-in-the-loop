//
//  ReturnPathResolver.swift
//  Export
//
//  Where a review goes when the user presses Send (docs/04-flows.md § F5).
//
//  Pure and synchronous. It reads what `meta.json` claimed and picks the path
//  that claim describes; it cannot check whether the path will actually work,
//  because nothing on device can. The review sheet shows the user what was
//  chosen and lets them decide (docs/02-spec.md § S4) — that destination row is
//  the only place they learn whether their context is preserved.
//
//  **What v1 actually resolves.** `checkin` and `none` complete without anything
//  installed: a scheduled check-in collects the bundle from the outbox on its
//  own, and no-path falls back to copy / share / save. `poke`, `resume` and
//  `cloud` need the Mac-side watcher (integrations/mac-watcher), which is why
//  docs/06 calls the check-in the v1 default. They are still recognised and
//  still displayed, because a user who can see "Poke session · SAME THREAD"
//  before pressing Send knows what they are getting; one who sees nothing does
//  not.
//

import Foundation
import Core

/// Chooses the return path for a document's origin.
///
/// **When it fails or is unavailable:** returns `ResolvedReturnPath.unresolved`.
/// Never throws, never returns nil. No return path is a supported outcome with a
/// good fallback — the share-sheet route into the Claude app works today
/// (docs/06-integrations.md § The universal fallback) — and it must never be
/// presented as an error.
public struct ReturnPathResolver: ReturnPathResolving {

    public init() {}

    public func resolve(_ origin: Origin) -> ResolvedReturnPath {
        // `.share` and `.manual` never carried a conversation to return to.
        guard origin.kind.supportsReturnPath else { return .unresolved }
        guard let path = origin.returnPath, path.type != .none else { return .unresolved }

        let sessionId = ReturnPathResolver.present(origin.sessionId)
        let triggerId = ReturnPathResolver.present(path.triggerId)

        return ResolvedReturnPath(
            type: path.type,
            displayName: origin.kind.displayName,
            threadTitle: ReturnPathResolver.present(origin.threadTitle),
            sessionId: sessionId,
            triggerId: triggerId,
            sameThread: ReturnPathResolver.preservesContext(
                path.type,
                sessionId: sessionId,
                triggerId: triggerId
            )
        )
    }

    // MARK: - The badge

    /// Whether firing this path lands the review in the conversation the
    /// document came from.
    ///
    /// Deliberately not `ReturnPathType.isSameThread`. The type says what the
    /// writing tool intended; this says what is achievable with the identifiers
    /// it actually recorded. A `.resume` with no session id has nothing to
    /// resume, and `ResolvedReturnPath.sameThread` is documented as the field to
    /// trust for exactly this reason.
    ///
    /// - `poke` needs the trigger to fire.
    /// - `resume` and `cloud` need the session to address.
    /// - `checkin` needs neither: the session already holds a scheduled task
    ///   that reads the outbox, so the delivery does not go through us at all.
    static func preservesContext(
        _ type: ReturnPathType,
        sessionId: String?,
        triggerId: String?
    ) -> Bool {
        switch type {
        case .poke:
            return triggerId != nil
        case .checkin:
            return true
        case .resume, .cloud:
            return sessionId != nil
        case .none:
            return false
        }
    }

    /// Nil for a value that is absent or blank, so an empty string in
    /// `meta.json` cannot masquerade as a session id.
    static func present(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
