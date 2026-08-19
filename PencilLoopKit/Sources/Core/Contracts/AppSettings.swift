//
//  AppSettings.swift
//  Core · Contracts
//
//  Everything Settings can change (docs/02-spec.md § S6 — "deliberately
//  short"). Five types in one file; listed in tooling/lint/style_allowlist.txt.
//
//  A value type, not a store: `SettingsStoring` owns persistence. Passing the
//  whole struct around means a view that reads two settings makes one call, and
//  a preview can hand over a literal.
//

import Foundation

/// The complete user-facing configuration.
public struct AppSettings: Codable, Sendable, Hashable {

    /// Security-scoped bookmark for the sync root. Nil means first run has not
    /// happened — the app shows S0 and nothing else.
    public var syncFolderBookmark: Data?

    /// Last known display name of the sync folder, so Settings can name it
    /// without resolving the bookmark.
    public var syncFolderDisplayName: String?

    public var pageTint: PageTint

    public var ink: InkDefaults

    /// BCP-47 identifier for speech, e.g. `en-GB`. Frozen as a string rather
    /// than a `Locale` because it is persisted and must round-trip exactly.
    public var transcriptionLocaleIdentifier: String

    /// Default for the review sheet's "Inked pages" toggle.
    public var sendInkedPagesAsImages: Bool

    /// Set once S0 completes. Guards the whole first-run path.
    public var hasCompletedFirstRun: Bool

    // MARK: - The server transport
    //
    // Three Optionals, and they are Optional for a reason that is written out
    // in full above `init(from:)`. Read `transport`, never `syncTransport`.

    /// Which transport carries documents, or nil in a settings blob written
    /// before the relay existed — which is every blob on every device that
    /// installed the app before this build.
    ///
    /// **When it is nil:** `transport` answers `.folder`, so an existing
    /// install keeps syncing exactly as it did yesterday.
    public var syncTransport: SyncTransport?

    /// The relay's base URL as the user typed it, e.g.
    /// `https://relay.example.com`. Nil until a server is adopted.
    ///
    /// A string rather than a `URL` because it is persisted and has to
    /// round-trip byte for byte; `serverBaseURL` is the parsed view.
    public var serverBaseURLString: String?

    /// Last known display name for the server, so Settings can name it without
    /// showing a URL.
    ///
    /// **When it is nil:** there is nothing friendlier to show and the caller
    /// falls back to the host from `serverBaseURL`.
    public var serverDisplayName: String?

    public init(
        syncFolderBookmark: Data? = nil,
        syncFolderDisplayName: String? = nil,
        pageTint: PageTint = .none,
        ink: InkDefaults = .standard,
        transcriptionLocaleIdentifier: String = AppSettings.defaultTranscriptionLocaleIdentifier,
        sendInkedPagesAsImages: Bool = true,
        hasCompletedFirstRun: Bool = false,
        syncTransport: SyncTransport? = nil,
        serverBaseURLString: String? = nil,
        serverDisplayName: String? = nil
    ) {
        self.syncFolderBookmark = syncFolderBookmark
        self.syncFolderDisplayName = syncFolderDisplayName
        self.pageTint = pageTint
        self.ink = ink
        self.transcriptionLocaleIdentifier = transcriptionLocaleIdentifier
        self.sendInkedPagesAsImages = sendInkedPagesAsImages
        self.hasCompletedFirstRun = hasCompletedFirstRun
        self.syncTransport = syncTransport
        self.serverBaseURLString = serverBaseURLString
        self.serverDisplayName = serverDisplayName
    }

    /// A fresh install.
    public static let initial = AppSettings()

    /// British English. The app's own spelling is British throughout; the
    /// default recogniser locale should match what the user is most likely
    /// dictating.
    public static let defaultTranscriptionLocaleIdentifier = "en-GB"

    /// `transcriptionLocaleIdentifier` as a `Locale`, for the transcriber.
    public var transcriptionLocale: Locale {
        Locale(identifier: transcriptionLocaleIdentifier)
    }

    /// The transport in force.
    ///
    /// **When `syncTransport` is absent or unreadable:** `.folder`. Every
    /// install that predates the relay lands here, and so does any settings
    /// blob a future build writes a transport this build has never heard of.
    public var transport: SyncTransport {
        syncTransport ?? .folder
    }

    /// `serverBaseURLString`, parsed.
    ///
    /// **When it fails:** nil — the string is absent, empty, or not a URL. Nil
    /// means the server transport has nowhere to talk to, and the recovery is
    /// to put the user back in front of the server form. It does not check the
    /// scheme: rejecting `http://` happens in one function on the way in, not
    /// on every read of this property.
    public var serverBaseURL: URL? {
        guard let serverBaseURLString, serverBaseURLString.isEmpty == false else { return nil }
        return URL(string: serverBaseURLString)
    }

    // MARK: - Codable

    /// The keys this struct is persisted under. Named explicitly so that
    /// `init(from:)` below cannot drift away from a synthesised set.
    private enum CodingKeys: String, CodingKey {
        case syncFolderBookmark
        case syncFolderDisplayName
        case pageTint
        case ink
        case transcriptionLocaleIdentifier
        case sendInkedPagesAsImages
        case hasCompletedFirstRun
        case syncTransport
        case serverBaseURLString
        case serverDisplayName
    }

    /// Decodes settings written by *any* build of this app, including one that
    /// had never heard of the field you are about to add.
    ///
    /// ─── READ THIS BEFORE ADDING A FIELD ─────────────────────────────────────
    /// `AppSettingsStore.load` catches every decode failure and falls back to
    /// `AppSettings.initial` — `hasCompletedFirstRun == false`, no bookmark —
    /// which throws the user back to the first-run picker and loses the folder
    /// they chose. Swift's synthesised `Codable` does **not** apply a property
    /// default when a key is absent from the blob, so a single new
    /// non-Optional field would do exactly that to every existing install, on
    /// upgrade, silently.
    ///
    /// So: every new field is Optional, and every field — old ones included —
    /// is read with `decodeIfPresent` and a fallback. Nothing in here can throw
    /// on an absent key, which is the whole point.
    /// ─────────────────────────────────────────────────────────────────────────
    ///
    /// **When it fails:** only if the blob is not a JSON object at all, which
    /// `AppSettingsStore` reports and recovers from by starting fresh.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            syncFolderBookmark: try container.decodeIfPresent(Data.self, forKey: .syncFolderBookmark),
            syncFolderDisplayName: try container.decodeIfPresent(String.self, forKey: .syncFolderDisplayName),
            pageTint: try container.decodeIfPresent(PageTint.self, forKey: .pageTint) ?? .none,
            ink: try container.decodeIfPresent(InkDefaults.self, forKey: .ink) ?? .standard,
            transcriptionLocaleIdentifier: try container.decodeIfPresent(
                String.self,
                forKey: .transcriptionLocaleIdentifier
            ) ?? AppSettings.defaultTranscriptionLocaleIdentifier,
            sendInkedPagesAsImages: try container.decodeIfPresent(
                Bool.self,
                forKey: .sendInkedPagesAsImages
            ) ?? true,
            hasCompletedFirstRun: try container.decodeIfPresent(
                Bool.self,
                forKey: .hasCompletedFirstRun
            ) ?? false,
            syncTransport: try container.decodeIfPresent(SyncTransport.self, forKey: .syncTransport),
            serverBaseURLString: try container.decodeIfPresent(String.self, forKey: .serverBaseURLString),
            serverDisplayName: try container.decodeIfPresent(String.self, forKey: .serverDisplayName)
        )
    }
}

/// Which transport carries documents to and from this iPad.
///
/// Two transports, one library. The folder is the reference transport and the
/// only one that works with no network at all; the relay is opt-in and carries
/// the same bytes (docs/12-relay.md). Switching between them never touches
/// `syncFolderBookmark`, so coming back to the folder costs nothing.
public enum SyncTransport: String, Codable, Sendable, CaseIterable, Hashable {

    /// A folder the user picked, shared by whatever file provider they like.
    case folder

    /// The hosted relay, reached over HTTPS with a bearer token.
    case server

    /// The name the Settings picker shows, alongside every other vocabulary in
    /// this file.
    public var displayName: String {
        switch self {
        case .folder: return "Folder"
        case .server: return "Server"
        }
    }
}

/// Page background wash in the reader.
///
/// Not a hex value in sight: each case maps to a system-derived colour in the UI
/// layer (docs/01-design-principles.md § 1). Core names the choice, AppUI knows
/// what it looks like.
///
/// **There is no Night, and that is a decision rather than an omission.** The
/// four cases here are White (`none`), Cream, Sepia and Grey. docs/01 asked for
/// Books' four — White, Sepia, Gray, Night — and Night is the one that cannot
/// be built the way the same rule requires: the wash is a multiply-blended
/// rectangle over the rendered page (`ReaderTintWash`), multiply can only
/// darken, and darkening a white page towards black takes the black text with
/// it. Every alternative — inverting the raster, a difference or exclusion
/// blend, `colorInvert()` — is inversion under another name, which rule 9
/// forbids for good reasons: it turns figures into negatives and
/// syntax-highlighted code into a colour scheme nobody chose, and it makes
/// graphite ink invisible on the page it was drawn on. docs/01 § 9 is corrected
/// to match, and docs/11 carries what a real Night would cost. Adding a case
/// here is a change request to the lead, and `ReaderTintWash.wash(for:)`
/// switches exhaustively so it fails visibly, in one place, if one ever lands.
public enum PageTint: String, Codable, Sendable, CaseIterable, Hashable {
    case none
    case cream
    case sepia
    case grey

    public var displayName: String {
        switch self {
        case .none: return "None"
        case .cream: return "Cream"
        case .sepia: return "Sepia"
        case .grey: return "Grey"
        }
    }
}

/// What the tool picker starts with.
public struct InkDefaults: Codable, Sendable, Hashable {

    public var tool: InkToolKind

    /// Stroke width in points.
    public var widthPoints: Double

    /// Ink colour as `#RRGGBB`. The one hex value the design principles allow —
    /// ink belongs to the user, not to the brand (docs/01-design-principles.md
    /// § 2).
    public var tintHex: String

    public init(tool: InkToolKind = .pen, widthPoints: Double = 3, tintHex: String = "#1C1C1E") {
        self.tool = tool
        self.widthPoints = widthPoints
        self.tintHex = tintHex
    }

    public static let standard = InkDefaults()
}

/// Which PencilKit tool to select on open.
///
/// Named cases rather than `PKInkingTool.InkType`, because Core does not import
/// PencilKit. Annotate maps these to the real tools in one place.
public enum InkToolKind: String, Codable, Sendable, CaseIterable, Hashable {
    case pen
    case pencil
    case marker
    case monoline
    case highlighter

    /// The name the Settings picker shows, alongside every other vocabulary in
    /// this file and in Identifiers.swift. It lived in `SettingsView` as a
    /// local `switch`, which is one more place for five strings to drift.
    public var displayName: String {
        switch self {
        case .pen: return "Pen"
        case .pencil: return "Pencil"
        case .marker: return "Marker"
        case .monoline: return "Monoline"
        case .highlighter: return "Highlighter"
        }
    }
}
