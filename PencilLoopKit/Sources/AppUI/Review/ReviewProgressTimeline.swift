//
//  ReviewProgressTimeline.swift
//  AppUI · Review
//
//  The Sent screen's progress list (docs/02-spec.md § S5).
//
//  ─── WHAT IS REAL AND WHAT IS NOT ───────────────────────────────────────────
//  The spec sketches "bundle written → picked up → agent working". Only the
//  first of those three is observable. docs/05-file-contracts.md defines no
//  acknowledgement file, no lock, no status key — nothing a watcher writes when
//  it collects a bundle, and nothing an agent writes while it thinks. The only
//  other real event is `reply.md` appearing (docs/04-flows.md § F6).
//
//  So this renders exactly three things: the bundle being built, the folder
//  confirming it (or queueing it, offline), and the reply arriving. The gap in
//  between is drawn as a stage that is openly waiting, with a line saying that
//  nothing reports pick-up. A spinner that implies an agent is reading would be
//  an invention, and the one thing worse than no progress is fake progress.
//  ────────────────────────────────────────────────────────────────────────────
//

import SwiftUI

/// A short vertical list of what has actually happened.
struct ReviewProgressTimeline: View {

    /// One line in the timeline.
    struct Stage: Identifiable, Hashable {

        /// How much is known about this step.
        enum Status: Hashable {

            /// Observed. It happened, and we saw it happen.
            case done

            /// Not observed, and not claimed. Either it has not happened yet or
            /// nothing reports it.
            case waiting

            /// Held locally until the folder comes back (docs/04-flows.md § F7).
            case queued
        }

        var id: String
        var title: String

        /// The honest detail line: a timestamp, a byte count, or why nothing
        /// can be said yet.
        var detail: String?

        var status: Status

        /// SF Symbols only.
        var symbolName: String {
            switch status {
            case .done: return "checkmark.circle.fill"
            case .waiting: return "circle.dotted"
            case .queued: return "clock"
            }
        }

        /// What VoiceOver reads for the symbol, since a glyph says nothing.
        var statusWord: String {
            switch status {
            case .done: return "done"
            case .waiting: return "waiting"
            case .queued: return "queued"
            }
        }
    }

    let stages: [Stage]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(stages) { stage in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: stage.symbolName)
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(stage.title)
                            .font(.subheadline)
                        if let detail = stage.detail {
                            Text(detail)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(label(for: stage))
            }
        }
        .padding(.vertical, 2)
    }

    private func label(for stage: Stage) -> String {
        guard let detail = stage.detail else {
            return "\(stage.title), \(stage.statusWord)"
        }
        return "\(stage.title), \(stage.statusWord). \(detail)"
    }
}

#Preview("Timeline · written, waiting for a reply") {
    List {
        Section("Progress") {
            ReviewProgressTimeline(
                stages: [
                    ReviewProgressTimeline.Stage(
                        id: "built",
                        title: "Review bundle built",
                        detail: "5 files · 84 KB",
                        status: .done
                    ),
                    ReviewProgressTimeline.Stage(
                        id: "written",
                        title: "Written to the folder",
                        detail: "outbox/2026-08-18-auth-refactor-plan.review",
                        status: .done
                    ),
                    ReviewProgressTimeline.Stage(
                        id: "reply",
                        title: "Waiting for a reply",
                        detail: "Nothing reports pick-up — the folder format has no signal for it. The next thing the app can actually see is reply.md appearing.",
                        status: .waiting
                    )
                ]
            )
        }
    }
    .listStyle(.insetGrouped)
}

#Preview("Timeline · offline") {
    List {
        Section("Progress") {
            ReviewProgressTimeline(
                stages: [
                    ReviewProgressTimeline.Stage(
                        id: "built",
                        title: "Review bundle built",
                        detail: "5 files · 84 KB",
                        status: .done
                    ),
                    ReviewProgressTimeline.Stage(
                        id: "written",
                        title: "Will send when online",
                        detail: "Held on this iPad. The sync folder is unavailable.",
                        status: .queued
                    )
                ]
            )
        }
    }
    .listStyle(.insetGrouped)
}
