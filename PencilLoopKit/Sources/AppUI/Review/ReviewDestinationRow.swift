//
//  ReviewDestinationRow.swift
//  AppUI · Review
//
//  The row that says where this review is going (docs/02-spec.md § S4,
//  docs/01-design-principles.md § Specific choices).
//
//  It is the only place the user learns whether their context is preserved, so
//  it is never buried: ReviewSendBar pins it directly above the Send button, in
//  a bottom inset that no amount of comment scrolling can push off screen.
//
//  Everything shown comes from `ResolvedReturnPath`, and the badge comes from
//  its `badgeText` — which reads `sameThread`, not `type`, because a `.resume`
//  path with no session id has nothing to resume and must not claim otherwise
//  (DTOs.swift § ResolvedReturnPath).
//

import SwiftUI
import Core

/// Origin name, thread title, session id, and the SAME THREAD / NEW THREAD
/// badge.
struct ReviewDestinationRow: View {

    /// What `ReturnPathResolving.resolve(_:)` decided.
    let path: ResolvedReturnPath

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbolName)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                if dynamicTypeSize.isAccessibilitySize {
                    Text(headline).font(.subheadline.weight(.semibold))
                    badge
                } else {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(headline).font(.subheadline.weight(.semibold))
                        Spacer(minLength: 0)
                        badge
                    }
                }

                if let threadTitle = path.threadTitle {
                    Text("“\(threadTitle)”")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                if let sessionId = path.sessionId {
                    Text("Session \(sessionId)")
                        .font(.footnote.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Text(explanation)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    /// "Cowork · Scheduled check-in", or just "No return path".
    var headline: String {
        path.type == .none ? path.displayName : "\(path.displayName) · \(path.type.displayName)"
    }

    /// One sentence about what pressing Send will actually do. Each of the five
    /// paths costs something different to operate (docs/06-integrations.md).
    var explanation: String {
        switch path.type {
        case .poke:
            return path.sameThread
                ? "Fires the session's poke task, so the review arrives as an ordinary turn in that conversation."
                : "The poke task id is missing, so this cannot reach the original session."
        case .checkin:
            return "The session reads the outbox on its next scheduled check-in. Slightly delayed, nothing to install."
        case .resume:
            return path.sameThread
                ? "Resumes that session on your Mac with its full history."
                : "No session id was recorded, so this cannot resume the original conversation."
        case .cloud:
            return path.sameThread
                ? "Queues into that live web session."
                : "No session id was recorded, so this cannot reach the original web session."
        case .none:
            return "Nothing to reply into. The review is written to the folder, and you can copy, share or save it."
        }
    }

    /// SF Symbols only, one per mechanism.
    private var symbolName: String {
        switch path.type {
        case .poke: return "bolt"
        case .checkin: return "clock"
        case .resume: return "arrow.uturn.backward"
        case .cloud: return "cloud"
        case .none: return "tray"
        }
    }

    /// Frozen on `ResolvedReturnPath`: SAME THREAD or NEW THREAD.
    private var badge: some View {
        Text(path.badgeText)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
    }

    /// One sentence for VoiceOver, in the order the row reads.
    private var accessibilityText: String {
        var parts: [String] = ["Destination: \(headline)"]
        if let threadTitle = path.threadTitle {
            parts.append("thread \(threadTitle)")
        }
        if let sessionId = path.sessionId {
            parts.append("session \(sessionId)")
        }
        parts.append(path.sameThread ? "same thread" : "new thread")
        parts.append(explanation)
        return parts.joined(separator: ". ")
    }
}

#Preview("Destination · every path") {
    List {
        Section("Poke") { ReviewDestinationRow(path: ReviewPreviewData.resolved(.poke)) }
        Section("Check-in") { ReviewDestinationRow(path: ReviewPreviewData.resolved(.checkin)) }
        Section("Resume") { ReviewDestinationRow(path: ReviewPreviewData.resolved(.resume)) }
        Section("Cloud") { ReviewDestinationRow(path: ReviewPreviewData.resolved(.cloud)) }
        Section("None") { ReviewDestinationRow(path: ResolvedReturnPath.unresolved) }
        Section("Resume, no session id") { ReviewDestinationRow(path: ReviewPreviewData.resumeWithoutSession) }
    }
    .listStyle(.insetGrouped)
}
