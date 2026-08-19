//
//  RelayDefaults.swift
//  AppUI · Support
//
//  The relay this build ships pointed at, if it ships pointed at one.
//
//  The app is meant to work the moment it is installed — no folder to pick, no
//  address to type, no token to paste. That is what these two values are for.
//  They are set in `Config/Local.xcconfig`, which is not committed, and reach
//  the app through `Info.plist`; a checkout without that file gets nothing here
//  and falls back to the folder picker exactly as before.
//
//  ─── WHY A TOKEN IS IN THE BUNDLE, AND WHAT THAT COSTS ───────────────────────
//  Anyone who can read the app bundle can read this token, and there is no way
//  around that for a credential that has to be there before the user types
//  anything. It is acceptable here because the relay is one person's, holds one
//  person's documents, and is installed only on their own devices — and because
//  the alternative, asking for a token at first run, is the friction this file
//  exists to remove.
//
//  It stops being acceptable the moment a second person installs a build. At
//  that point the token has to be per-user and obtained rather than shipped,
//  and `docs/12-relay.md` § 3 says the same thing about the tenancy boundary.
//

import Foundation
import Core

/// The relay baked into this build.
///
/// A namespace, not an object: it is one fact about the bundle and it cannot
/// change while the app is running.
public enum RelayDefaults {

    /// The address, or nil when this build ships without one.
    ///
    /// **On a malformed value:** nil, and the app behaves as though no relay
    /// were configured — the folder picker, as before. A build setting that is
    /// wrong should cost the default, never the app.
    ///
    /// The stored value carries no scheme, because an xcconfig reads `//` as
    /// the start of a comment and `https://host` would silently truncate to
    /// `https:`. The scheme is put back here, and it is always `https`.
    public static var baseURL: URL? {
        guard let host = string(forKey: "PencilLoopRelayURL") else { return nil }
        let text = host.contains("://") ? host : "https://\(host)"
        guard let url = URL(string: text),
              url.scheme?.lowercased() == "https",
              let name = url.host(), name.isEmpty == false else {
            return nil
        }
        return url
    }

    /// The access token, or nil when this build ships without one.
    public static var token: String? {
        string(forKey: "PencilLoopRelayToken")
    }

    /// Whether this build can reach a relay without being told how.
    ///
    /// Both halves or neither: an address with no token would fail on the first
    /// request, and the honest place to notice that is here rather than in a
    /// status line the user cannot act on.
    public static var isConfigured: Bool {
        baseURL != nil && token != nil
    }

    /// A trimmed, non-empty `Info.plist` string, or nil.
    ///
    /// The empty case is the normal one: `Config/Relay.xcconfig` declares both
    /// keys empty so that a checkout with no local config still substitutes
    /// cleanly rather than leaving `$(PENCILLOOP_RELAY_URL)` in the bundle.
    private static func string(forKey key: String) -> String? {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: key) as? String else {
            return nil
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed.hasPrefix("$(") {
            return nil
        }
        return trimmed
    }
}
