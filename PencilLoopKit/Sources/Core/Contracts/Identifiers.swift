//
//  Identifiers.swift
//  Core · Contracts
//
//  The closed vocabularies. Every raw value here appears verbatim in a file on
//  disk (`meta.json`, `review.json`) and is therefore a public contract with
//  external tools — see docs/05-file-contracts.md. Adding a case is cheap;
//  renaming one breaks every tool that ever wrote our folder format. Don't.
//
//  Decoding is deliberately total: an unrecognised raw value never throws, it
//  degrades to the documented fallback. A malformed `meta.json` must not stop a
//  document being readable (docs/04-flows.md § F1, failure handling).
//
//  Contains six enums rather than one type per file — they are one vocabulary
//  and splitting them buys nothing. Listed in tooling/lint/style_allowlist.txt.
//

import Foundation

/// Where a document sits in the reading lifecycle.
///
/// Drives the Library's three sections (docs/02-spec.md § S1). `.archived` is
/// hidden from all three. The transition `.unread → .reviewing` happens on the
/// first annotation, never on open (docs/04-flows.md § F2).
public enum DocState: String, Codable, Sendable, CaseIterable, Hashable {
    case unread
    case reviewing
    case read
    case archived

    /// Section heading text. Frozen here so the Library and the review sheet
    /// cannot drift apart.
    public var displayName: String {
        switch self {
        case .unread: return "Unread"
        case .reviewing: return "Reviewing"
        case .read: return "Read"
        case .archived: return "Archived"
        }
    }

    /// The sections the Library sidebar shows, in order, `.archived` excluded.
    public static let librarySections: [DocState] = [.reviewing, .unread, .read]

    /// Unknown raw values decode as `.unread` rather than throwing.
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = DocState(rawValue: raw) ?? .unread
    }
}

/// How the text of a comment was captured.
///
/// Serialised into `review.json` as `comments[].source` and rendered in
/// `review.md` as the italic attribution line under each comment.
public enum CommentSource: String, Codable, Sendable, CaseIterable, Hashable {
    case voice
    case handwriting
    case typed

    /// The attribution line used in `review.md`, without the surrounding
    /// asterisks. Frozen so the exported prose is stable across releases.
    ///
    /// **`.voice` no longer claims where it was transcribed, and that is a
    /// correction rather than a loss.** It used to say "transcribed on device",
    /// which stopped being reliably true when a queued recording could be
    /// re-transcribed by a better model afterwards
    /// (notes/pencil-loop-cloud-dictation.md). A line in an exported review is
    /// a claim to whoever reads it, `review.md` is a public contract
    /// (CLAUDE.md non-negotiable 3), and a vaguer true statement beats a
    /// specific false one. It still says how the words came to exist, which is
    /// what a reader of the review actually needs from it.
    public var attribution: String {
        switch self {
        case .voice: return "voice, transcribed"
        case .handwriting: return "handwriting, recognised"
        case .typed: return "typed"
        }
    }

    /// The one-line source label shown in the review sheet (docs/02-spec.md § S4).
    public var displayName: String {
        switch self {
        case .voice: return "voice · on-device"
        case .handwriting: return "handwriting · recognised"
        case .typed: return "typed"
        }
    }

    /// Unknown raw values decode as `.typed` — the least presumptuous source.
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = CommentSource(rawValue: raw) ?? .typed
    }
}

/// Which tool put the document in `inbox/`.
///
/// Raw values are exactly the strings in `meta.json` — note the hyphen in
/// `claude-code`, which is why these cannot be derived from the case names.
public enum OriginKind: String, Codable, Sendable, CaseIterable, Hashable {
    case cowork
    case claudeCode = "claude-code"
    case codex
    case share
    case manual

    /// Written in this app rather than sent to it (docs/11-backlog.md § B1).
    /// A note has no conversation behind it, so `supportsReturnPath` is false
    /// and a review of one goes to the relay's outbox for an agent to pull.
    case note

    /// Human-facing name used in the Library subtitle ("Cowork · 8 min ago ·
    /// 4 pages") and in the review sheet's destination row.
    public var displayName: String {
        switch self {
        case .cowork: return "Cowork"
        case .claudeCode: return "Claude Code"
        case .codex: return "Codex"
        case .share: return "Shared"
        case .manual: return "Added manually"
        case .note: return "Note"
        }
    }

    /// True when this origin can, in principle, carry a review back into a live
    /// conversation. `.share` and `.manual` never can (docs/04-flows.md § F5).
    public var supportsReturnPath: Bool {
        switch self {
        case .cowork, .claudeCode, .codex: return true
        case .share, .manual, .note: return false
        }
    }

    /// Unknown raw values decode as `.manual`, which is the documented fallback
    /// for a malformed `meta.json`.
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = OriginKind(rawValue: raw) ?? .manual
    }
}

/// How a finished review gets back to the session that sent the document.
///
/// Raw values are exactly the strings in `meta.json` at
/// `origin.returnPath.type`. See docs/06-integrations.md for what each one
/// costs to operate.
public enum ReturnPathType: String, Codable, Sendable, CaseIterable, Hashable {
    /// Fire a poke-only scheduled task bound to a Cowork session. Best path:
    /// the review lands as an ordinary user turn in the same thread.
    case poke
    /// A scheduled check-in on the Cowork session reads the outbox. The v1
    /// default because it needs nothing installed.
    case checkin
    /// `claude -p "…" --resume <session-id>` against an idle local session.
    case resume
    /// `claude --cloud <session-id> -p "…"` against a live web session.
    case cloud
    /// No automated path. The Sent screen offers copy / share / save instead —
    /// this is a supported outcome, never an error (docs/06-integrations.md).
    case none

    /// True when firing this path delivers into the originating conversation
    /// with its context intact. Drives the SAME THREAD / NEW THREAD badge.
    public var isSameThread: Bool {
        switch self {
        case .poke, .checkin, .resume, .cloud: return true
        case .none: return false
        }
    }

    /// Human-facing name for the destination row.
    public var displayName: String {
        switch self {
        case .poke: return "Poke session"
        case .checkin: return "Scheduled check-in"
        case .resume: return "Resume session"
        case .cloud: return "Cloud session"
        case .none: return "No return path"
        }
    }

    /// Unknown raw values decode as `.none`: we would rather show the share
    /// sheet fallback than claim a path that does not exist.
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = ReturnPathType(rawValue: raw) ?? .none
    }
}

/// What the document was before it became `document.pdf`.
///
/// `meta.json` field `sourceFormat`. `.markdown` is the only value that implies
/// `source.md` and `sourcemap.json` exist alongside it.
public enum SourceFormat: String, Codable, Sendable, CaseIterable, Hashable {
    case markdown
    case pdf
    case text
    case html
    case unknown

    /// Unknown raw values decode as `.unknown`.
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = SourceFormat(rawValue: raw) ?? .unknown
    }
}

/// The ruling printed on a page of blank paper.
///
/// `note.json` field `paper`, recorded so that pages appended to a notebook
/// later match the ones already in it (docs/11-backlog.md § B1).
///
/// The ruling is drawn *into* the PDF rather than laid under the canvas as a
/// view. A background view would be positioned in screen space and the ink in
/// page space, so the two would drift apart the moment the reader was zoomed —
/// the same reason document text is rendered rather than overlaid.
public enum PaperStyle: String, Codable, Sendable, CaseIterable, Hashable {
    case plain
    case lined
    case grid

    /// Human-facing name, used in the paper picker when a note is created.
    public var displayName: String {
        switch self {
        case .plain: return "Plain"
        case .lined: return "Lined"
        case .grid: return "Grid"
        }
    }

    /// Unknown raw values decode as `.plain` — an unreadable ruling should cost
    /// the lines, never the notebook.
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = PaperStyle(rawValue: raw) ?? .plain
    }
}
