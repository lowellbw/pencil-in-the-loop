//
//  InkDebouncePolicy.swift
//  Annotate · Ink
//
//  The timing rules for autosave and recognition, as pure arithmetic. Extracted
//  from the actor precisely so that the part worth testing can be tested without
//  a clock, a store or a canvas (STYLE.md § 10).
//

import Foundation

/// When a page's ink gets written, and when it gets read by the recogniser.
///
/// A plain trailing-edge debounce has a failure mode: a user who keeps drawing
/// keeps resetting the timer, so a long uninterrupted scribble is never written
/// at all. `maximumDelay` caps that — the first unsaved change is never more
/// than that many seconds from disk, however busy the page is. Autosave is the
/// only save there is (docs/02-spec.md § S2: no save action, no unsaved state),
/// so the cap is not a nicety.
///
/// **On failure:** there is none; every member is total. Intervals that are zero
/// or negative are clamped, so a nonsense policy saves eagerly rather than never.
public struct InkDebouncePolicy: Sendable, Hashable {

    /// Quiet time after the last stroke before the page is written.
    /// 500ms, per docs/03-architecture.md § 2 and docs/04-flows.md § F3.
    public let debounceInterval: TimeInterval

    /// Hard cap on how long the first unsaved change may wait, however many
    /// strokes follow it.
    public let maximumDelay: TimeInterval

    /// Quiet time before handwriting recognition runs. Longer than the save
    /// debounce because recognition is the expensive half and is worth
    /// coalescing harder; it has a 500ms per-page budget of its own once it
    /// starts (docs/03-architecture.md § Performance targets).
    public let recognitionDelay: TimeInterval

    public init(
        debounceInterval: TimeInterval = 0.5,
        maximumDelay: TimeInterval = 2.0,
        recognitionDelay: TimeInterval = 1.5
    ) {
        self.debounceInterval = max(0, debounceInterval)
        self.maximumDelay = max(0, maximumDelay)
        self.recognitionDelay = max(0, recognitionDelay)
    }

    /// The documented defaults: 500ms debounce, 2s cap, 1.5s before recognition.
    public static let standard = InkDebouncePolicy()

    /// The effective cap, which can never be shorter than the debounce itself —
    /// a cap below the interval would turn the debounce off entirely.
    public var effectiveMaximumDelay: TimeInterval {
        max(self.maximumDelay, self.debounceInterval)
    }

    /// When a page carrying unsaved changes should be written.
    ///
    /// - Parameters:
    ///   - firstChangeAt: when the oldest unwritten change was recorded.
    ///   - lastChangeAt: when the newest one was.
    /// - Returns: the earlier of "quiet for `debounceInterval`" and
    ///   "`effectiveMaximumDelay` since the first unwritten change".
    public func deadline(firstChangeAt: Date, lastChangeAt: Date) -> Date {
        let quiet = lastChangeAt.addingTimeInterval(self.debounceInterval)
        let capped = firstChangeAt.addingTimeInterval(self.effectiveMaximumDelay)
        return min(quiet, capped)
    }

    /// How long to wait from `now` before writing. Never negative.
    public func delay(from now: Date, firstChangeAt: Date, lastChangeAt: Date) -> TimeInterval {
        let target = self.deadline(firstChangeAt: firstChangeAt, lastChangeAt: lastChangeAt)
        return max(0, target.timeIntervalSince(now))
    }

    /// Whether the page is due to be written at `now`.
    public func shouldCommit(now: Date, firstChangeAt: Date, lastChangeAt: Date) -> Bool {
        now >= self.deadline(firstChangeAt: firstChangeAt, lastChangeAt: lastChangeAt)
    }

    /// `delay(from:…)` as whole nanoseconds, for `Task.sleep(nanoseconds:)`.
    public func delayNanoseconds(from now: Date, firstChangeAt: Date, lastChangeAt: Date) -> UInt64 {
        let seconds = self.delay(from: now, firstChangeAt: firstChangeAt, lastChangeAt: lastChangeAt)
        return InkDebouncePolicy.nanoseconds(seconds)
    }

    /// Seconds to nanoseconds, saturating rather than trapping on nonsense
    /// input — a clock that jumps must not take the app down.
    public static func nanoseconds(_ seconds: TimeInterval) -> UInt64 {
        // NaN and negatives are nonsense and mean "write now"; an infinite
        // delay is an ordering, and saturates to the cap. `isFinite` used to be
        // in this guard, which sent infinity to 0 — the opposite of saturating,
        // and a write the debounce was explicitly asked not to make yet. NaN
        // needs no test of its own: every comparison against it is false.
        guard seconds > 0 else { return 0 }
        let scaled = seconds * 1_000_000_000
        guard scaled < 9_000_000_000_000_000_000 else { return 9_000_000_000_000_000_000 }
        return UInt64(scaled)
    }
}
