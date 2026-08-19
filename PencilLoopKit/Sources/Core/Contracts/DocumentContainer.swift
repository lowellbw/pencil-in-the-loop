//
//  DocumentContainer.swift
//  Core · Contracts
//
//  Where a pinned document lives inside the app container, and how an absolute
//  URL becomes something safe to persist. **One definition, in Core, because
//  three modules need it and only Core is visible to all three.**
//
//  ─── WHY THIS FILE EXISTS ────────────────────────────────────────────────────
//  Wave 1 shipped three container layouts. Storage put documents under
//  `Application Support/PencilLoop/Documents/<folderName>/` and stored paths
//  relative to that root; Sync pinned into
//  `Application Support/PencilLoop/pinned/<folderName>/`; Ingest took an
//  injected `containerRoot` and wrote a third place. Sync pinned the bytes and
//  Ingest then copied them somewhere else, so every document existed twice and
//  the copy Storage recorded was not the copy Sync had verified.
//
//  The failure that made this urgent is quieter than the wasted bytes. The
//  app container's absolute path contains a UUID the system regenerates on
//  reinstall. `StorageLocations.storedPath(for:)` returns a *relative* path for
//  anything under the documents root and an absolute one for anything outside
//  it — so a document Ingest wrote outside that root is recorded by its
//  absolute path, and every one of those documents stops opening after a
//  reinstall (docs/02-spec.md § Everything is always local).
//
//  So: one root, defined here. Sync pins into it, Ingest materialises into it,
//  Storage records paths relative to it. Storage's relative-path discipline is
//  the constraint everything else bends to, and `StorageLocations` in Storage
//  now forwards to this type rather than defining a second opinion.
//
//  ─── WHAT LIVES IN A DOCUMENT DIRECTORY ──────────────────────────────────────
//  `documentDirectory(folderName:)` holds the pinned bytes named by
//  `DocumentFileNames` — `document.pdf`, `source.md`, `sourcemap.json`,
//  `meta.json` — plus Sync's `.pinned.json` completion sidecar, written last.
//  A directory without that sidecar is a copy that did not finish and is
//  re-pinned rather than trusted (`InboxItemPinner`).
//

import Foundation

/// The app container's document layout: one directory per document, named by
/// its inbox `folderName`.
///
/// **On failure:** every member returns a URL rather than throwing. When the
/// system will not hand over Application Support — which should not happen on a
/// device — the temporary directory is used instead, so the app still runs and
/// the failure shows up as an empty library rather than a crash on launch.
///
/// **Never store one of these URLs.** Persist `storedPath(for:)` and resolve it
/// with `url(forStoredPath:)` on every read. The absolute path is not stable
/// across a reinstall; the relative one is.
public enum DocumentContainer {

    /// Container subdirectory for everything this app persists.
    public static let directoryName = "PencilLoop"

    /// Where pinned document folders live, one directory per document.
    public static let documentsDirectoryName = "Documents"

    /// `Application Support/PencilLoop`, created if absent.
    ///
    /// Application Support rather than Caches on purpose: Caches is exactly the
    /// directory the system is allowed to empty, and "never evicted" is the
    /// requirement (docs/02-spec.md § Everything is always local).
    public static func containerRoot() -> URL {
        let manager = FileManager.default
        let base = manager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? manager.temporaryDirectory
        let root = base.appendingPathComponent(directoryName, isDirectory: true)
        ensureDirectory(root)
        return root
    }

    /// `Application Support/PencilLoop/Documents`, created if absent.
    ///
    /// The one root. Sync pins into it, Ingest materialises into it, Storage
    /// records every path relative to it.
    public static func documentsRoot() -> URL {
        let root = containerRoot().appendingPathComponent(documentsDirectoryName, isDirectory: true)
        ensureDirectory(root)
        return root
    }

    /// The pinned directory for one document folder name, e.g.
    /// `…/Documents/2026-08-18-auth-refactor-plan`.
    ///
    /// Not created here — Sync creates it when it copies the bytes in.
    public static func documentDirectory(folderName: String) -> URL {
        documentsRoot().appendingPathComponent(folderName, isDirectory: true)
    }

    /// Turns an absolute URL into the string the store persists.
    ///
    /// - Returns: a path relative to `documentsRoot()` when the URL is inside
    ///   it, and the absolute path otherwise. An absolute result is legal — a
    ///   document pinned somewhere unusual still has to be findable — but it is
    ///   the case that does not survive a reinstall, which is why every writer
    ///   keeps its bytes under `documentsRoot()`.
    public static func storedPath(for url: URL) -> String {
        let root = documentsRoot().standardizedFileURL.path(percentEncoded: false)
        let prefix = root.hasSuffix("/") ? root : root + "/"
        let candidate = url.standardizedFileURL.path(percentEncoded: false)
        if candidate.hasPrefix(prefix) {
            return String(candidate.dropFirst(prefix.count))
        }
        return candidate
    }

    /// The inverse of `storedPath(for:)`.
    ///
    /// - Returns: nil for an empty path. A row with no pinned bytes — one
    ///   recorded by `DocumentStoring.recordIngestFailure(folderName:reason:)`
    ///   — has an empty path, and there is no honest URL to invent for it
    ///   (docs/02-spec.md § S1).
    public static func url(forStoredPath path: String) -> URL? {
        guard !path.isEmpty else { return nil }
        if path.hasPrefix("/") { return URL(fileURLWithPath: path) }
        return documentsRoot().appendingPathComponent(path)
    }

    /// True when `url` sits inside the app's own documents root.
    ///
    /// Every destructive operation checks this first: purging deletes files,
    /// and it must never be able to reach the user's sync folder.
    public static func isInsideDocumentsRoot(_ url: URL) -> Bool {
        // Both sides are stripped of a trailing slash first. `path` used to do
        // that itself; `path(percentEncoded:)` keeps the slash a directory URL
        // carries, so the root's own path arrived here already ending in one,
        // matched the prefix built from it, and the root reported itself as
        // being inside itself — which would make the whole documents directory
        // a legal deletion target.
        let root = DocumentContainer.pathWithoutTrailingSlash(documentsRoot())
        return DocumentContainer.pathWithoutTrailingSlash(url).hasPrefix(root + "/")
    }

    /// A file URL's path with any trailing slash removed, so that two paths can
    /// be compared without a directory URL and a file URL for the same place
    /// disagreeing about their last character.
    private static func pathWithoutTrailingSlash(_ url: URL) -> String {
        var path = url.standardizedFileURL.path(percentEncoded: false)
        while path.count > 1, path.hasSuffix("/") {
            path.removeLast()
        }
        return path
    }

    /// Creates a directory when it is not already there, ignoring the failure.
    ///
    /// A directory that cannot be created shows up as the read that follows it
    /// failing, with a reason, rather than as a throw from a path accessor that
    /// every caller would have to handle.
    private static func ensureDirectory(_ url: URL) {
        let manager = FileManager.default
        if manager.fileExists(atPath: url.path(percentEncoded: false)) { return }
        try? manager.createDirectory(at: url, withIntermediateDirectories: true)
    }
}
