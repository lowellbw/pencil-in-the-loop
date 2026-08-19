//
//  Origin.swift
//  Core · Contracts
//
//  The `origin` object in `meta.json`, plus the `returnPath` it contains.
//
//  Two types in one file: `ReturnPath` exists only inside `Origin` and reading
//  them apart is worse than reading them together. Listed in
//  tooling/lint/style_allowlist.txt.
//
//  **Nothing here throws on decode.** docs/05-file-contracts.md says everything
//  under `origin` is optional, and docs/04-flows.md § F1 says a malformed
//  `meta.json` must never block ingest. So every field is optional-tolerant and
//  the whole object degrades to `.manual` rather than failing. If you find
//  yourself adding a `try` that can propagate out of this file, you have broken
//  a documented guarantee.
//

import Foundation

/// Where a document came from, and how to get a review back there.
///
/// ```json
/// "origin": {
///   "kind": "cowork",
///   "sessionId": "8f3c1d…",
///   "threadTitle": "Q3 platform planning",
///   "returnPath": { "type": "poke", "triggerId": "trig_…" }
/// }
/// ```
public struct Origin: Codable, Sendable, Hashable {

    /// Which tool wrote the document. Unknown or missing values become
    /// `.manual`.
    public var kind: OriginKind

    /// The originating session, when there was one. Cowork session id, Claude
    /// Code `session_id` from the hook payload, or the Codex equivalent.
    public var sessionId: String?

    /// Human-facing conversation title, shown in the review sheet's destination
    /// row so the user knows which thread they are about to post into.
    public var threadTitle: String?

    /// How to deliver the review. Nil means no automated path — the Sent screen
    /// falls back to copy / share / save.
    public var returnPath: ReturnPath?

    public init(
        kind: OriginKind = .manual,
        sessionId: String? = nil,
        threadTitle: String? = nil,
        returnPath: ReturnPath? = nil
    ) {
        self.kind = kind
        self.sessionId = sessionId
        self.threadTitle = threadTitle
        self.returnPath = returnPath
    }

    /// The value used whenever `meta.json` is absent, unreadable, or so
    /// malformed that nothing can be salvaged: a manually added document with
    /// no session and no way back.
    public static let manual = Origin(kind: .manual)

    /// True when a review from this document can reach a conversation.
    public var canReturn: Bool {
        guard kind.supportsReturnPath else { return false }
        guard let returnPath else { return false }
        return returnPath.type != .none
    }

    enum CodingKeys: String, CodingKey {
        case kind
        case sessionId
        case threadTitle
        case returnPath
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        try container.encodeIfPresent(sessionId, forKey: .sessionId)
        try container.encodeIfPresent(threadTitle, forKey: .threadTitle)
        try container.encodeIfPresent(returnPath, forKey: .returnPath)
    }

    /// Never throws. Anything unreadable — a string where an object belongs, a
    /// number for `kind`, a truncated file — yields `.manual` or the closest
    /// partial reading available.
    public init(from decoder: Decoder) throws {
        guard let container = try? decoder.container(keyedBy: CodingKeys.self) else {
            self = .manual
            return
        }
        self.kind = (try? container.decode(OriginKind.self, forKey: .kind)) ?? .manual
        self.sessionId = Origin.lenientString(container, .sessionId)
        self.threadTitle = Origin.lenientString(container, .threadTitle)
        self.returnPath = try? container.decodeIfPresent(ReturnPath.self, forKey: .returnPath)
    }

    /// Decodes a string, tolerating a number or a bool where a string was
    /// expected, and treating an empty string as absent.
    private static func lenientString(
        _ container: KeyedDecodingContainer<CodingKeys>,
        _ key: CodingKeys
    ) -> String? {
        if let value = try? container.decodeIfPresent(String.self, forKey: key) {
            return value.isEmpty ? nil : value
        }
        if let value = try? container.decodeIfPresent(Int.self, forKey: key) {
            return String(value)
        }
        return nil
    }
}

/// How a finished review gets delivered back.
///
/// ```json
/// "returnPath": { "type": "poke", "triggerId": "trig_…" }
/// ```
/// `triggerId` is meaningful for `.poke` and `.checkin` only; the resume and
/// cloud paths key off `Origin.sessionId`. Extra keys written by future tools
/// are ignored rather than rejected.
public struct ReturnPath: Codable, Sendable, Hashable {

    /// Which mechanism. Unknown or missing values become `.none`.
    public var type: ReturnPathType

    /// The scheduled-task id to fire, for `.poke` and `.checkin`.
    public var triggerId: String?

    /// Optional free-text note from the writing tool about how to deliver —
    /// e.g. a working directory for `--resume`. Carried through untouched.
    public var detail: String?

    public init(type: ReturnPathType = .none, triggerId: String? = nil, detail: String? = nil) {
        self.type = type
        self.triggerId = triggerId
        self.detail = detail
    }

    /// The "no automated path" value.
    public static let none = ReturnPath(type: .none)

    enum CodingKeys: String, CodingKey {
        case type
        case triggerId
        case detail
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(type, forKey: .type)
        try container.encodeIfPresent(triggerId, forKey: .triggerId)
        try container.encodeIfPresent(detail, forKey: .detail)
    }

    /// Never throws; degrades to `.none`.
    public init(from decoder: Decoder) throws {
        guard let container = try? decoder.container(keyedBy: CodingKeys.self) else {
            self = .none
            return
        }
        self.type = (try? container.decode(ReturnPathType.self, forKey: .type)) ?? .none
        self.triggerId = try? container.decodeIfPresent(String.self, forKey: .triggerId)
        self.detail = try? container.decodeIfPresent(String.self, forKey: .detail)
    }
}
