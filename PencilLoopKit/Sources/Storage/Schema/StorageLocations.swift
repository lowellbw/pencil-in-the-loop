//
//  StorageLocations.swift
//  Storage
//
//  Storage's own on-disk business: where the SwiftData store file lives, and
//  how many bytes a directory holds for the Settings row.
//
//  ─── THE LAYOUT MOVED TO CORE ────────────────────────────────────────────────
//  The container layout — the documents root, a document's directory, and the
//  relative-path encoding that survives a reinstall — is now defined once, in
//  `Core/Contracts/DocumentContainer.swift`. It had to move: Sync pins the
//  bytes and Ingest materialises them, and neither may import Storage, so a
//  layout that lived here was a layout each of them re-invented (see that
//  file's header for what that cost).
//
//  The five members below forward to it unchanged. They are kept because
//  Storage's own call sites and tests read better with one import, and because
//  `storeURL()` and the byte counting genuinely belong to this module. **Do not
//  add a member here that decides where anything lives.** That decision has one
//  home and it is not this file.
//

import Foundation
import Core

/// Where everything Storage owns lives on disk.
///
/// **On failure:** every member returns a value rather than throwing. A path
/// that cannot be resolved shows up as the read that follows it failing, with a
/// reason, rather than as a crash on launch.
public enum StorageLocations {

    /// The SwiftData store file.
    public static let storeFileName = "Library.store"

    /// `Application Support/PencilLoop`. Forwards to `DocumentContainer`.
    public static func containerRoot() -> URL {
        DocumentContainer.containerRoot()
    }

    /// `Application Support/PencilLoop/Documents`. Forwards to
    /// `DocumentContainer`.
    public static func documentsRoot() -> URL {
        DocumentContainer.documentsRoot()
    }

    /// The pinned directory for one document folder name. Forwards to
    /// `DocumentContainer`.
    public static func documentDirectory(folderName: String) -> URL {
        DocumentContainer.documentDirectory(folderName: folderName)
    }

    /// Turns an absolute URL into the string the store persists. Forwards to
    /// `DocumentContainer`.
    public static func storedPath(for url: URL) -> String {
        DocumentContainer.storedPath(for: url)
    }

    /// The inverse of `storedPath(for:)`. Forwards to `DocumentContainer`.
    ///
    /// - Returns: nil for an empty path — a row recorded by
    ///   `recordIngestFailure(folderName:reason:)` has no pinned bytes and no
    ///   honest URL.
    public static func url(forStoredPath path: String) -> URL? {
        DocumentContainer.url(forStoredPath: path)
    }

    /// True when `url` sits inside the app's own documents root. Forwards to
    /// `DocumentContainer`.
    public static func isInsideDocumentsRoot(_ url: URL) -> Bool {
        DocumentContainer.isInsideDocumentsRoot(url)
    }

    /// The SwiftData store file URL.
    public static func storeURL() -> URL {
        DocumentContainer.containerRoot().appendingPathComponent(storeFileName, isDirectory: false)
    }

    /// Total bytes of every regular file under `url`, following no symlinks.
    ///
    /// - Returns: zero for a directory that does not exist or cannot be read.
    ///   Sizes are advisory (Settings shows them); an unreadable file is skipped
    ///   rather than reported.
    public static func byteCount(at url: URL) -> Int64 {
        let manager = FileManager.default
        var isDirectory = false
        if let values = try? url.resourceValues(forKeys: [.isDirectoryKey]) {
            isDirectory = values.isDirectory ?? false
        } else {
            return 0
        }
        if isDirectory == false {
            return fileSize(of: url)
        }
        guard let enumerator = manager.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]
        ) else {
            return 0
        }
        var total: Int64 = 0
        for case let child as URL in enumerator {
            total += fileSize(of: child)
        }
        return total
    }

    /// Size of one regular file, or zero for anything else.
    public static func fileSize(of url: URL) -> Int64 {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
              values.isRegularFile == true,
              let size = values.fileSize else {
            return 0
        }
        return Int64(size)
    }
}
