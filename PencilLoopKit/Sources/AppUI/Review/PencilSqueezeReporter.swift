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
//  ─── WHY THIS REPORTS ONE EVENT AND NOT TWO ──────────────────────────────────
//  It used to report `onBegan` and `onEnded`, so the sheet could treat a squeeze
//  as press-and-hold: squeeze to start dictating, let go to stop. The phase enum
//  invites that reading — `began`, `changed`, `ended`, `cancelled` is the
//  vocabulary of a continuous gesture, and holding one is the obvious way to
//  talk without putting the Pencil down.
//
//  It does not survive contact with the system. A recording begun that way ended
//  on its own, a few seconds in, with the squeeze still held. The system is
//  *recognising* a squeeze, not relaying a sensor: SwiftUI's mirror of this API
//  spells the same thing out, offering `active`, `ended` and `failed` — where
//  `failed` is "started squeezing but failed to successfully complete the
//  gesture". A gesture with a completion criterion is not a hold, and how long
//  one may be sustained before the system decides for you is not ours to set.
//  Apple's own guidance (WWDC24 § Squeeze the most out of Apple Pencil) is to
//  "treat squeeze as a single gesture that performs a discrete action", and
//  every shipping app that uses squeeze — Procreate, Notability, Concepts, Notes
//  — summons something with it and releases immediately.
//
//  So the squeeze is discrete here, and the sheet toggles on it. Nothing is held,
//  so there is nothing for the system to take away mid-sentence.
//
//  **Only `ended` acts.** It is the phase that means "recognised" — the header
//  defines it as a continuous gesture ending *or* a discrete one being
//  recognised. `cancelled` is deliberately ignored rather than folded in as it
//  once was: a gesture the system abandoned is one the user did not complete,
//  and toggling a microphone on the strength of it is how a recording starts
//  that nobody asked for. Under press-and-hold the opposite rule was correct,
//  because there the risk was a mic left live; a toggle has no such state to
//  unwind.
//
//  **On an iPad with no Pencil Pro:** the squeeze never arrives and nothing
//  else changes. Every path it offers is reachable by holding
//  (docs/01-design-principles.md rule 5).
//

import SwiftUI
import UIKit

/// Installs a `UIPencilInteraction` and reports completed squeezes.
///
/// Renders nothing and occupies no space; put it in a `.background`.
struct PencilSqueezeReporter: UIViewRepresentable {

    /// A squeeze was completed. Called once per squeeze, and never for one the
    /// system abandoned.
    let onSqueeze: () -> Void

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: CGRect.zero)
        view.isUserInteractionEnabled = false
        let interaction = UIPencilInteraction()
        interaction.delegate = context.coordinator
        view.addInteraction(interaction)
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        // The closure is captured fresh on every SwiftUI update so the
        // coordinator does not call into a stale copy of the sheet's state.
        context.coordinator.onSqueeze = onSqueeze
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onSqueeze: onSqueeze)
    }

    /// Holds the delegate conformance, because a `UIViewRepresentable` is a
    /// value and `UIPencilInteraction` needs an object to talk to.
    @MainActor
    final class Coordinator: NSObject, UIPencilInteractionDelegate {

        var onSqueeze: () -> Void

        init(onSqueeze: @escaping () -> Void) {
            self.onSqueeze = onSqueeze
        }

        func pencilInteraction(
            _ interaction: UIPencilInteraction,
            didReceiveSqueeze squeeze: UIPencilInteraction.Squeeze
        ) {
            let name: String
            switch squeeze.phase {
            case .began: name = "began"
            case .changed: name = "changed"
            case .ended: name = "ended"
            case .cancelled: name = "cancelled"
            @unknown default: name = "unknown"
            }
            plsq("phase=\(name) t=\(squeeze.timestamp) hover=\(squeeze.hoverPose != nil)")

            switch squeeze.phase {
            case .ended:
                onSqueeze()
            case .began, .changed, .cancelled:
                break
            @unknown default:
                break
            }
        }
    }
}
