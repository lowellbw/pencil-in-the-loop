//
//  InkToolFactory.swift
//  Annotate · Ink
//
//  The one place `InkToolKind` meets PencilKit. Core names the choice and does
//  not import PencilKit; this turns the name into a tool, and turns whatever the
//  user picked in the tool picker back into a name worth persisting
//  (Core/Contracts/AppSettings.swift, `InkToolKind`).
//

import Foundation
import PencilKit
import UIKit
import Core

/// Builds PencilKit tools from stored defaults, and reads them back again.
///
/// **On failure:** total in both directions. A width outside PencilKit's
/// accepted range is clamped, and a tool that is not an inking tool — an eraser,
/// a lasso, anything Apple adds later — reads back as the caller's fallback
/// rather than as nil, so a user who happens to have the eraser selected when
/// the app backgrounds does not lose their pen colour.
public enum InkToolFactory {

    /// Narrowest stroke we will ask PencilKit for.
    public static let minimumWidthPoints: Double = 1

    /// Widest stroke we will ask PencilKit for. Comfortably inside the range
    /// every ink type accepts.
    public static let maximumWidthPoints: Double = 36

    /// The tool a canvas should start with.
    public static func tool(for defaults: InkDefaults) -> PKTool {
        InkToolFactory.inkingTool(for: defaults)
    }

    /// The same thing, typed concretely, for callers that need the ink type.
    public static func inkingTool(for defaults: InkDefaults) -> PKInkingTool {
        let tint = InkPalette.tint(fromHex: defaults.tintHex)
        let width = CGFloat(InkToolFactory.clampedWidth(defaults.widthPoints))
        switch defaults.tool {
        case .pen:
            return PKInkingTool(.pen, color: tint, width: width)
        case .pencil:
            return PKInkingTool(.pencil, color: tint, width: width)
        case .marker:
            return PKInkingTool(.marker, color: tint, width: width)
        case .monoline:
            return PKInkingTool(.monoline, color: tint, width: width)
        case .highlighter:
            // PencilKit has no separate highlighter: the marker is the
            // translucent one, and it is what Notes uses for the yellow
            // swatch (docs/01-design-principles.md § Specific choices).
            return PKInkingTool(.marker, color: tint, width: width)
        }
    }

    /// What to persist after the user changes something in the tool picker.
    ///
    /// - Parameters:
    ///   - tool: whatever `PKToolPicker.selectedTool` now is.
    ///   - fallback: the current defaults, returned unchanged for tools that
    ///     carry no colour or width — erasers and the lasso.
    public static func defaults(from tool: PKTool, fallback: InkDefaults) -> InkDefaults {
        guard let inking = tool as? PKInkingTool else { return fallback }
        return InkDefaults(
            tool: InkToolFactory.kind(for: inking, fallback: fallback),
            widthPoints: InkToolFactory.clampedWidth(Double(inking.width)),
            tintHex: InkPalette.hex(fromTint: inking.color)
        )
    }

    /// Which stored name best describes an inking tool.
    ///
    /// The marker is ambiguous — both `.marker` and `.highlighter` map onto it —
    /// so the fallback's own choice breaks the tie. A user who selected the
    /// highlighter and then changed its width keeps the highlighter.
    public static func kind(for tool: PKInkingTool, fallback: InkDefaults) -> InkToolKind {
        switch tool.inkType {
        case .pen:
            return .pen
        case .pencil:
            return .pencil
        case .monoline:
            return .monoline
        case .marker:
            return fallback.tool == .highlighter ? .highlighter : .marker
        default:
            // A crayon, a fountain pen, or whatever ships next. Nothing is lost:
            // the tool is live on the canvas either way, this only decides what
            // gets written into settings for next launch.
            return fallback.tool
        }
    }

    /// A width PencilKit will accept.
    public static func clampedWidth(_ width: Double) -> Double {
        guard width.isFinite else { return InkDefaults.standard.widthPoints }
        return min(max(width, InkToolFactory.minimumWidthPoints), InkToolFactory.maximumWidthPoints)
    }
}
