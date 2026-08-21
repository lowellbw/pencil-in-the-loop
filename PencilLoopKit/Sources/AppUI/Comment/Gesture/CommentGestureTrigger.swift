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

    /// A Pencil Pro squeeze was completed, anchored at the hover point when
    /// hovering. A secondary trigger and never the only way in
    /// (docs/01-design-principles.md rule 5).
    ///
    /// **One case, not three.** A squeeze used to arrive as began/ended/
    /// cancelled so it could be held like a long press, and a recording begun
    /// that way ended on its own a few seconds in with the squeeze still held.
    /// The system recognises a squeeze rather than relaying a sensor — SwiftUI's
    /// mirror of the API offers `active`, `ended` and `failed`, where `failed`
    /// is a squeeze that never completed — so how long one may be sustained is
    /// not ours to decide. Apple's guidance is to treat it as a single discrete
    /// action (WWDC24 § Squeeze the most out of Apple Pencil).
    ///
    /// So a squeeze *toggles*: once to start talking, once to stop. Holding is
    /// still hold-to-talk, and it is still the long press, which is a gesture
    /// the app owns end to end.
    case squeezeToggled(point: CGPoint)

    /// Where this trigger happened, when it happened somewhere.
    public var point: CGPoint? {
        switch self {
        case let .armed(point): return point
        case let .holdBegan(point): return point
        case let .squeezeToggled(point): return point
        case .armingEnded, .holdEnded, .holdCancelled:
            return nil
        }
    }
}
