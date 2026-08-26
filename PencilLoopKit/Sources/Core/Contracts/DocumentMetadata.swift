//
//  DocumentMetadata.swift
//  Core · Contracts
//
//  The whole of `meta.json`. See docs/05-file-contracts.md.
//
//  Read with `ContractCoding.decoder()` and write with `ContractCoding.encoder()`
//  — the date strategy is part of the format, not a caller preference.
//

import Foundation

/// `meta.json`, the one file that tells us where a document came from.
///
/// ```json
/// {
///   "id": "F7A1…",
///   "title": "Auth refactor plan",
///   "createdAt": "2026-08-18T18:22:04Z",
///   "origin": { … },
///   "sourceFormat": "markdown",
///   "pageCount": 4
/// }
/// ```
///
/// **Every field is optional and decoding never throws.** A document whose
/// `meta.json` is truncated, empty, or written by a tool that got the schema
/// wrong still ingests: the title falls back to the filename and the origin to
/// `.manual` (docs/04-flows.md § F1). Ingest is responsible for supplying those
/// fallbacks — this type reports honestly what was in the file and nothing more.
public struct DocumentMetadata: Codable, Sendable, Hashable {

    /// The writing tool's own identifier, verbatim. Deliberately a `String`,
    /// not a `UUID`: external tools write whatever they like here and a
    /// non-UUID value must not fail ingest. Use `uuid` when you need one.
    public var id: String?

    /// Document title. Nil means "use the PDF metadata, the markdown H1, or the
    /// filename", in that order.
    public var title: String?

    /// When the writing tool created the document, not when we saw it.
    public var createdAt: Date?

    /// Nil is equivalent to `Origin.manual`; `resolvedOrigin` does that for you.
    public var origin: Origin?

    /// What the document was before rendering.
    public var sourceFormat: SourceFormat?

    /// Page count as claimed by the writer. Advisory only — the real count comes
    /// from the rendered PDF, and they can disagree.
    public var pageCount: Int?

    /// Where the document came from on the web, when it came from the web.
    ///
    /// Written by the share extension for a shared link: the extension does no
    /// network work, so it stages a placeholder `source.md` and records the
    /// address here for the app to fetch and render later
    /// (docs/06-integrations.md § Share extension). It had been going into a
    /// `source.url` file named by a private constant in the extension, which
    /// meant the one piece of the app that will read it had no contract name
    /// for it.
    ///
    /// Optional and additive: a reader that does not know the key ignores it,
    /// and nothing in ingest branches on it today.
    public var sourceURL: URL?

    /// The group the sending tool proposes this document be filed under, or nil
    /// when it proposes none (docs/05-file-contracts.md).
    ///
    /// Groups are identified by this string and nothing else — there is no
    /// registry and no id, so a name used for the first time starts a group and
    /// a name nothing uses stops being one. Names are compared with case,
    /// accents and punctuation ignored and displayed as first written; the rule
    /// lives in `AppSettings.DocumentGroups`.
    ///
    /// **Advisory.** The app adopts it for a document it has not seen before and
    /// never overrides a group the user chose on the device, so a re-send cannot
    /// move a document the reader has filed by hand.
    ///
    /// Optional and additive: most documents do not have one, by design.
    public var group: String?

    public init(
        id: String? = nil,
        title: String? = nil,
        createdAt: Date? = nil,
        origin: Origin? = nil,
        sourceFormat: SourceFormat? = nil,
        pageCount: Int? = nil,
        sourceURL: URL? = nil,
        group: String? = nil
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.origin = origin
        self.sourceFormat = sourceFormat
        self.pageCount = pageCount
        self.sourceURL = sourceURL
        self.group = group
    }

    /// The value used when `meta.json` is missing entirely.
    public static let empty = DocumentMetadata()

    /// `origin` with the documented fallback applied.
    public var resolvedOrigin: Origin { origin ?? .manual }

    /// `id` parsed as a UUID when it happens to be one. Ingest mints a fresh
    /// UUID when this is nil, and records the raw string alongside it.
    public var uuid: UUID? {
        guard let id else { return nil }
        return UUID(uuidString: id)
    }

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case createdAt
        case origin
        case sourceFormat
        case pageCount
        case sourceURL
        case group
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(id, forKey: .id)
        try container.encodeIfPresent(title, forKey: .title)
        try container.encodeIfPresent(createdAt, forKey: .createdAt)
        try container.encodeIfPresent(origin, forKey: .origin)
        try container.encodeIfPresent(sourceFormat, forKey: .sourceFormat)
        try container.encodeIfPresent(pageCount, forKey: .pageCount)
        try container.encodeIfPresent(sourceURL?.absoluteString, forKey: .sourceURL)
        try container.encodeIfPresent(group, forKey: .group)
    }

    /// Never throws for a document that is valid JSON. A top level that is not
    /// an object yields `.empty`; individual fields that are the wrong type are
    /// dropped.
    public init(from decoder: Decoder) throws {
        guard let container = try? decoder.container(keyedBy: CodingKeys.self) else {
            self = .empty
            return
        }
        self.id = try? container.decodeIfPresent(String.self, forKey: .id)
        self.title = try? container.decodeIfPresent(String.self, forKey: .title)
        self.createdAt = DocumentMetadata.lenientDate(container, .createdAt)
        self.origin = try? container.decodeIfPresent(Origin.self, forKey: .origin)
        self.sourceFormat = try? container.decodeIfPresent(SourceFormat.self, forKey: .sourceFormat)
        self.pageCount = try? container.decodeIfPresent(Int.self, forKey: .pageCount)
        self.sourceURL = DocumentMetadata.lenientURL(container, .sourceURL)
        self.group = try? container.decodeIfPresent(String.self, forKey: .group)
    }

    /// A URL from its string form. Anything that is not a parseable absolute
    /// URL is nil rather than an error: a malformed address costs a "fetch this
    /// page later", never the document.
    private static func lenientURL(
        _ container: KeyedDecodingContainer<CodingKeys>,
        _ key: CodingKeys
    ) -> URL? {
        // `try?` flattens the `String??` that decodeIfPresent would otherwise
        // give here, so an absent key and a key of the wrong type both arrive
        // as nil — which is exactly the leniency this method is for.
        guard let text = try? container.decodeIfPresent(String.self, forKey: key),
              text.isEmpty == false else { return nil }
        return URL(string: text)
    }

    /// Accepts whatever the decoder's date strategy handles, then falls back to
    /// parsing an ISO 8601 string by hand, then to a Unix timestamp. Anything
    /// else is nil.
    private static func lenientDate(
        _ container: KeyedDecodingContainer<CodingKeys>,
        _ key: CodingKeys
    ) -> Date? {
        if let date = try? container.decodeIfPresent(Date.self, forKey: key) {
            return date
        }
        if let text = try? container.decodeIfPresent(String.self, forKey: key) {
            return ContractCoding.date(from: text)
        }
        if let seconds = try? container.decodeIfPresent(Double.self, forKey: key) {
            return Date(timeIntervalSince1970: seconds)
        }
        return nil
    }
}
