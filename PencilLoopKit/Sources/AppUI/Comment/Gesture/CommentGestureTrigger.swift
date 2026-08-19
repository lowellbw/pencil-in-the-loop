//
//  CommentGestureTrigger.swift
//  AppUI · Comment · Gesture
//
//  What the gesture layer says, in the vocabulary the recording state machine
//  understands — points and phases, never views and never recognisers.
//

import Foundation
import CoreGraphics

/// One thing the user's hand did.
///
/// Deliberately thin: this is the whole of what `CommentCaptureModel` learns
/// from UIKit, which is what lets the model be read without knowing how a
/// `UILongPressGestureRecognizer` behaves, and lets the recogniser be replaced
/// on a device without touching the model.
///
/// Points are in the coordinate space of `CommentPageResolving.pageHostView`.
///
/// **Never fails.** An enum of facts.
public enum CommentGestureTrigger: Sendable, Hashable {

    /// A stationary Pencil press has lasted `CommentGestureTuning.armingDuration`.
    /// A comment is now plausible: pre-warm capture, show nothing.
    case armed(point: CGPoint)

    /// The press ended or moved before it could become a hold. Nothing
    /// happened, as far as the user is concerned — release the microphone.
    case armingEnded

    /// The full press was recognised. Capture the anchor, cancel the dot, open
    /// the popover, start recording.
    case holdBegan(point: CGPoint)

    /// The Pencil lifted. Under `GestureTiming.minimumHoldDuration` this is a
    /// mis-touch and nothing is left behind; at or over it, the comment saves.
    case holdEnded

    /// The system took the gesture away — a call arrived, the app backgrounded,
    /// a second touch landed. Treated as a cancellation, never as a save.
    case holdCancelled

    /// A Pencil Pro squeeze began, anchored at the hover point when hovering.
    /// A secondary trigger and never the only way in
    /// (docs/01-design-principles.md rule 5).
    case squeezeBegan(point: CGPoint)

    /// The squeeze was released. Same meaning as `holdEnded`.
    case squeezeEnded

    /// The squeeze was interrupted. Same meaning as `holdCancelled`.
    case squeezeCancelled

    /// Where this trigger happened, when it happened somewhere.
    public var point: CGPoint? {
        switch self {
        case let .armed(point): return point
        case let .holdBegan(point): return point
        case let .squeezeBegan(point): return point
        case .armingEnded, .holdEnded, .holdCancelled, .squeezeEnded, .squeezeCancelled:
            return nil
        }
    }
}
