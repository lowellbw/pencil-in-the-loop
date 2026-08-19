//
//  AppSettings.swift
//  Core · Contracts
//
//  Everything Settings can change (docs/02-spec.md § S6 — "deliberately
//  short"). Four types in one file; listed in tooling/lint/style_allowlist.txt.
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

    public init(
        syncFolderBookmark: Data? = nil,
        syncFolderDisplayName: String? = nil,
        pageTint: PageTint = .none,
        ink: InkDefaults = .standard,
        transcriptionLocaleIdentifier: String = AppSettings.defaultTranscriptionLocaleIdentifier,
        sendInkedPagesAsImages: Bool = true,
        hasCompletedFirstRun: Bool = false
    ) {
        self.syncFolderBookmark = syncFolderBookmark
        self.syncFolderDisplayName = syncFolderDisplayName
        self.pageTint = pageTint
        self.ink = ink
        self.transcriptionLocaleIdentifier = transcriptionLocaleIdentifier
        self.sendInkedPagesAsImages = sendInkedPagesAsImages
        self.hasCompletedFirstRun = hasCompletedFirstRun
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
