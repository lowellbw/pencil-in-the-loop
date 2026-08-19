//
//  PencilCommentGesture.swift
//  AppUI · Comment · Gesture
//
//  The recogniser that sits alongside `PKCanvasView` and never gets in its way.
//  Configuration only — the decisions live in `CommentGestureController`.
//

import Foundation
import UIKit

/// A stationary, Pencil-only long press, configured so that the canvas
/// underneath it never notices it is there.
///
/// **Why it must not delay touches.** A Pencil held still for
/// `GestureTiming.longPressDuration` is, to `PKCanvasView`, a perfectly good
/// stroke — a dot — and it has already been drawn by the time the press is
/// recognised. The obvious fix is `delaysTouchesBegan`, holding touches back
/// until this gesture resolves; that puts 400ms of work on the touch path,
/// which docs/03-architecture.md forbids outright, and ink latency is the one
/// budget with no slack in it. So this recogniser observes and never
/// intercepts: `delaysTouchesBegan`, `delaysTouchesEnded` and
/// `cancelsTouchesInView` are all off, the canvas receives every touch at full
/// speed, and the dot is taken back afterwards by `InFlightStrokeCanceller`
/// (docs/02-spec.md § S2).
///
/// **Never fails.** Two instances of this are installed, one to arm and one to
/// trigger; both are inert until a Pencil touches the screen.
public final class PencilCommentGesture: UILongPressGestureRecognizer {

    /// Which half of the press this instance watches.
    public enum Role: Sendable, Hashable {

        /// The short pre-trigger press. Its `.began` means "a comment is now
        /// plausible" and pre-warms capture; nothing is shown and nothing is
        /// recorded.
        case arming

        /// The full press. Its `.began` opens the popover and starts recording.
        case hold
    }

    /// Which half of the press this instance watches.
    public let role: Role

    /// - Parameters:
    ///   - role: which half of the press this instance watches.
    ///   - tuning: supplies the duration and the movement allowance.
    ///   - target: the controller.
    ///   - action: its handler.
    public init(
        role: Role,
        tuning: CommentGestureTuning,
        target: Any?,
        action: Selector?
    ) {
        self.role = role
        super.init(target: target, action: action)

        minimumPressDuration = role == .arming ? tuning.armingDuration : tuning.holdDuration
        allowableMovement = role == .arming
            ? tuning.armingAllowableMovement
            : tuning.allowableMovement
        numberOfTouchesRequired = 1
        numberOfTapsRequired = 0

        // Pencil only. A finger long-press on text belongs to the system text
        // selection menu, which reaches the same popover through the "Comment"
        // item (docs/02-spec.md § S2) — one gesture, two inputs, no conflict.
        allowedTouchTypes = [NSNumber(value: UITouch.TouchType.pencil.rawValue)]

        // The three lines this whole file exists for.
        delaysTouchesBegan = false
        delaysTouchesEnded = false
        cancelsTouchesInView = false
    }

    /// Where the press is now, in the recogniser's view's coordinate space.
    ///
    /// - Returns: nil when the recogniser is not attached to a view, which is
    ///   the state between documents.
    public var pointInHostView: CGPoint? {
        guard let view else { return nil }
        return location(in: view)
    }
}
