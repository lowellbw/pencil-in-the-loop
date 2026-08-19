//
//  CommentHaptics.swift
//  AppUI · Comment · Model
//
//  Two haptics in the whole feature, and this file exists so that stays true.
//

import Foundation
import UIKit

/// The only two haptics comment capture is allowed to play.
///
/// docs/01-design-principles.md rule 7 is a closed list: `.light` on Pencil Pro
/// squeeze, `.success` when a comment saves, **nothing else**. Not on the
/// popover opening, not on a mis-touch discard, not on delete, not on undo. A
/// feature that buzzes at every step stops meaning anything, and the long-press
/// case deliberately has no haptic at all — the popover appearing is the
/// feedback.
///
/// A namespace rather than an object: there is no state, and an instance would
/// only invite someone to hold a generator open.
///
/// **Never fails.** On a device with no haptic engine, or with system haptics
/// off, these do nothing and say nothing.
public enum CommentHaptics {

    /// `.light` — the squeeze was received. The one confirmation a gesture with
    /// no visible contact point can give.
    public static func squeezeRecognised() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    /// `.success` — a comment reached the store. Played after the write, never
    /// before: this says "saved", and saying it optimistically would make it a
    /// lie on the one occasion it matters.
    public static func commentSaved() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }
}
