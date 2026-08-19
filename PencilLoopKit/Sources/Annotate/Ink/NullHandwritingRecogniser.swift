//
//  NullHandwritingRecogniser.swift
//  Annotate · Ink
//
//  The default, and on any build that is not compiled against the iPadOS 27 SDK
//  the only one. Recognition is an enhancement and never a dependency
//  (docs/04-flows.md § F3): ink is captured, persisted and exported as an image
//  whether or not a single word of it is ever read.
//

import Foundation
import Core

/// A recogniser that always declines.
///
/// **On failure or unavailability — which is its entire behaviour:**
/// `recogniseText(drawingData:locale:)` returns nil and `isAvailable(for:)`
/// returns false. Neither throws, neither blocks, and neither allocates. A
/// caller that treats nil as "no recognised text yet" rather than as an error is
/// correct on every build of the app; a caller that shows a spinner waiting for
/// this is wrong on all of them (Core/Contracts/Protocols.swift,
/// `HandwritingRecognising`).
public struct NullHandwritingRecogniser: HandwritingRecognising {

    public init() {}

    /// Always nil. See the type's documentation.
    public func recogniseText(drawingData: Data, locale: Locale) async -> RecognisedInk? {
        nil
    }

    /// Always false, for every locale.
    public func isAvailable(for locale: Locale) async -> Bool {
        false
    }
}
