//
//  RemoteDocument.swift
//  Sync · HTTP
//
//  One entry in `GET /v1/changes`, and the rules for reading a feed written by
//  a server this app does not deploy in lockstep with.
//
//  ─── THE ONE RULE, THE SAME ONE AS meta.json ─────────────────────────────────
//  Decoding is lenient in exactly the way `MetadataFile` is lenient. An unknown
//  key is ignored, a missing key takes a default, and **a malformed entry is
//  dropped rather than failing the page**. A relay that gains a field must not
//  be able to empty an iPad's library, and one bad row must not hide the
//  fifteen good ones behind it — a document that quietly never appears is the
//  failure this project can least afford (DTOs.swift § InboxScanResult).
//
//  The corollary is that nothing here is trusted. `folderName` becomes a
//  directory name inside the app container, so it is checked for path
//  separators and dots before it is used, and a file name has to be one of the
//  four in `DocumentFileNames` — the same allowlist the relay applies on the
//  way in (relay/files.py § validate_document_file).
//  ─────────────────────────────────────────────────────────────────────────────
//

import Foundation
import Core

/// A document the relay is offering, as `GET /v1/changes` describes it.
///
/// This is a description, not the document: the bytes are fetched, verified and
/// pinned by `RemoteDocumentPinner` before anything else in the app is told the
/// document exists (CLAUDE.md non-negotiable 2).
public struct RemoteDocument: Sendable, Hashable, Decodable {

    /// One file the server says the document is made of, with what it must
    /// weigh and hash to.
    ///
    /// Both `bytes` and `sha256` are Optional because a decoder that threw on
    /// their absence would drop the whole entry. A file that declares neither
    /// cannot be verified, and `RemoteDocumentPinner` refuses it rather than
    /// pinning bytes it cannot check.
    public struct File: Sendable, Hashable, Decodable {

        /// `document.pdf`, `source.md`, `sourcemap.json` or `meta.json`.
        public var name: String

        /// The exact size the download must have.
        public var bytes: Int64?

        /// Lowercase hex SHA-256 of the contents, as `ETag` also carries.
        public var sha256: String?

        public init(name: String, bytes: Int64? = nil, sha256: String? = nil) {
            self.name = name
            self.bytes = bytes
            self.sha256 = sha256
        }

        private enum CodingKeys: String, CodingKey {
            case name, bytes, sha256
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            func text(_ key: CodingKeys) -> String? {
                guard let value = try? container.decodeIfPresent(String.self, forKey: key) else { return nil }
                return value
            }
            name = text(.name) ?? ""
            sha256 = text(.sha256)
            bytes = try? container.decodeIfPresent(Int64.self, forKey: .bytes)
        }

        /// Whether this file may be written into the container at all.
        ///
        /// The name has to be one of the four a document directory holds. That
        /// is a path-traversal check as much as a schema check: `name` is
        /// appended to a directory URL, and there is no normalising step
        /// because a name that needs normalising is not one of the four.
        public var isKnownDocumentFile: Bool {
            DocumentFileNames.documentFiles.contains(name)
        }
    }

    /// One element of a JSON array that must never fail the array.
    ///
    /// Decoding an array of these cannot throw: an element that is the wrong
    /// shape entirely — a string where an object was expected — becomes a nil
    /// `value` and is dropped by the caller. It is generic because both arrays
    /// in a change page need it, and it lives here because this is the file
    /// that owns the feed's tolerance.
    public struct LenientElement<Wrapped: Decodable & Sendable>: Decodable, Sendable {

        /// What was there, or nil when it could not be read.
        public let value: Wrapped?

        public init(from decoder: any Decoder) throws {
            value = try? Wrapped(from: decoder)
        }
    }

    /// `YYYY-MM-DD-<slug>` — the human key, allocated by the server, and the
    /// name of the directory the pinned copy lives in.
    public var folderName: String

    /// `meta.json`'s `id`, which is the idempotency key on the way up and the
    /// correlation key everywhere else. Nil when the server sent something that
    /// is not a UUID.
    public var documentId: UUID?

    /// The title from `meta.json`, when it had one. Ingest still prefers the
    /// PDF's own title and the markdown H1 over this.
    public var title: String?

    /// When the document was created, per `meta.json`.
    public var createdAt: Date?

    /// The relay's monotonic sequence number: the cursor, and the revision
    /// marker recorded in the pinned sidecar.
    public var seq: Int64

    /// Set when the document has been deleted on the server. A tombstone
    /// carries no files.
    public var deletedAt: Date?

    /// Every file the server holds for this document, each with its size and
    /// hash.
    public var files: [File]

    public init(
        folderName: String,
        documentId: UUID? = nil,
        title: String? = nil,
        createdAt: Date? = nil,
        seq: Int64 = 0,
        deletedAt: Date? = nil,
        files: [File] = []
    ) {
        self.folderName = folderName
        self.documentId = documentId
        self.title = title
        self.createdAt = createdAt
        self.seq = seq
        self.deletedAt = deletedAt
        self.files = files
    }

    private enum CodingKeys: String, CodingKey {
        case folderName, documentId, title, createdAt, seq, deletedAt, files
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Every field is read through a `try?`, so a `createdAt` of "yesterday"
        // costs the date and not the document. The alternative — one strict
        // key — is a relay typo emptying a library.
        func text(_ key: CodingKeys) -> String? {
            guard let value = try? container.decodeIfPresent(String.self, forKey: key) else { return nil }
            return value
        }
        func stamp(_ key: CodingKeys) -> Date? {
            guard let value = try? container.decodeIfPresent(Date.self, forKey: key) else { return nil }
            return value
        }
        func entries(_ key: CodingKeys) -> [File] {
            guard let value = try? container.decodeIfPresent([LenientElement<File>].self, forKey: key) else {
                return []
            }
            return value.compactMap(\.value)
        }

        folderName = text(.folderName) ?? ""
        documentId = text(.documentId).flatMap { UUID(uuidString: $0) }
        title = text(.title)
        createdAt = stamp(.createdAt)
        deletedAt = stamp(.deletedAt)
        files = entries(.files)
        seq = (try? container.decodeIfPresent(Int64.self, forKey: .seq)) ?? 0
    }

    /// The revision marker recorded in the pinned sidecar, so a later poll can
    /// tell "the same document again" from "a new revision of it".
    public var revision: String { String(seq) }

    /// True when this entry is a deletion rather than a document.
    public var isDeleted: Bool { deletedAt != nil }

    /// Whether `folderName` is safe to use as a directory name.
    ///
    /// The relay allocates these and would never send anything else, which is
    /// exactly why this is checked here: the one place a compromised or simply
    /// wrong server could reach outside the app container is a folder name with
    /// a path separator in it, and the check costs nothing.
    public var hasUsableFolderName: Bool {
        if folderName.isEmpty { return false }
        if folderName.hasPrefix(".") { return false }
        if folderName.contains("/") { return false }
        if folderName.contains("\\") { return false }
        return true
    }

    /// The files worth downloading, in the order they are copied.
    ///
    /// Anything the server offers under a name a document directory does not
    /// have is skipped rather than refused, so a relay that starts serving a
    /// fifth file does not break this build of the app.
    public var pinnableFiles: [File] {
        let order = DocumentFileNames.documentFiles
        return files
            .filter(\.isKnownDocumentFile)
            .sorted { (order.firstIndex(of: $0.name) ?? 0) < (order.firstIndex(of: $1.name) ?? 0) }
    }
}
