//
//  InkChange.swift
//  Annotate · Ink
//
//  One `canvasViewDrawingDidChange` callback, packaged for the actor that will
//  persist it. Constructing one of these is the entire amount of work the touch
//  path is allowed to do (docs/01-design-principles.md § 10).
//

import Foundation
import PencilKit

/// A drawing change recorded on the main actor and handed to
/// `InkPersistenceCoordinator` for debouncing and persistence.
///
/// Carrying the `PKDrawing` rather than its bytes is the point: serialising a
/// three-hundred-stroke drawing takes milliseconds, and milliseconds on the
/// touch path are dropped frames. `PKDrawing` is a value type with copy-on-write
/// storage, so capturing one is a retain; `dataRepresentation()` is called later,
/// off the main actor.
///
/// **On failure:** there is none. A change that cannot be persisted is retried
/// by the coordinator and reported through `InkLog`; it is never thrown back at
/// the caller, because the caller is a UIKit delegate callback with nowhere to
/// put an error.
// SAFETY: `PKDrawing` is a value type whose stroke storage is immutable once
// constructed; this struct is `let`-only and its drawing is read exactly once,
// by the actor that receives it. Nothing mutates a drawing after it has been
// packaged into a change, so there is no shared mutable state to race on. The
// annotation is here only because `PKDrawing` is not itself declared `Sendable`
// in every SDK this project has to build against.
public struct InkChange: @unchecked Sendable {

    /// The page the change belongs to.
    public let binding: InkPageBinding

    /// The canvas's drawing at the moment the delegate fired.
    public let drawing: PKDrawing

    /// When the change was recorded, for the debounce arithmetic.
    public let recordedAt: Date

    public init(binding: InkPageBinding, drawing: PKDrawing, recordedAt: Date = Date()) {
        self.binding = binding
        self.drawing = drawing
        self.recordedAt = recordedAt
    }
}
