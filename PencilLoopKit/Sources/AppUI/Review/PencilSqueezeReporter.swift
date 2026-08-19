//
//  PencilSqueezeReporter.swift
//  AppUI · Review
//
//  A Pencil Pro squeeze, reported into SwiftUI.
//
//  `UIPencilInteraction` is a UIKit interaction and has no SwiftUI equivalent,
//  so this is the smallest possible bridge: an empty view that installs one and
//  calls back. It deliberately knows nothing about what a squeeze means — the
//  review sheet decides that, because the answer depends on where the Pencil is
//  hovering and only the view tree knows.
//
//  ─── WHY IT DOES NOT TRACK HOVER ITSELF ──────────────────────────────────────
//  `CommentGestureController` does both, and has to: it sits on the Reader's
//  page host and needs a *point in page space* to anchor a comment to. Here the
//  question is only "is the Pencil over that section", which SwiftUI answers
//  with `onContinuousHover` on the section itself — correctly, through its own
//  hit-testing, without this having to know the sheet's layout.
//
//  **On an iPad with no Pencil Pro:** the squeeze never arrives and nothing
//  else changes. Every path it offers is reachable by holding
//  (docs/01-design-principles.md rule 5).
//

import SwiftUI
import UIKit

/// Installs a `UIPencilInteraction` and reports squeezes.
///
/// Renders nothing and occupies no space; put it in a `.background`.
struct PencilSqueezeReporter: UIViewRepresentable {

    /// The squeeze started. Called once per squeeze.
    let onBegan: () -> Void

    /// The squeeze finished or was abandoned. Always called after `onBegan`,
    /// which is what lets a caller treat it as press-and-hold without having to
    /// unwind state itself.
    let onEnded: () -> Void

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: CGRect.zero)
        view.isUserInteractionEnabled = false
        let interaction = UIPencilInteraction()
        interaction.delegate = context.coordinator
        view.addInteraction(interaction)
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        // The closures are captured fresh on every SwiftUI update so the
        // coordinator does not call into a stale copy of the sheet's state.
        context.coordinator.onBegan = onBegan
        context.coordinator.onEnded = onEnded
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onBegan: onBegan, onEnded: onEnded)
    }

    /// Holds the delegate conformance, because a `UIViewRepresentable` is a
    /// value and `UIPencilInteraction` needs an object to talk to.
    @MainActor
    final class Coordinator: NSObject, UIPencilInteractionDelegate {

        var onBegan: () -> Void
        var onEnded: () -> Void

        init(onBegan: @escaping () -> Void, onEnded: @escaping () -> Void) {
            self.onBegan = onBegan
            self.onEnded = onEnded
        }

        /// Cancelled is treated exactly as ended.
        ///
        /// A squeeze the system abandons — a call arriving, the Pencil going to
        /// sleep — must still stop whatever the squeeze started. Leaving a
        /// recording running because the gesture ended untidily is the one
        /// outcome worth ruling out.
        func pencilInteraction(
            _ interaction: UIPencilInteraction,
            didReceiveSqueeze squeeze: UIPencilInteraction.Squeeze
        ) {
            switch squeeze.phase {
            case .began:
                onBegan()
            case .ended, .cancelled:
                onEnded()
            case .changed:
                break
            @unknown default:
                break
            }
        }
    }
}
