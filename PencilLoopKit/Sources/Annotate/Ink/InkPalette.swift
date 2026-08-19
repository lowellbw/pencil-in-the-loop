//
//  InkPalette.swift
//  Annotate · Ink
//
//  The five ink colours, and the only hardcoded palette permitted anywhere in
//  the app (docs/01-design-principles.md § 1 and § 2 — ink belongs to the user,
//  not to the brand). Everything else in the app uses system values.
//
//  Note the spelling contortions: STYLE.md § 2 bans the word in either spelling
//  from our own symbol names, so these are "tints" throughout.
//

import Foundation
import UIKit

/// The five inks offered in the tool picker: graphite, red, blue, green and a
/// yellow highlighter (docs/01-design-principles.md § Specific choices).
///
/// The hex values are the source of truth and they are deliberately static
/// rather than dynamic system values: ink is content, and content that changed
/// shade between light and dark mode would be a bug, not a feature. `PageTint`
/// handles appearance; ink does not participate.
///
/// **On failure:** every member is total. `palette(forHex:)` returns nil for a
/// value that is not one of the five, and `tint(fromHex:)` falls back to
/// graphite for anything it cannot parse, so a corrupted setting produces
/// visible black ink rather than an invisible stroke.
public enum InkPalette: String, CaseIterable, Sendable {

    case graphite
    case red
    case blue
    case green
    case highlighter

    /// The default, and the value `InkDefaults.standard.tintHex` already carries.
    public static let standard = InkPalette.graphite

    /// `#RRGGBB`, matching the format `InkDefaults.tintHex` persists.
    public var tintHex: String {
        switch self {
        case .graphite: return "#1C1C1E"
        case .red: return "#FF3B30"
        case .blue: return "#007AFF"
        case .green: return "#34C759"
        case .highlighter: return "#FFCC00"
        }
    }

    /// For the VoiceOver label on a swatch (docs/01-design-principles.md § 8).
    public var displayName: String {
        switch self {
        case .graphite: return "Graphite"
        case .red: return "Red"
        case .blue: return "Blue"
        case .green: return "Green"
        case .highlighter: return "Highlighter"
        }
    }

    /// Whether this ink is meant to be laid down with a translucent marker
    /// rather than an opaque nib. Only the highlighter is.
    public var isTranslucent: Bool {
        self == .highlighter
    }

    /// The drawable value, derived from `tintHex` so the two can never disagree.
    public var uiTint: UIColor {
        InkPalette.tint(fromHex: self.tintHex)
    }

    /// The palette entry a persisted hex value names, or nil when the user has
    /// picked something else in the tool picker — which they are allowed to do.
    public static func palette(forHex hex: String) -> InkPalette? {
        let wanted = InkPalette.canonicalHex(hex)
        return InkPalette.allCases.first { $0.tintHex == wanted }
    }

    /// `#RRGGBB` to a drawable value. Anything unparseable comes back as
    /// graphite rather than as clear, because invisible ink is unrecoverable and
    /// black ink is merely wrong.
    public static func tint(fromHex hex: String) -> UIColor {
        guard let packed = InkPalette.packed(hex) else {
            return UIColor(red: 28.0 / 255, green: 28.0 / 255, blue: 30.0 / 255, alpha: 1)
        }
        let red = CGFloat((packed >> 16) & 0xFF) / 255
        let green = CGFloat((packed >> 8) & 0xFF) / 255
        let blue = CGFloat(packed & 0xFF) / 255
        return UIColor(red: red, green: green, blue: blue, alpha: 1)
    }

    /// A drawable value back to `#RRGGBB`, for persisting what the tool picker
    /// ended up on.
    public static func hex(fromTint tint: UIColor) -> String {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        guard tint.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else {
            return InkPalette.graphite.tintHex
        }
        let channels = [red, green, blue].map { channel -> Int in
            let clamped = min(max(channel, 0), 1)
            return Int((clamped * 255).rounded())
        }
        return channels.reduce("#") { partial, channel in
            partial + String(format: "%02X", channel)
        }
    }

    /// Uppercased, `#`-prefixed, three-byte form. `#abc` shorthand is expanded.
    public static func canonicalHex(_ hex: String) -> String {
        guard let packed = InkPalette.packed(hex) else { return InkPalette.graphite.tintHex }
        return "#" + String(format: "%06X", packed)
    }

    /// The 24-bit value behind a hex string, or nil when it is not one.
    private static func packed(_ hex: String) -> Int? {
        var digits = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if digits.hasPrefix("#") {
            digits.removeFirst()
        }
        if digits.count == 3 {
            digits = digits.reduce(into: "") { partial, character in
                partial.append(character)
                partial.append(character)
            }
        }
        guard digits.count == 6, let value = Int(digits, radix: 16) else { return nil }
        return value
    }
}
