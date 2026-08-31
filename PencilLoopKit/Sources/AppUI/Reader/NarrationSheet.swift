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
//  There is no waveform, no artwork and no speed dial. The lock screen already
//  has transport controls and the system already has a volume control; what is
//  here is what is not available anywhere else.
//

import SwiftUI
import Annotate
import Core

/// The player, as a sheet.
public struct NarrationSheet: View {

    private let player: NarrationPlayer
    private let title: String

    @State private var playback = NarrationPlayback()
    @Environment(\.dismiss) private var dismiss

    public init(player: NarrationPlayer, title: String) {
        self.player = player
        self.title = title
    }

    public var body: some View {
        NavigationStack {
            VStack(spacing: 28) {
                Text(title)
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
            .padding(.vertical, 32)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .navigationTitle("Listening")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
        .task {
            // Polled rather than observed: `AVAudioPlayer` publishes nothing,
            // and four times a second is enough for a progress bar and cheap
            // enough not to matter.
            while Task.isCancelled == false {
                playback = await player.playback()
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

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
