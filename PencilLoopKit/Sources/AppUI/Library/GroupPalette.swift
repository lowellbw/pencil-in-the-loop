//
//  GroupPalette.swift
//  AppUI · Library
//
//  A colour per group, so the sections are told apart at a glance
//  (docs/02-spec.md § S1).
//
//  Derived from the name rather than stored. A colour nobody chose is one
//  nobody has to maintain: no picker, no migration, no settings field, and a
//  group made by a sender looks the same on every device that sees it. The
//  trade-off is that renaming a group changes its colour, which is visible and
//  self-explanatory in a way a stored-but-stale colour would not be.
//

import SwiftUI
import Core

/// The colours the Library draws groups in.
public enum GroupPalette {

    /// System colours only (docs/01-design-principles.md § 1), chosen to stay
    /// apart from the two colours that already mean something here:
    ///
    /// - **no green**, which means pinned;
    /// - **no accent**, which a `List` draws selection in.
    ///
    /// Red is left out as well: nothing here is an error, and a red section
    /// heading reads like one.
    static let colours: [Color] = [
        .blue, .orange, .purple, .pink, .teal, .indigo, .brown, .mint, .cyan, .yellow
    ]

    /// The colour for one group.
    ///
    /// Stable across launches and across devices: the index comes from a hash
    /// written out here rather than from `hashValue`, which Swift seeds
    /// randomly per process — using it would give a group a different colour
    /// every time the app started.
    ///
    /// Keyed on `DocumentGroups`' own matching rule, so two spellings of one
    /// group are one colour.
    public static func colour(for name: String) -> Color {
        let key = AppSettings.DocumentGroups.matchingKey(for: name)
        return colours[Int(GroupPalette.hash(key) % UInt64(colours.count))]
    }

    /// FNV-1a, 64-bit. Small, stable, and good enough to spread a dozen names
    /// across ten colours — which is the whole requirement.
    private static func hash(_ text: String) -> UInt64 {
        var value: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            value ^= UInt64(byte)
            value = value &* 0x0000_0100_0000_01B3
        }
        return value
    }
}
