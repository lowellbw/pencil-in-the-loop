//
//  CommentMarkerView.swift
//  AppUI · Comment · Markers
//
//  "A small filled circle in the page margin, accent-tinted, ~16pt. Not a
//  speech bubble, not a number badge unless there are several on a line."
//  (docs/01-design-principles.md)
//

import SwiftUI
import UIKit

/// The dot in the margin.
///
/// One circle, the app's accent colour, and a numeral only when it stands for
/// more than one comment. There is no icon in it: a speech bubble would say
/// "message" when the thing it marks is a note, and at 16pt a glyph is a smudge
/// anyway.
///
/// The diameter scales with Dynamic Type through `UIFontMetrics`, because a
/// tap target that stays 16pt while the text around it doubles is a tap target
/// nobody with large text can hit.
///
/// **Never fails.** A shape and, at most, two digits.
public struct CommentMarkerView: View {

    /// How many comments this marker stands for.
    public var count: Int

    /// True while this marker's popover is open, which lifts it slightly the
    /// way a selected row does.
    public var isSelected: Bool

    /// Unscaled diameter. Defaults to the layout's, and is scaled for Dynamic
    /// Type here rather than by the layout, which works in a page's coordinate
    /// space and has no view to ask.
    public var diameter: CGFloat

    public init(
        count: Int = 1,
        isSelected: Bool = false,
        diameter: CGFloat = CommentMarkerLayout.Metrics.standard.diameter
    ) {
        self.count = count
        self.isSelected = isSelected
        self.diameter = diameter
    }

    public var body: some View {
        let size = UIFontMetrics.default.scaledValue(for: diameter)
        Circle()
            .fill(Color.accentColor)
            .overlay {
                if count > 1 {
                    Text(count.formatted())
                        .font(.caption2)
                        .fontWeight(.semibold)
                        .monospacedDigit()
                        .minimumScaleFactor(0.6)
                        .foregroundStyle(Color.white)
                        .padding(1)
                }
            }
            .overlay {
                // The selected state is a ring, not a colour change: the accent
                // is the only saturated colour in the app chrome and a second
                // one would be a second brand colour.
                Circle()
                    .strokeBorder(Color.white, lineWidth: isSelected ? 2 : 0)
            }
            .frame(width: size, height: size)
            // A 16pt dot with a 44pt target around it, invisible: the minimum
            // the human interface guidelines allow, and the difference between
            // a marker you can tap with a Pencil and one you stab at.
            .frame(width: max(44, size), height: max(44, size))
            .contentShape(.rect)
            .accessibilityLabel(accessibilityLabel)
            .accessibilityAddTraits(.isButton)
    }

    private var accessibilityLabel: String {
        count > 1 ? "\(count) comments" : "Comment"
    }
}

#Preview("One comment") {
    CommentMarkerView()
        .padding()
}

#Preview("Several on a line") {
    VStack(spacing: 24) {
        CommentMarkerView(count: 2)
        CommentMarkerView(count: 3, isSelected: true)
        CommentMarkerView(count: 12)
    }
    .padding()
}
