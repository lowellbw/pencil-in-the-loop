//
//  CommentGestureTuning.swift
//  AppUI · Comment · Gesture
//
//  ─── THE DEVICE-ITERATION DIAL ───────────────────────────────────────────────
//  docs/02-spec.md § S2 calls the Pencil long-press "the top item on the
//  device-iteration list", and says outright to expect the numbers to change.
//  So every number the gesture depends on is here, in one value type, with the
//  reason it has the value it has. Nothing in Gesture/ reads a literal.
//
//  Change one field, rebuild, hand the iPad back. Do not scatter these.
//  ─────────────────────────────────────────────────────────────────────────────
//

import Foundation
import CoreGraphics
import Core

/// Every number the comment gesture depends on, in one place, so that tuning it
/// on a device is a one-line change rather than a search.
///
/// **Two of these numbers are not ours to choose.** `GestureTiming.longPressDuration`
/// (0.4s) and `GestureTiming.minimumHoldDuration` (0.3s) live in Core because the
/// recogniser and `VoiceRecordingMachine` must not drift apart (STYLE.md § 9), and
/// they are read here rather than re-declared. The rest are local judgement calls
/// with no second consumer.
///
/// **Never fails.** A struct of numbers; there is nothing to be unavailable.
public struct CommentGestureTuning: Sendable, Hashable {

    /// How long the Pencil must rest before the popover opens.
    ///
    /// Reads `GestureTiming.longPressDuration` by default and exists as a field
    /// only so a device session can try 0.35 or 0.5 without touching Core.
    /// **If a different value survives the device, the change belongs in
    /// `GestureTiming`, not here** — a permanent local override would be exactly
    /// the drift that constant was moved to Core to prevent.
    public var holdDuration: TimeInterval

    /// How long the Pencil must rest before the microphone is pre-warmed.
    ///
    /// The machine's `touchDown` event means "a comment is now plausible", and
    /// its doc is explicit that it must not fire for every Pencil touch —
    /// inking is a touch too, and opening an audio session on every stroke is
    /// both rude and expensive. So arming is its own, shorter, stationary
    /// press: long enough that a drawing stroke has already moved out of
    /// `allowableMovement`, short enough that the remaining
    /// `holdDuration - armingDuration` covers the 400ms first-token budget
    /// (docs/03-architecture.md § Performance targets).
    public var armingDuration: TimeInterval

    /// How far the Pencil may drift and still count as stationary, in points.
    ///
    /// Tight on purpose: a comment press is a press, and anything that moves is
    /// a stroke. Too loose and slow deliberate strokes open popovers; too tight
    /// and a real hand's tremor cancels the gesture. The single most likely
    /// number to change on a device.
    public var allowableMovement: CGFloat

    /// How far the Pencil may drift and still count as *arming*, in points.
    ///
    /// Tighter than `allowableMovement`, and deliberately so: the two mistakes
    /// are not symmetric. Failing to arm costs a little first-token latency and
    /// nothing else — the popover still opens on time. Arming when the user was
    /// only drawing slowly opens an audio session for the length of a stroke,
    /// which is the exact rudeness `VoiceRecordingMachine.Event.touchDown`
    /// warns about. So this errs towards not arming.
    public var armingAllowableMovement: CGFloat

    /// Whether the dot stroke a stationary press has already started is taken
    /// back when the gesture wins.
    ///
    /// On by default and effectively non-optional in shipping; it is a flag so
    /// that a device session can turn it off for one build and see what the
    /// cancellation itself is costing — if the dot never appears with this
    /// off, the cancel path is doing nothing and should go.
    public var cancelsInFlightStroke: Bool

    /// Whether to re-check, one runloop turn after cancelling, that no stroke
    /// was committed anyway, and restore the pre-press drawing if one was.
    ///
    /// Belt and braces. Disabling the drawing gesture recogniser cancels a
    /// stroke that is still in flight, which is the normal case for a held
    /// press; this catches a build or a device where PencilKit has already
    /// committed the dot by 0.4s. Costs one drawing comparison per comment
    /// gesture and nothing at all per stroke.
    public var verifiesStrokeCancellation: Bool

    /// Whether `UIPencilInteraction` squeeze is offered as a second way in.
    ///
    /// A shortcut for people who already know it and never the only route to
    /// anything (docs/01-design-principles.md rule 5): not every supported iPad
    /// has a Pencil Pro paired, and the squeeze is remappable system-wide, so a
    /// user may have pointed it at something else entirely.
    public var squeezeEnabled: Bool

    /// Whether a hover recogniser tracks the Pencil so a squeeze knows where to
    /// anchor (docs/02-spec.md § S2: "at the current hover point if hovering").
    ///
    /// Hover is free — the recogniser fires only when a Pencil is near the
    /// screen — but it is another recogniser on the touch path's view, so it is
    /// switchable.
    public var hoverTrackingEnabled: Bool

    /// How stale the last hover point may be before a squeeze ignores it and
    /// falls back to the centre of the visible page.
    ///
    /// A Pencil resting in a case reports no hover; one lifted a second ago
    /// reports a point the user is no longer looking at.
    public var hoverFreshness: TimeInterval

    public init(
        holdDuration: TimeInterval = GestureTiming.longPressDuration,
        armingDuration: TimeInterval = 0.12,
        allowableMovement: CGFloat = 6,
        armingAllowableMovement: CGFloat = 4,
        cancelsInFlightStroke: Bool = true,
        verifiesStrokeCancellation: Bool = true,
        squeezeEnabled: Bool = true,
        hoverTrackingEnabled: Bool = true,
        hoverFreshness: TimeInterval = 1.5
    ) {
        self.holdDuration = holdDuration
        self.armingDuration = armingDuration
        self.allowableMovement = allowableMovement
        self.armingAllowableMovement = armingAllowableMovement
        self.cancelsInFlightStroke = cancelsInFlightStroke
        self.verifiesStrokeCancellation = verifiesStrokeCancellation
        self.squeezeEnabled = squeezeEnabled
        self.hoverTrackingEnabled = hoverTrackingEnabled
        self.hoverFreshness = hoverFreshness
    }

    /// What ships until a device says otherwise.
    public static let standard = CommentGestureTuning()

    /// Everything Pencil-specific off: long-press still opens the popover, and
    /// nothing depends on a Pencil Pro or on hover.
    ///
    /// Not a degraded mode — it is what an iPad with a first-generation Pencil
    /// gets, and every feature is still reachable.
    public static let withoutPencilPro = CommentGestureTuning(
        squeezeEnabled: false,
        hoverTrackingEnabled: false
    )
}
