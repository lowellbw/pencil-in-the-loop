//
//  BundleManifest.swift
//  Core · Contracts
//
//  `manifest.json`. Three types in one file; listed in
//  tooling/lint/style_allowlist.txt.
//
//  ─── DESIGNED, NOT TRANSCRIBED ───────────────────────────────────────────────
//  docs/05-file-contracts.md lists `manifest.json` in the outbox layout but
//  never shows its contents, so the shape below is a decision of this unit
//  rather than a transcription. It answers the three questions a watcher on the
//  other side actually has: is this bundle complete, did it change since I last
//  looked, and what wrote it. Schema in contracts/schema/manifest.schema.json,
//  fixture in contracts/fixtures/manifest.json.
//  ─────────────────────────────────────────────────────────────────────────────
//

import Foundation

/// An inventory of a review bundle, written last.
///
/// Its ordering matters operationally: the bundle is assembled in a temporary
/// directory and renamed into place atomically (docs/04-flows.md § F5), so a
/// watcher never sees a partial bundle. The manifest exists for the case the
/// rename cannot protect against — a bundle copied by another tool, or synced
/// file by file by a provider that has its own ideas about ordering. If the
/// files listed here are not all present with these sizes and hashes, wait.
public struct BundleManifest: Codable, Sendable, Hashable {

    /// Format version. Bump only for a breaking change.
    public var version: Int

    /// The `meta.json` id of the document being reviewed, verbatim.
    public var documentId: String

    /// The bundle's own directory name, `<slug>.review`. Present so a manifest
    /// that gets copied somewhere else still says where it belongs.
    public var reviewFolder: String

    /// When the bundle was written.
    public var createdAt: Date

    /// What wrote it.
    public var generator: GeneratorInfo

    /// Every file in the bundle except this one, sorted by path. `manifest.json`
    /// cannot list its own hash, so it does not list itself.
    public var files: [ManifestFile]

    /// Whether the bundle is finished.
    ///
    /// Always `true` in a manifest this app writes — the manifest is written
    /// last, so its existence already says so. It is written explicitly because
    /// the watcher's completeness rule is "does not say `complete: false`", and
    /// a tool assembling a bundle over several syncs has somewhere to say
    /// "not yet" (integrations/mac-watcher § completeness).
    public var complete: Bool

    /// Where the reviewed document came from, copied from its `meta.json`.
    ///
    /// The watcher resolves a return path most-specific-first and looks here
    /// before anything else. Without it, it always fell through to reading
    /// `inbox/<slug>/meta.json` — which works only while the inbox folder is
    /// still called what the bundle expects, so a renamed or tidied-away inbox
    /// folder lost the route back to the conversation. The bundle now carries
    /// its own answer.
    ///
    /// Nil when the document had no metadata at all, which is a manually added
    /// document with no return path — readable, just not routable.
    public var origin: Origin?

    public init(
        version: Int = BundleManifest.currentVersion,
        documentId: String,
        reviewFolder: String,
        createdAt: Date,
        generator: GeneratorInfo,
        files: [ManifestFile],
        complete: Bool = true,
        origin: Origin? = nil
    ) {
        self.version = version
        self.documentId = documentId
        self.reviewFolder = reviewFolder
        self.createdAt = createdAt
        self.generator = generator
        self.files = files
        self.complete = complete
        self.origin = origin
    }

    public static let currentVersion = 1

    /// The bundle-relative filename this type is written to.
    public static let fileName = "manifest.json"

    /// Total bytes of the listed files.
    public var totalBytes: Int64 {
        files.reduce(0) { $0 + $1.bytes }
    }
}

/// One file in the inventory.
public struct ManifestFile: Codable, Sendable, Hashable {

    /// Bundle-relative, forward slashes, no leading slash: `review.md`,
    /// `ink/page-01.png`.
    public var path: String

    /// Exact byte count.
    public var bytes: Int64

    /// Lowercase hex SHA-256 of the file's contents, 64 characters. Lets a
    /// watcher tell a re-sent bundle from a re-synced one.
    public var sha256: String

    public init(path: String, bytes: Int64, sha256: String) {
        self.path = path
        self.bytes = bytes
        self.sha256 = sha256
    }
}

/// What produced the bundle.
public struct GeneratorInfo: Codable, Sendable, Hashable {

    /// Always `pencil-in-the-loop` for bundles this app writes. A different
    /// value means another tool wrote a compatible bundle, which is allowed and
    /// is rather the point of a file-based contract.
    public var name: String

    /// The app's marketing version, e.g. `1.0`.
    public var version: String

    /// Build number, when known.
    public var build: String?

    public init(name: String = GeneratorInfo.appName, version: String, build: String? = nil) {
        self.name = name
        self.version = version
        self.build = build
    }

    public static let appName = "pencil-in-the-loop"

    enum CodingKeys: String, CodingKey {
        case name
        case version
        case build
    }

    /// Omits `build` rather than writing null.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(version, forKey: .version)
        try container.encodeIfPresent(build, forKey: .build)
    }
}
