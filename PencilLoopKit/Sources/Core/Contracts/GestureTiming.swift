//
//  GestureTiming.swift
//  Core · Contracts
//
//  The two durations that decide what a press means (docs/04-flows.md § F4).
//
//  They were statics on `VoiceRecordingMachine` in Annotate. Wave 2's gesture
//  recogniser needs `longPressDuration` to decide when to open the popover, and
//  a recogniser in AppUI cannot reach into Annotate's state machine for a
//  number without either duplicating it or coupling the two. A constant used in
//  two modules belongs here (STYLE.md § 9).
//

import Foundation

/// How long a press has to last before it means something.
///
/// **Never fails.** Two constants; there is nothing to be unavailable.
public enum GestureTiming {

    /// Below this, a press-and-hold is a mis-touch: recording is discarded and
    /// nothing is written (docs/04-flows.md § F4).
    ///
    /// 0.3s is short enough that a deliberate quick note survives and long
    /// enough that a palm brushing the screen does not open a comment.
    public static let minimumHoldDuration: TimeInterval = 0.3

    /// How long a finger or pencil must rest before a long press fires and the
    /// comment popover opens.
    ///
    /// Deliberately longer than `minimumHoldDuration`: the gesture has to have
    /// been recognised before the recording it starts can be counted as held.
    public static let longPressDuration: TimeInterval = 0.4
}
