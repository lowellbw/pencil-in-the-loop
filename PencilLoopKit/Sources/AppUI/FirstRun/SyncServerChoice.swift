//
//  SyncServerChoice.swift
//  AppUI · FirstRun
//
//  Adopting a relay the user typed in, in one place. First run offers it as the
//  alternative to a folder and Settings offers it again, and doing the checking
//  twice in two files is how two screens end up disagreeing about what a valid
//  address is.
//
//  The sibling of `SyncFolderChoice`, and deliberately the same shape.
//

import Foundation
import Core

/// Turns a typed URL and token into something worth trying.
///
/// **On failure:** throws `PencilLoopError.folderUnavailable(reason:)` with a
/// sentence a person can read and act on, because every failure here is
/// something they typed and can fix. Nothing is persisted and no request is
/// made until it passes.
public enum SyncServerChoice {

    /// Checks an address before anything is stored or contacted.
    ///
    /// **`https` only, and no App Transport Security exception.** Rejecting
    /// `http://` in one testable function is a much better trade than adding an
    /// exception to `Info.plist`, which would weaken every connection the app
    /// ever makes so that one person could use a box on their desk. If that box
    /// matters, it can have a certificate.
    ///
    /// - Returns: the URL, with any trailing slash removed so that paths built
    ///   from it cannot double up.
    /// - Throws: `.folderUnavailable(reason:)` for empty text, a scheme that is
    ///   not `https`, a missing host, or a blank token.
    public nonisolated static func validate(urlText: String, token: String) throws -> URL {
        let trimmed = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else {
            throw PencilLoopError.folderUnavailable(reason: "Enter the address of your relay.")
        }

        // A bare host is what people type, so read it as https rather than
        // refusing it on a technicality.
        let text = trimmed.contains("://") ? trimmed : "https://\(trimmed)"

        guard let url = URL(string: text), let scheme = url.scheme?.lowercased() else {
            throw PencilLoopError.folderUnavailable(
                reason: "That is not an address this iPad can reach."
            )
        }
        guard scheme == "https" else {
            throw PencilLoopError.folderUnavailable(
                reason: "The address has to start with https, so what you send is encrypted on the way."
            )
        }
        guard let host = url.host(), host.isEmpty == false else {
            throw PencilLoopError.folderUnavailable(
                reason: "That address has no server name in it."
            )
        }
        guard token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            throw PencilLoopError.folderUnavailable(
                reason: "Enter the access token your relay printed when it was set up."
            )
        }

        return SyncServerChoice.withoutTrailingSlash(url)
    }

    /// The token, with the whitespace a paste tends to bring with it removed.
    public nonisolated static func cleaned(token: String) -> String {
        token.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// One line a person can read, for a status row or an inline message.
    ///
    /// The same treatment `SyncFolderChoice` gives folder errors, so the two
    /// paths report failure in one voice.
    public nonisolated static func describe(_ error: any Error) -> String {
        if let known = error as? PencilLoopError {
            return known.message
        }
        return error.localizedDescription
    }

    private nonisolated static func withoutTrailingSlash(_ url: URL) -> URL {
        var text = url.absoluteString
        while text.hasSuffix("/"), text.count > 1 {
            text.removeLast()
        }
        return URL(string: text) ?? url
    }
}
