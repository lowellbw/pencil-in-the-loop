//
//  NarrationSheet.swift
//  AppUI · Reader
//
//  Listening to a document (docs/02-spec.md § S2).
//
//  A sheet with detents and a grabber, per docs/01-design-principles.md § 3 —
//  not a floating transport bar over the page. § 4 rules out persistent chrome
//  in the reader, and the reader's own toolbar auto-hides on scroll, so a
//  control living only there would vanish mid-listen. A sheet the reader can
//  pull down and bring back is the standard container for this.
//
//  **Tapping Listen always opens this**, whether or not there is anything to
//  play, because a toolbar button that changes to a grey word and then does
//  nothing for four minutes is not a state anybody can read. What is happening,
//  how long it takes and whether it went wrong all belong in one place, and this
//  is that place.
//
//  That is not the spinner CLAUDE.md non-negotiable 1 forbids. The rule is that
//  reading and annotating never *wait* on the network; this is a sheet the
//  reader deliberately opened and can dismiss with a swipe, and the document
//  behind it is untouched and fully usable the whole time.
//
//  There is no waveform, no artwork and no speed dial. The lock screen already
//  has transport controls and the system already has a volume control; what is
//  here is what is not available anywhere else.
//
//  ─── WHAT TO CHECK BY HAND, ON A DEVICE ──────────────────────────────────────
//  1. Tap Listen on a document with no narration: the sheet opens immediately
//     and says what it is doing. Nothing is greyed out and nothing hangs.
//  2. Dismiss it and reopen it: it still says "making one", because the relay
//     is remembering, not the app.
//  3. Force-quit and relaunch mid-generation, then reopen the sheet: same.
//  4. Turn the network off and tap Listen: it says so once and the document is
//     exactly as it was.
//  ─────────────────────────────────────────────────────────────────────────────
//

import SwiftUI
import Annotate
import Core

/// The player, and everything that happens before there is one to play.
public struct NarrationSheet: View {

    private let narration: NarrationController

    @State private var playback = NarrationPlayback()
    @State private var depth = "standard"
    @Environment(\.dismiss) private var dismiss

    private var player: NarrationPlayer { narration.player }

    public init(narration: NarrationController) {
        self.narration = narration
    }

    public var body: some View {
        NavigationStack {
            Group {
                if narration.hasNarration {
                    self.transport
                } else {
                    self.waiting
                }
            }
            .padding(.vertical, 28)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .navigationTitle(narration.hasNarration ? "Listening" : "Listen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
        .task { await self.follow() }
    }

    // MARK: - Playing

    private var transport: some View {
        VStack(spacing: 28) {
            Text(narration.title)
                .font(.title3)
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .padding(.horizontal)

            VStack(spacing: 6) {
                ProgressView(value: playback.fraction)
                HStack {
                    Text(NarrationSheet.clock(playback.elapsed))
                    Spacer()
                    Text("−" + NarrationSheet.clock(max(0, playback.duration - playback.elapsed)))
                }
                .font(.footnote.monospacedDigit())
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal)

            HStack(spacing: 44) {
                Button {
                    Task { await player.skip(-NarrationPlayer.skipBack) }
                } label: {
                    Label("Back 30 Seconds", systemImage: "gobackward.30")
                        .labelStyle(.iconOnly)
                        .font(.title)
                }
                .accessibilityLabel("Back 30 seconds")

                Button {
                    Task { await player.toggle() }
                } label: {
                    Label(
                        playback.isPlaying ? "Pause" : "Play",
                        systemImage: playback.isPlaying ? "pause.circle.fill" : "play.circle.fill"
                    )
                    .labelStyle(.iconOnly)
                    .font(.system(size: 56))
                }
                .accessibilityLabel(playback.isPlaying ? "Pause" : "Play")

                Button {
                    Task { await player.skip(NarrationPlayer.skipForward) }
                } label: {
                    Label("Forward 15 Seconds", systemImage: "goforward.15")
                        .labelStyle(.iconOnly)
                        .font(.title)
                }
                .accessibilityLabel("Forward 15 seconds")
            }

            Text("Keeps playing with the screen off.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Not playing yet

    /// Being made, not made yet, or refused — one layout, because from the
    /// reader's side they are the same question with different answers.
    @ViewBuilder private var waiting: some View {
        VStack(spacing: 20) {
            Image(systemName: narration.isPreparing ? "waveform" : "headphones")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
                .symbolEffect(.variableColor, isActive: narration.isPreparing)
                .accessibilityHidden(true)

            if narration.isPreparing {
                ProgressView()
                    .progressViewStyle(.circular)
            }

            Text(narration.status?.summary ?? NarrationSheet.unknown)
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 32)

            if narration.isPreparing == false {
                self.ask
            }
        }
    }

    /// Ask for one, at a chosen length.
    ///
    /// The depth picker is here rather than hidden in Settings because it is a
    /// decision about *this* document — a forty-page paper and a two-page note
    /// do not want the same answer — and because a longer one costs more to
    /// make. All three cover every section; they differ in how much detail
    /// survives (`docs/12-relay.md` § 4c).
    @ViewBuilder private var ask: some View {
        if narration.status?.state == .unconfigured {
            EmptyView()
        } else {
            VStack(spacing: 16) {
                Picker("Length", selection: $depth) {
                    Text("Brief").tag("brief")
                    Text("Standard").tag("standard")
                    Text("In depth").tag("deep")
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 40)

                Button {
                    Task { await narration.request(depth: depth) }
                } label: {
                    Text(narration.status?.state == .failed ? "Try Again" : "Make One")
                        .frame(maxWidth: 220)
                }
                .buttonStyle(.borderedProminent)

                Text("Takes a few minutes. You can carry on reading.")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: - Following along

    /// Two clocks, because the two things being watched move at very different
    /// speeds: playback four times a second for a progress bar, and the relay
    /// every few seconds because a narration takes minutes to make.
    private func follow() async {
        var ticks = 0
        while Task.isCancelled == false {
            if narration.hasNarration {
                playback = await player.playback()
            } else if ticks % NarrationSheet.relayEvery == 0 {
                await narration.refresh()
            }
            ticks += 1
            try? await Task.sleep(for: .milliseconds(NarrationSheet.tick))
        }
    }

    /// Polled rather than observed: `AVAudioPlayer` publishes nothing, and four
    /// times a second is enough for a progress bar and cheap enough not to
    /// matter.
    static let tick = 250

    /// Every 20 ticks — five seconds. Fast enough that the sheet notices within
    /// a moment of the audio landing, slow enough to be nothing on a relay
    /// doing real work.
    static let relayEvery = 20

    /// Shown before the first answer, and after one that never arrived.
    static let unknown = "Checking…"

    /// `m:ss`, or `h:mm:ss` past an hour.
    static func clock(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded())
        let (hours, minutes, secs) = (total / 3600, (total % 3600) / 60, total % 60)
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%d:%02d", minutes, secs)
    }
}
