//
//  NarrationPlayback.swift
//  Annotate · Audio
//
//  What the player is doing, in the one shape a view needs.
//
//  A value rather than an observable object, because the player is an actor and
//  the sheet polls it: `NarrationPlayback` is what crosses that boundary, and
//  being `Hashable` is what lets SwiftUI skip a redraw when a poll returns the
//  same state it returned last time.
//

import Foundation

/// What the player is doing, for a view to draw.
public struct NarrationPlayback: Sendable, Hashable {
    public var isPlaying: Bool
    public var elapsed: TimeInterval
    public var duration: TimeInterval

    public init(isPlaying: Bool = false, elapsed: TimeInterval = 0, duration: TimeInterval = 0) {
        self.isPlaying = isPlaying
        self.elapsed = elapsed
        self.duration = duration
    }

    /// 0…1, or 0 for a file with no duration yet.
    public var fraction: Double {
        duration > 0 ? min(1, max(0, elapsed / duration)) : 0
    }
}
