//
//  ShareOutcome.swift
//  ReviewShareExtension
//
//  What one run of the extension amounts to, and the three sentences it is
//  allowed to say when it did not work.
//
//  The messages live here rather than on the view controller because the
//  failure paths are decided deep inside a file-provider callback, off the main
//  actor, and a value that carries its own sentence is the only thing that
//  crosses that boundary cleanly.
//

import Foundation
import Core

/// The result of trying to stage one shared item.
///
/// **There is no partial success.** `ShareStagingWriter` builds into a hidden
/// `.tmp` sibling and renames, so either a complete directory landed in
/// `staging/` or nothing did. `.failed` therefore always means the user's
/// document is still exactly where they shared it from, and nothing has been
/// lost.
enum ShareOutcome: Sendable {

    /// A directory landed in `staging/`. The title is what `meta.json` records
    /// and what the confirmation shows.
    case staged(title: String)

    /// Nothing was written. The message is a sentence to put in front of the
    /// user verbatim.
    case failed(message: String)

    /// The share sheet handed us something we do not read.
    static let unsupported = ShareOutcome.failed(
        message: "Review takes PDFs, markdown files and web links. There was nothing of that kind to add."
    )

    /// The App Group container could not be reached — an unsigned build, a
    /// device that has never run the app, or a provisioning mismatch.
    static let containerUnavailable = ShareOutcome.failed(
        message: "Review cannot reach its shared storage. Open PencilLoop once, then try sharing again."
    )

    /// The copy itself failed: no space, or a file that went away underneath us.
    static let stagingFailed = ShareOutcome.failed(
        message: "The document could not be saved. Check that there is free space on this iPad, then try sharing it again."
    )

    /// Maps a thrown error onto the sentence the user should read.
    ///
    /// Only the unreachable-container case is worth distinguishing: it is the
    /// one failure a user can actually do something about.
    static func failure(for error: any Error) -> ShareOutcome {
        if let known = error as? PencilLoopError, case .folderUnavailable = known {
            return .containerUnavailable
        }
        return .stagingFailed
    }
}
