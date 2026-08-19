//
//  InkRecogniserFactory.swift
//  Annotate · Ink
//
//  The one place the availability dance happens. Everywhere else in the app
//  holds an `any HandwritingRecognising` and neither knows nor cares which one
//  it got — which is the whole point of the protocol
//  (Core/Contracts/Protocols.swift).
//

import Foundation
import Core

/// Picks the best handwriting recogniser this build and this device can offer.
///
/// Two things have to line up before the real engine is used: the module must
/// have been compiled with `PENCILLOOP_STROKE_RECOGNIZER` defined — off by
/// default in Package.swift, because the type does not exist in the iPadOS 26
/// SDK — and the device must actually be running iPadOS 27 or newer, since the
/// deployment floor is 26.0.
///
/// **On failure or unavailability:** returns `NullHandwritingRecogniser`, which
/// declines everything without ever throwing. There is no error path and no
/// state for the UI to show; a build without recognition is a build where
/// handwritten notes are exported as images and are not searchable as text, and
/// nothing else differs (docs/04-flows.md § F3).
public enum InkRecogniserFactory {

    /// The recogniser to install in the app environment at launch.
    public static func make() -> any HandwritingRecognising {
        #if PENCILLOOP_STROKE_RECOGNIZER
        if #available(iOS 27, *) {
            return StrokeRecogniserEngine()
        }
        #endif
        return NullHandwritingRecogniser()
    }

    /// Whether this build could recognise anything at all, before a locale is
    /// even considered. Cheap, synchronous, and safe to branch a Settings row on.
    public static var isCompiledIn: Bool {
        #if PENCILLOOP_STROKE_RECOGNIZER
        return true
        #else
        return false
        #endif
    }
}
