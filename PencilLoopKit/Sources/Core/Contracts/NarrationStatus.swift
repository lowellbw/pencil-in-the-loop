//
//  NarrationStatus.swift
//  Core · Contracts
//
//  Where a narration has got to, as the relay reports it.
//
//  This exists because the device cannot know on its own. Making a narration
//  takes minutes and happens somewhere else, so "am I still waiting?" is not a
//  fact the app can hold: a local flag is lost the moment the app is relaunched,
//  and would then offer Listen for something already halfway made. The relay
//  remembers, and this is what it says (`docs/12-relay.md` § 4c).
//

import Foundation

/// What the relay says about a document's narration.
public struct NarrationStatus: Sendable, Hashable, Codable {

    /// The relay's state machine, and what each one means to the reader.
    public enum State: String, Sendable, Codable {
        /// Nothing has been asked for. The button offers to ask.
        case none
        /// Being made. Minutes, not seconds — and nothing is waiting on it.
        case working
        /// The audio exists on the relay. It may not be on the device yet.
        case ready
        /// No provider key is set. Retrying will not help, and saying so is
        /// kinder than a generic failure the reader would keep tapping.
        case unconfigured
        /// It went wrong. Asking again may work.
        case failed
    }

    public var state: State
    /// How long the finished narration runs, when it is ready.
    public var minutes: Double?
    /// Which half of the work is running: `scripting` or `recording`.
    public var stage: String?
    /// Turns spoken, and how many there are. Both zero while it is scripting,
    /// because the number of turns is not known until the script exists.
    public var done: Int
    public var total: Int
    /// Headings the script never mentioned. Empty is the normal case: the relay
    /// already asks again for anything missing before it speaks a word.
    public var missedSections: [String]

    public init(
        state: State,
        minutes: Double? = nil,
        stage: String? = nil,
        done: Int = 0,
        total: Int = 0,
        missedSections: [String] = []
    ) {
        self.state = state
        self.minutes = minutes
        self.stage = stage
        self.done = done
        self.total = total
        self.missedSections = missedSections
    }

    /// 0…1 through the recording, or nil when there is nothing to measure yet.
    ///
    /// Nil rather than zero while scripting, so a view can show an
    /// indeterminate spinner instead of a bar sitting at the far left — which
    /// reads as stuck rather than starting.
    public var fraction: Double? {
        guard state == .working, total > 0 else { return nil }
        return min(1, max(0, Double(done) / Double(total)))
    }

    /// What to put on screen, in the app's own voice.
    ///
    /// Deliberately not the relay's `error` string: a provider's failure text is
    /// written for whoever is running the relay, and pasting it in front of
    /// someone reading a paper tells them nothing they can act on.
    public var summary: String {
        switch state {
        case .none:
            return "Not made yet."
        case .working:
            // Deliberately no time estimate. The first version of this said "a
            // few minutes", which was a guess and wrong by a factor of ten on a
            // long paper: a 35,000-character document is tens of sequential
            // provider calls and runs for the best part of an hour. Counting
            // turns is a true thing to say; a duration was not.
            if total > 0 {
                return "Recording — \(done) of \(total). It carries on if you "
                    + "leave this screen."
            }
            return "Writing the script. It carries on if you leave this screen."
        case .ready:
            guard let minutes, minutes > 0 else { return "Ready to play." }
            return "Ready — about \(Int(minutes.rounded())) minutes."
        case .unconfigured:
            return "Listening isn't set up on the relay yet."
        case .failed:
            return "That didn't work. You can ask again."
        }
    }
}
