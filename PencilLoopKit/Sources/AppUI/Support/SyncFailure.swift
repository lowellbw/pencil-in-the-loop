//
//  SyncFailure.swift
//  AppUI · Support
//
//  One line a person can read, when something went wrong.
//
//  This was `SyncFolderChoice.describe(_:)` and outlived the type that held it:
//  the folder transport is gone, but every status row in the app still needs a
//  sentence, and six screens were already calling this one. It sits in Support
//  now because it was never about folders — it is about errors.
//

import Foundation
import Core

/// Turns any error into the sentence a status row shows.
public enum SyncFailure {

    /// One line a person can read, for a status row or an inline message.
    ///
    /// `PencilLoopError` carries display text on every case, which is why the
    /// UI never has to compose an error string of its own
    /// (Core/Contracts/PencilLoopError.swift). Anything else falls back to the
    /// system's own description, which is the best available and never empty.
    public nonisolated static func describe(_ error: any Error) -> String {
        if let known = error as? PencilLoopError {
            return known.message
        }
        return error.localizedDescription
    }
}
