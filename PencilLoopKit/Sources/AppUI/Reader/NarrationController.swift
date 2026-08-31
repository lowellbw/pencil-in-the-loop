//
//  NarrationController.swift
//  AppUI · Reader
//
//  Asking for a narration, and knowing where it got to.
//
//  This lived inside `ReaderModel` until the library needed it too. Listening is
//  not a property of having a document open — picking a paper in the sidebar and
//  setting it going while you read something else is the obvious way to use
//  this — so the state moved somewhere both screens can hold one.
//
//  It is deliberately not in `AppEnvironment`. The *player* is shared, because
//  only one thing can be playing; **which document you are asking about is not**,
//  and a single shared controller would mean the sidebar and the reader
//  overwriting each other's target.
//

import Foundation
import Observation
import Annotate
import Core
import Sync
import os

/// One document's narration: whether there is one, where it has got to, and the
/// two things you can do about it.
@MainActor
@Observable
public final class NarrationController {

    private static let log = Logger(subsystem: "co.pencil-loop.appui", category: "narration")

    private let environment: any AppEnvironment

    /// The document this is about. Nil before anything has been chosen.
    public private(set) var folderName: String?

    /// Its title, for the sheet and for Now Playing.
    public private(set) var title = ""

    /// What the relay last said. Nil until it has been asked, and after a relay
    /// it could not reach — in which case the last answer stands rather than
    /// being replaced by an error.
    public private(set) var status: NarrationStatus?

    /// Set the instant Listen is tapped, so there is something to show before
    /// the first round trip lands. The relay's own `working` takes over from it
    /// and outlives the app being relaunched, which this cannot.
    private var didJustAsk = false

    public init(environment: any AppEnvironment) {
        self.environment = environment
    }

    /// Point this at a document. Clears everything known about the last one.
    public func target(folderName: String, title: String) {
        guard folderName != self.folderName else { return }
        self.folderName = folderName
        self.title = title
        self.status = nil
        self.didJustAsk = false
    }

    /// Whether the audio is on this device, ready to play with no signal.
    ///
    /// A file's presence, read each time rather than cached: the fetcher may
    /// land one while the screen is open, and a cached "no" would leave the
    /// button wrong until the document was reopened.
    public var hasNarration: Bool {
        guard let folderName else { return false }
        return NarrationFetcher.hasNarration(forFolderName: folderName)
    }

    /// Whether one is being made right now.
    ///
    /// The relay's answer wins, and it is the one that survives a relaunch: an
    /// app that had only its own flag would offer to make a second narration of
    /// a document already halfway through one.
    public var isPreparing: Bool {
        if status?.state == .working { return true }
        if status == nil { return didJustAsk }
        return didJustAsk && status?.state == .none
    }

    /// Asks the relay where it has got to.
    ///
    /// **Never throws.** An unreachable relay leaves the last answer standing —
    /// the document is still perfectly readable, which is the posture here.
    public func refresh() async {
        guard let folderName else { return }
        do {
            status = try await environment.sync.narrationStatus(forFolderName: folderName)
        } catch {
            NarrationController.log.notice(
                "Could not read the narration state: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    /// Asks for one, and returns immediately.
    ///
    /// Generating it takes minutes; the audio arrives on a later scan. A relay
    /// that refuses leaves the screen exactly as it was (CLAUDE.md
    /// non-negotiable 1).
    public func request(depth: String = "standard") async {
        guard let folderName, isPreparing == false else { return }
        didJustAsk = true
        do {
            try await environment.sync.requestNarration(forFolderName: folderName, depth: depth)
            await refresh()
        } catch {
            didJustAsk = false
            status = NarrationStatus(state: .failed)
            NarrationController.log.notice(
                "Could not ask for a narration: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    /// Starts playing.
    ///
    /// - Returns: whether it started. False means the file would not open, or a
    ///   dictation holds the audio session.
    @discardableResult
    public func play() async -> Bool {
        guard let folderName else { return false }
        return await environment.narrationPlayer.play(
            NarrationFetcher.narrationURL(forFolderName: folderName),
            title: title,
            folderName: folderName
        )
    }

    /// The player itself, for a view drawing a transport.
    public var player: NarrationPlayer { environment.narrationPlayer }
}
