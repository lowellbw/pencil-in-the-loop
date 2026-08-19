//
//  ReaderTintWash.swift
//  AppUI · Reader
//
//  Page tints, the Books way: render the page and tint it, never invert it
//  (docs/01-design-principles.md § 9). PDFKit has no tint API, so the wash is a
//  multiply-blended rectangle laid over the page — multiply leaves black text
//  black and turns a white page the colour of the wash, which is exactly what
//  paper does and exactly what inversion does not.
//
//  It sits over the ink as well as over the page, because the ink lives inside
//  the PDF view. That is the right answer rather than a compromise: ink on a
//  cream page should look like ink on a cream page. PencilKit's own lightening
//  is separately disabled — `PageCanvasController` forces
//  `overrideUserInterfaceStyle = .light` so graphite does not become
//  white-on-white (Annotate/Ink/PageCanvasController.swift).
//
//  No hex values: `PageTint` names the choice in Core, and AppUI derives each
//  one from a system colour (docs/01-design-principles.md § 1).
//

import SwiftUI
import Core

/// The wash drawn over the page for a given `PageTint`.
///
/// **On failure:** there is none. Every `PageTint` maps to a wash, and `.none`
/// maps to an invisible one, which the reader skips drawing entirely.
public struct ReaderTintWash {

    /// What to fill the wash rectangle with, before opacity.
    public let fill: Color

    /// How strongly to apply it, 0…1. Deliberately low: a wash you notice is
    /// too strong.
    public let opacity: Double

    /// A VoiceOver-friendly name, taken from Core so the reader and Settings
    /// cannot drift apart.
    public let displayName: String

    public init(fill: Color, opacity: Double, displayName: String) {
        self.fill = fill
        self.opacity = opacity
        self.displayName = displayName
    }

    /// Whether there is anything to draw. `.none` is not a transparent wash that
    /// costs a compositing pass; it is no wash at all.
    public var isVisible: Bool {
        self.opacity > 0
    }

    /// The wash for a stored setting.
    ///
    /// - Note: four tints, and no Night. docs/01-design-principles.md § 9 asked
    ///   for Books' White, Sepia, Gray and Night; the app ships White
    ///   (`.none`), Cream, Sepia and Grey, and § 9 has been corrected to say so.
    ///   A night wash cannot be multiplied — multiply only darkens, so it takes
    ///   the black text down with the white page — and every other route is
    ///   inversion, which the same rule forbids for good reasons: negatives
    ///   instead of figures, a colour scheme nobody chose instead of syntax
    ///   highlighting, and graphite ink invisible on the page it was drawn on.
    ///   What a real Night would cost is written down in
    ///   docs/11-backlog.md § B11. Adding a case to `PageTint` is a change
    ///   request to the lead, so the switch below stays exhaustive and will fail
    ///   to compile — visibly, in one place — on the day one lands.
    public static func wash(for tint: PageTint) -> ReaderTintWash {
        switch tint {
        case .none:
            return ReaderTintWash(fill: .clear, opacity: 0, displayName: tint.displayName)
        case .cream:
            return ReaderTintWash(
                fill: Color(uiColor: .systemYellow),
                opacity: 0.10,
                displayName: tint.displayName
            )
        case .sepia:
            return ReaderTintWash(
                fill: Color(uiColor: .systemBrown),
                opacity: 0.16,
                displayName: tint.displayName
            )
        case .grey:
            return ReaderTintWash(
                fill: Color(uiColor: .systemGray),
                opacity: 0.12,
                displayName: tint.displayName
            )
        }
    }
}
