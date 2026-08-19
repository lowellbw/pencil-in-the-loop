//
//  InkToolPickerController.swift
//  Annotate · Ink
//
//  `PKToolPicker` in its floating iPadOS form, summoned from the toolbar and
//  dismissed by tapping away. Never pinned, never visible until asked for
//  (docs/01-design-principles.md § 4 and § Specific choices).
//
//  The toolbar button belongs to Wave 2; this is what it drives.
//

import Foundation
import PencilKit
import UIKit
import Core

/// Owns the reader's one tool picker.
///
/// One picker for the whole reader, not one per page: the picker follows a
/// first responder — in practice the `PDFView` or the reader's own view, not any
/// individual canvas — and every visible canvas is registered as an observer, so
/// they all share whatever the user selects. That is what stops the tool
/// resetting as pages recycle underneath it.
///
/// **On failure:** every member is total. Asking to show the picker for a
/// responder that will not accept first responder status leaves the picker
/// hidden and logs it; there is no error to surface, because the tool picker is
/// a convenience and ink works without it — the canvas already has a tool from
/// `AppSettings.ink`.
@MainActor
public final class InkToolPickerController: NSObject, PKToolPickerObserver {

    /// The picker. Exposed for the rare caller that needs to read
    /// `selectedTool` directly; prefer `onDefaultsChange`.
    public let picker: PKToolPicker

    /// Whether the picker is currently being shown.
    public private(set) var isVisible = false

    /// Fires when the user changes tool, width or colour, with the value to
    /// persist through `SettingsStoring`. Wave 2 wires this to settings.
    public var onDefaultsChange: ((InkDefaults) -> Void)?

    private var defaults: InkDefaults

    /// - Parameter defaults: the stored ink defaults (`AppSettings.ink`).
    public init(defaults: InkDefaults = .standard) {
        self.picker = PKToolPicker()
        self.defaults = defaults
        super.init()
        self.picker.selectedTool = InkToolFactory.tool(for: defaults)

        // The canvases render with a forced light appearance so ink is not
        // inverted over the page (see PageCanvasController). The swatches have
        // to agree, or the user picks a colour and gets a different one.
        self.picker.colorUserInterfaceStyle = .light
        self.picker.addObserver(self)
    }

    /// Registers a canvas so it follows the picker's selection.
    ///
    /// Call it for every canvas as it is created; the pool does this.
    public func attach(_ canvasView: PKCanvasView) {
        self.picker.addObserver(canvasView)
        canvasView.tool = self.picker.selectedTool
    }

    /// Unregisters a canvas. Call when a canvas is discarded for good, not when
    /// it is recycled — a recycled canvas wants to keep following the picker.
    public func detach(_ canvasView: PKCanvasView) {
        self.picker.removeObserver(canvasView)
    }

    /// Shows or hides the picker.
    ///
    /// - Parameters:
    ///   - visible: what the toolbar button just asked for.
    ///   - responder: the view the picker attaches to. The reader's PDF view is
    ///     the right choice: it outlives every page, so the picker does not
    ///     vanish when a canvas recycles.
    public func setVisible(_ visible: Bool, for responder: UIResponder) {
        if visible, !responder.isFirstResponder {
            guard responder.canBecomeFirstResponder else {
                InkLog.canvas.error("Tool picker was asked to appear for a responder that cannot become first responder; leaving it hidden.")
                return
            }
            _ = responder.becomeFirstResponder()
        }
        self.picker.setVisible(visible, forFirstResponder: responder)
        self.isVisible = visible
    }

    /// Toolbar-button behaviour: summon it, or put it away.
    public func toggle(for responder: UIResponder) {
        self.setVisible(!self.isVisible, for: responder)
    }

    /// The current ink defaults, as last selected.
    public var currentDefaults: InkDefaults {
        self.defaults
    }

    // MARK: - PKToolPickerObserver

    public func toolPickerSelectedToolDidChange(_ toolPicker: PKToolPicker) {
        let updated = InkToolFactory.defaults(from: toolPicker.selectedTool, fallback: self.defaults)
        self.defaults = updated
        self.onDefaultsChange?(updated)
    }

    public func toolPickerVisibilityDidChange(_ toolPicker: PKToolPicker) {
        // The user can dismiss the picker themselves by tapping away, so the
        // toolbar button's idea of the state has to come from here rather than
        // from the last thing it asked for.
        self.isVisible = toolPicker.isVisible
    }
}
