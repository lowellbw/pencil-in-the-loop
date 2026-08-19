//
//  PencilLoopError.swift
//  Core · Contracts
//
//  Every error that crosses a module boundary. One enum, deliberately: a caller
//  in AppUI catching six different error types from six modules writes six
//  switch statements and gets them subtly wrong.
//
//  Errors that never leave their module do not belong here. This is the
//  vocabulary for things another unit has to *handle*, not a log format.
//

import Foundation

/// A failure worth showing a person, or worth another module deciding about.
///
/// Every case carries enough text to display without further lookup — these
/// strings end up on the Library's error row and in the Settings speech row, so
/// write them as sentences a user could read.
public enum PencilLoopError: Error, Sendable, Hashable {

    // MARK: Folder and sync

    /// The sync root could not be reached: no bookmark, a stale one, or a
    /// provider that has signed out. Never fatal — existing documents stay
    /// readable (docs/02-spec.md § Cross-cutting).
    case folderUnavailable(reason: String)

    /// Security scope could not be opened for a URL we hold a bookmark to.
    case accessDenied(path: String)

    /// A bookmark resolved but is stale and must be re-created.
    case bookmarkStale

    // MARK: Ingest

    /// The inbox directory has neither `document.pdf` nor `source.md`.
    case nothingToIngest(folderName: String)

    /// The PDF exists but PDFKit will not open it.
    case unreadableDocument(folderName: String, reason: String)

    /// Markdown parsing failed. Rare — the parser is tolerant — and the caller
    /// should fall back to rendering the raw text rather than dropping the
    /// document.
    case markdownParseFailed(reason: String)

    /// PDF rendering failed.
    case renderFailed(reason: String)

    /// Copying into the app container failed, so the document cannot be pinned.
    /// The row shows as `.unavailable` rather than disappearing.
    case materialisationFailed(folderName: String, reason: String)

    // MARK: Storage

    /// No document with that id.
    case documentNotFound(id: UUID)

    /// No comment with that id.
    case commentNotFound(id: UUID)

    /// SwiftData refused a write.
    case storeWriteFailed(reason: String)

    // MARK: Export

    /// The bundle could not be built — an unreadable PDF, an ink page that
    /// would not render.
    case bundleBuildFailed(reason: String)

    /// The atomic write failed. The temporary directory is cleaned up before
    /// this is thrown; a half-written bundle must never survive.
    case outboxWriteFailed(reason: String)

    // MARK: Capture

    /// Speech is unavailable. Same reason string as
    /// `SpeechAssetState.unavailable`.
    case speechUnavailable(reason: String)

    /// Microphone or speech-recognition permission was refused. The popover
    /// offers scribble instead.
    case permissionDenied(what: String)

    /// A user-facing sentence for any case. Views may show this directly.
    public var message: String {
        switch self {
        case let .folderUnavailable(reason):
            return "The sync folder is unavailable. \(reason)"
        case let .accessDenied(path):
            return "No permission to read \(path)."
        case .bookmarkStale:
            return "The sync folder has moved. Choose it again in Settings."
        case let .nothingToIngest(folderName):
            return "\(folderName) contains no document to read."
        case let .unreadableDocument(folderName, reason):
            return "\(folderName) could not be opened. \(reason)"
        case let .markdownParseFailed(reason):
            return "The markdown could not be parsed. \(reason)"
        case let .renderFailed(reason):
            return "The document could not be rendered. \(reason)"
        case let .materialisationFailed(folderName, reason):
            return "\(folderName) could not be downloaded. \(reason)"
        case let .documentNotFound(id):
            return "That document is no longer in the library. (\(id.uuidString))"
        case let .commentNotFound(id):
            return "That comment no longer exists. (\(id.uuidString))"
        case let .storeWriteFailed(reason):
            return "The change could not be saved. \(reason)"
        case let .bundleBuildFailed(reason):
            return "The review could not be prepared. \(reason)"
        case let .outboxWriteFailed(reason):
            return "The review could not be written to the folder. \(reason)"
        case let .speechUnavailable(reason):
            return "Dictation is unavailable. \(reason)"
        case let .permissionDenied(what):
            return "\(what) permission was not granted."
        }
    }
}

extension PencilLoopError: LocalizedError {
    public var errorDescription: String? { message }
}
