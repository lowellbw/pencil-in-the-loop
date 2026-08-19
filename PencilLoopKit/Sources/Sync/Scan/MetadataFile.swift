//
//  MetadataFile.swift
//  Sync · Scan
//
//  Reading and writing `meta.json` (docs/05-file-contracts.md).
//
//  ─── THE ONE RULE ────────────────────────────────────────────────────────────
//  Reading never throws and never blocks ingest. A truncated file, a file
//  written by a tool that got the schema wrong, a file that is not there at all
//  — every one of those yields `DocumentMetadata.empty`, and the caller falls
//  back to the filename for the title and `origin.kind = "manual"`
//  (docs/04-flows.md § F1, failure handling).
//
//  The tolerance lives in Core: `DocumentMetadata` and `Origin` both decode
//  leniently by construction. This file does not reimplement any of it, and if
//  you find yourself adding a second lenient decoder here, delete it and use
//  theirs.
//  ─────────────────────────────────────────────────────────────────────────────
//

import Foundation
import Core

/// `meta.json`, read and written through `ContractCoding`.
///
/// **On failure:** `read` cannot fail — it returns `DocumentMetadata.empty`.
/// `encode` throws whatever `JSONEncoder` threw, which for a value built from
/// `DocumentMetadata`'s own fields does not happen in practice.
public enum MetadataFile {

    /// Reads `meta.json` from an inbox directory.
    ///
    /// - Parameter directoryURL: an `inbox/<YYYY-MM-DD-slug>` directory. The
    ///   caller must already hold access.
    /// - Returns: what was in the file, or `DocumentMetadata.empty` when it was
    ///   missing, unreadable or malformed. Never throws.
    public static func read(inDirectory directoryURL: URL) -> DocumentMetadata {
        read(at: directoryURL.appendingPathComponent(DocumentFileNames.metadata, isDirectory: false))
    }

    /// Reads a `meta.json` at an exact URL.
    ///
    /// - Returns: `DocumentMetadata.empty` for anything that is not a readable,
    ///   decodable object. Never throws.
    public static func read(at url: URL) -> DocumentMetadata {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return .empty
        }
        do {
            let data = try CoordinatedFileAccess.read(at: url) { readableURL in
                try Data(contentsOf: readableURL)
            }
            return try ContractCoding.decoder().decode(DocumentMetadata.self, from: data)
        } catch {
            SyncLog.scan.notice("meta.json at \(url.lastPathComponent) was unusable; falling back to defaults.")
            return .empty
        }
    }

    /// The bytes of a `meta.json`, formatted exactly as every other file this
    /// app writes: sorted keys, pretty-printed, ISO 8601 dates with a `Z`.
    ///
    /// - Throws: an encoding error. There is no `PencilLoopError` for this
    ///   because there is no recovery a caller could perform.
    public static func encode(_ metadata: DocumentMetadata) throws -> Data {
        try ContractCoding.encoder().encode(metadata)
    }

    /// The origin a document inherits when it is created from another
    /// document's reply (docs/04-flows.md § F6).
    ///
    /// The whole point of the reply loop is that the thread carries forward, so
    /// the session id, the thread title and the return path all come across
    /// unchanged. An origin that could not carry a review back stays as it is —
    /// inheriting `.manual` from a manual document is the honest answer.
    public static func inheritedOrigin(from metadata: DocumentMetadata) -> Origin {
        metadata.resolvedOrigin
    }

    /// A title for a directory whose `meta.json` did not supply one.
    ///
    /// `2026-08-18-auth-refactor-plan` becomes `Auth refactor plan`. Ingest
    /// still prefers the PDF metadata title and the markdown H1 over this;
    /// it is the last resort, and the last resort has to be readable.
    public static func fallbackTitle(forDirectoryNamed folderName: String) -> String {
        let slug = Slug.split(folderName: folderName)?.slug ?? folderName
        let spaced = slug.replacingOccurrences(of: "-", with: " ").trimmingCharacters(in: .whitespaces)
        guard let first = spaced.first else { return folderName }
        return String(first).uppercased() + spaced.dropFirst()
    }
}
