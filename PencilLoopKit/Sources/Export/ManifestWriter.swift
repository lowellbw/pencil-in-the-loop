//
//  ManifestWriter.swift
//  Export
//
//  `manifest.json`, written last. Schema at contracts/schema/manifest.schema.json.
//
//  ─── WHAT THE WATCHER ON THE OTHER SIDE WAITS FOR ────────────────────────────
//  integrations/mac-watcher gates on this file, and its completeness rule is:
//
//    · manifest.json exists and parses as a JSON object
//    · it does not say "complete": false
//    · review.md exists
//    · every file the manifest lists exists
//    · the directory's (path, size, mtime) fingerprint holds still, and the
//      whole check passes again after the settle delay
//
//  So the list has to be exhaustive and it has to be right. A bundle whose
//  manifest omits an ink PNG is delivered the moment the manifest lands, before
//  the PNG has finished syncing, and the review arrives without its images.
//
//  The watcher reads `files` as either strings or objects carrying `path`,
//  `name` or `file` — `ManifestFile.path` satisfies that unchanged. It reads
//  `complete` as optional, and `BundleManifest` now writes it explicitly as
//  `true`. It also reads the manifest's own `origin` block before falling back
//  to `inbox/<slug>/meta.json`, and the manifest now carries one, so a renamed
//  or tidied-away inbox folder no longer loses the route back.
//  ─────────────────────────────────────────────────────────────────────────────
//

import Foundation
import CryptoKit
import Core

/// Builds `manifest.json` for a set of bundle files.
///
/// **On failure:** `data(for:)` throws `PencilLoopError.bundleBuildFailed`.
/// Building the value cannot fail; hashing bytes already in memory cannot fail.
public struct ManifestWriter: Sendable {

    private let generator: GeneratorInfo

    /// - Parameter generator: what to record as the producer. Defaults to the
    ///   host app's version, which is nil-safe: an extension or a test bundle
    ///   with no version info records `0`, it does not crash and it does not
    ///   omit the field the schema requires.
    public init(generator: GeneratorInfo = ManifestWriter.hostGenerator()) {
        self.generator = generator
    }

    // MARK: - Building

    /// The manifest for a finished bundle.
    ///
    /// - Parameters:
    ///   - files: every file in the bundle. `manifest.json` is dropped if it is
    ///     present — it cannot list its own hash (`BundleManifest.files`).
    ///   - documentId: `meta.json`'s id, verbatim.
    ///   - reviewFolder: the bundle's own directory name, `<slug>.review`.
    ///   - createdAt: when the bundle was written.
    ///   - origin: the reviewed document's origin, copied in so the bundle
    ///     carries its own return path. Pass nil only when there was no
    ///     metadata at all.
    /// - Returns: a manifest whose `files` are sorted by path, so two runs over
    ///   the same bundle produce identical bytes, and which says `complete:
    ///   true` — this writer only ever builds a finished bundle.
    public func manifest(
        files: [BundleFile],
        documentId: String,
        reviewFolder: String,
        createdAt: Date,
        origin: Origin? = nil
    ) -> BundleManifest {
        let listed = files
            .filter { $0.relativePath != BundleManifest.fileName }
            .map {
                ManifestFile(
                    path: $0.relativePath,
                    bytes: Int64($0.data.count),
                    sha256: ManifestWriter.sha256Hex($0.data)
                )
            }
            .sorted { $0.path < $1.path }

        return BundleManifest(
            version: BundleManifest.currentVersion,
            documentId: documentId,
            reviewFolder: reviewFolder,
            createdAt: createdAt,
            generator: generator,
            files: listed,
            complete: true,
            origin: origin
        )
    }

    /// The bytes, through the one frozen encoder.
    ///
    /// - Throws: `PencilLoopError.bundleBuildFailed` when encoding fails.
    public func data(for manifest: BundleManifest) throws -> Data {
        do {
            return try ContractCoding.encoder().encode(manifest)
        } catch {
            throw PencilLoopError.bundleBuildFailed(
                reason: "manifest.json could not be encoded. \(error.localizedDescription)"
            )
        }
    }

    // MARK: - Primitives

    /// Lowercase hex SHA-256, 64 characters, as
    /// contracts/schema/manifest.schema.json requires.
    ///
    /// Exposed rather than private so a test can check a hash without importing
    /// CryptoKit into a test target that is not allowed it.
    public static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    /// `GeneratorInfo` for the running app.
    ///
    /// Reads `CFBundleShortVersionString` and `CFBundleVersion` from the main
    /// bundle. Both are optional in practice — a unit test bundle has neither —
    /// so the version falls back to `0` rather than to a crash.
    public static func hostGenerator(bundle: Bundle = .main) -> GeneratorInfo {
        let info = bundle.infoDictionary
        let version = (info?["CFBundleShortVersionString"] as? String) ?? "0"
        let build = info?["CFBundleVersion"] as? String
        return GeneratorInfo(name: GeneratorInfo.appName, version: version, build: build)
    }
}
