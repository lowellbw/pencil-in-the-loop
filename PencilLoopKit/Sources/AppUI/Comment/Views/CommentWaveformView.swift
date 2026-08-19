//
//  CommentWaveformView.swift
//  AppUI · Comment · Views
//
//  "A live waveform while recording" (docs/02-spec.md § S3) — and nothing else
//  moving anywhere in this feature (docs/01-design-principles.md rule 7).
//

import Foundation
import SwiftUI

/// The bars that say the microphone is open.
///
/// **What it is actually showing.** `SpeechTranscribing` streams text, not
/// audio levels — there is no level anywhere in `Core/Contracts` — so this
/// cannot be a true meter without a new contract member. What it does instead
/// is honest about what it knows: the bars idle low, and swell while the
/// transcript is growing. Silence looks like silence and speech looks like
/// speech, which is the entire job of a waveform in a popover this small.
/// A real meter is a change request (see this unit's report), not a local
/// invention.
///
/// **Accessibility.** Hidden from VoiceOver: it duplicates the recording state
/// that `CommentPopoverView` already announces, and a bar chart of nothing in
/// particular is not worth a rotor stop. Honours Reduce Motion by holding
/// still.
///
/// **Never fails.** Draws flat bars when it has nothing to say.
public struct CommentWaveformView: View {

    /// True while audio is being captured.
    public var isActive: Bool

    /// Length of the transcript so far. The view watches this for growth; it
    /// never reads the text.
    public var transcriptLength: Int

    /// How many bars. Odd, so the middle one anchors the row.
    public var barCount: Int

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var tick = 0
    @State private var lastLength = 0
    @State private var ticksSinceGrowth = 99

    public init(isActive: Bool, transcriptLength: Int = 0, barCount: Int = 17) {
        self.isActive = isActive
        self.transcriptLength = transcriptLength
        self.barCount = barCount
    }

    public var body: some View {
        HStack(alignment: .center, spacing: 3) {
            ForEach(0..<barCount, id: \.self) { index in
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(Color.accentColor)
                    .opacity(isActive ? 0.85 : 0.25)
                    .frame(width: 3, height: height(for: index))
            }
        }
        .frame(height: 26, alignment: .center)
        .animation(.linear(duration: 0.08), value: tick)
        .accessibilityHidden(true)
        .task(id: isActive) {
            guard isActive, !reduceMotion else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 70_000_000)
                guard !Task.isCancelled else { return }
                tick &+= 1
                ticksSinceGrowth = min(99, ticksSinceGrowth + 1)
            }
        }
        .onChange(of: transcriptLength) { _, newValue in
            guard newValue != lastLength else { return }
            lastLength = newValue
            ticksSinceGrowth = 0
        }
    }

    /// Bar height in points.
    ///
    /// Deterministic: two irrationally-related sine terms per bar, so the row
    /// reads as a waveform rather than as a repeating pattern, with no random
    /// number generator to make the view non-reproducible in a preview.
    private func height(for index: Int) -> CGFloat {
        let floorHeight: CGFloat = 4
        guard isActive else { return floorHeight }
        let phase = Double(tick) * 0.9 + Double(index) * 1.7
        let wobble = (sin(phase) + sin(phase * 0.37 + 1.3)) / 2
        let envelope = 0.5 + 0.5 * cos(Double(index - barCount / 2) / Double(max(1, barCount)) * 3.1)
        let amplitude = reduceMotion ? 0.35 : activity
        let value = floorHeight + CGFloat(abs(wobble) * envelope * amplitude) * 22
        return min(26, value)
    }

    /// 1 while the transcript is growing, decaying towards a quiet idle when it
    /// stops.
    private var activity: Double {
        let decayed = 1.0 - Double(min(ticksSinceGrowth, 12)) / 12.0
        return 0.25 + 0.75 * decayed
    }
}

#Preview("Recording") {
    CommentWaveformView(isActive: true, transcriptLength: 40)
        .padding()
}

#Preview("Idle") {
    CommentWaveformView(isActive: false)
        .padding()
}
