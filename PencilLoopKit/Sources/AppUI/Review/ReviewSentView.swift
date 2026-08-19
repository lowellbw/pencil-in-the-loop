//
//  ReviewSentView.swift
//  AppUI · Review
//
//  S5, the Sent screen (docs/02-spec.md § S5, docs/04-flows.md §§ F6-F7).
//
//  Three jobs: name the resolved return path explicitly, show what has actually
//  happened to the bundle, and make sure there is never a dead end. The reply
//  appears inline when it arrives, with "Open as document" to carry the loop on.
//
//  What it does not do is invent progress. See ReviewProgressTimeline for why
//  the "picked up" and "agent working" steps in the spec sketch are not drawn.
//

import SwiftUI
import UIKit
import Core

/// The confirmation screen the review sheet becomes after Send.
struct ReviewSentView: View {

    /// The one route to every dependency.
    let environment: any AppEnvironment

    /// The same model the compose screen used, still listening to sync.
    let model: ReviewSheetModel

    /// Called with the new document's id after "Open as document" succeeds.
    let onOpenReply: (UUID) -> Void

    @State private var isSharing = false
    @State private var isExporting = false
    @State private var exportURLs: [URL] = []
    @State private var didCopy = false

    var body: some View {
        List {
            Section {
                header
            }

            Section {
                ReviewProgressTimeline(stages: stages)
            } header: {
                Text("Progress")
            }

            if let reply = model.outcome?.reply {
                replySection(reply)
            }

            ReviewFallbackActions(
                isPrimary: model.outcome?.needsFallback ?? true,
                didCopy: didCopy,
                onCopy: copyReview,
                onShare: shareReview,
                onSave: saveReview
            )

            if let failureMessage = model.failureMessage {
                Section {
                    Label(failureMessage, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .listStyle(.insetGrouped)
        .sheet(isPresented: $isSharing) {
            ReviewShareSheet(items: shareItems)
        }
        .sheet(isPresented: $isExporting) {
            ReviewExportPicker(urls: exportURLs)
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: headerSymbol)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text(headerTitle)
                    .font(.headline)
            }
            Text(headerSubtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    private var headerSymbol: String {
        guard let outcome = model.outcome else { return "checkmark.circle" }
        if case .queued = outcome.delivery { return "clock" }
        return outcome.needsFallback ? "tray.full" : "checkmark.circle.fill"
    }

    private var headerTitle: String {
        guard let outcome = model.outcome else { return "Review sent" }
        if case .queued = outcome.delivery { return "Will send when online" }
        return outcome.needsFallback ? "Review saved" : "Review sent"
    }

    /// Names the resolved return path in words, which is the whole point of the
    /// screen (docs/02-spec.md § S5).
    private var headerSubtitle: String {
        guard let outcome = model.outcome else { return "" }
        if case let .queued(reason) = outcome.delivery {
            return "The bundle is written on this iPad and goes to the folder as soon as it is reachable. \(reason)"
        }
        if outcome.needsFallback {
            return "No conversation to reply into. The bundle is in \(outcome.directoryName), and it is yours to copy, share or save."
        }
        var parts: [String] = ["\(outcome.path.displayName) · \(outcome.path.type.displayName)"]
        if let threadTitle = outcome.path.threadTitle {
            parts.append("“\(threadTitle)”")
        }
        if let sessionId = outcome.path.sessionId {
            parts.append("session \(sessionId)")
        }
        parts.append(outcome.path.sameThread ? "context intact" : "a new thread")
        return parts.joined(separator: " · ")
    }

    // MARK: - Timeline

    /// Only observed facts, in the order they can happen.
    private var stages: [ReviewProgressTimeline.Stage] {
        guard let outcome = model.outcome else { return [] }
        var result: [ReviewProgressTimeline.Stage] = []

        let fileWord = outcome.fileCount == 1 ? "1 file" : "\(outcome.fileCount) files"
        result.append(
            ReviewProgressTimeline.Stage(
                id: "built",
                title: "Review bundle built",
                detail: "\(fileWord) · \(outcome.byteSummary) · \(shortTime(outcome.builtAt))",
                status: .done
            )
        )

        switch outcome.delivery {
        case .pending:
            result.append(
                ReviewProgressTimeline.Stage(
                    id: "delivery",
                    title: "Writing to the sync folder",
                    detail: "Not confirmed yet. The folder reports back when the write lands.",
                    status: .waiting
                )
            )
        case let .written(at):
            result.append(
                ReviewProgressTimeline.Stage(
                    id: "delivery",
                    title: "Written to the folder",
                    detail: "outbox/\(outcome.directoryName) · \(shortTime(at))",
                    status: .done
                )
            )
        case let .queued(reason):
            result.append(
                ReviewProgressTimeline.Stage(
                    id: "delivery",
                    title: "Will send when online",
                    detail: "Held on this iPad. \(reason)",
                    status: .queued
                )
            )
        }

        if let reply = outcome.reply {
            result.append(
                ReviewProgressTimeline.Stage(
                    id: "reply",
                    title: "Reply received",
                    detail: shortTime(reply.receivedAt),
                    status: .done
                )
            )
        } else if outcome.needsFallback == false {
            result.append(
                ReviewProgressTimeline.Stage(
                    id: "reply",
                    title: "Waiting for a reply",
                    detail: "Nothing reports pick-up, and nothing reports an agent working — the folder format defines neither. The next thing this app can actually see is a reply arriving.",
                    status: .waiting
                )
            )
        }

        return result
    }

    private func shortTime(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }

    // MARK: - Reply

    private func replySection(_ reply: ReviewSentOutcome.Reply) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                if let text = reply.text {
                    Text(text)
                        .font(.body)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("The reply is in \(model.outcome?.directoryName ?? "the review folder"). Open it as a document to read and annotate it.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.vertical, 2)

            Button {
                Task {
                    if let id = await self.model.openReply(environment: self.environment) {
                        self.onOpenReply(id)
                    }
                }
            } label: {
                Label("Open as document", systemImage: "doc.badge.plus")
            }
            .disabled(model.isOpeningReply)
        } header: {
            Text("Reply · \(shortTime(reply.receivedAt))")
        } footer: {
            Text("Opening it adds the reply to the library with the same origin, so a review of it goes back to the same conversation.")
        }
    }

    // MARK: - The fallback actions

    private var shareItems: [Any] {
        guard let outcome = model.outcome else { return [] }
        var items: [Any] = [outcome.reviewMarkdown]
        for file in outcome.inkImageFiles {
            if let image = UIImage(data: file.data) {
                items.append(image)
            }
        }
        return items
    }

    private func copyReview() {
        UIPasteboard.general.string = model.outcome?.reviewMarkdown
        didCopy = true
        Task {
            try? await Task.sleep(for: .seconds(2))
            self.didCopy = false
        }
    }

    private func shareReview() {
        isSharing = true
    }

    private func saveReview() {
        guard let outcome = model.outcome else { return }
        Task {
            self.exportURLs = await ReviewSentView.exportFiles(for: outcome)
            self.isExporting = true
        }
    }

    /// Writes the bundle's files into a temporary directory so the document
    /// picker has something to copy.
    ///
    /// Nonisolated so the write happens off the main actor. Returns an empty
    /// array when nothing could be written, which presents an empty picker
    /// rather than an error — the review is still in the outbox either way.
    private nonisolated static func exportFiles(for outcome: ReviewSentOutcome) async -> [URL] {
        let manager = FileManager.default
        let root = URL.temporaryDirectory.appendingPathComponent(outcome.directoryName, isDirectory: true)
        try? manager.removeItem(at: root)
        guard (try? manager.createDirectory(at: root, withIntermediateDirectories: true)) != nil else {
            return []
        }

        var written: [URL] = []
        for file in outcome.payload.files {
            let destination = root.appendingPathComponent(file.relativePath, isDirectory: false)
            let directory = destination.deletingLastPathComponent()
            try? manager.createDirectory(at: directory, withIntermediateDirectories: true)
            if (try? file.data.write(to: destination, options: .atomic)) != nil {
                written.append(destination)
            }
        }
        return written
    }
}

#Preview("Sent · same thread, waiting") {
    ReviewSentView(
        environment: PreviewEnvironment(),
        model: ReviewPreviewData.sentModel(pathType: .checkin, delivery: .written(at: Date())),
        onOpenReply: { _ in }
    )
}

#Preview("Sent · reply arrived") {
    ReviewSentView(
        environment: PreviewEnvironment(),
        model: ReviewPreviewData.sentModel(
            pathType: .poke,
            delivery: .written(at: Date()),
            reply: ReviewSentOutcome.Reply(
                receivedAt: Date(),
                text: "Added a 24h shadow-read window to phase 2, capped refresh retries with exponential backoff, and re-scoped to 6 days. The mobile SDK question needs you — I could not verify the client version spread."
            )
        ),
        onOpenReply: { _ in }
    )
}

#Preview("Sent · offline queue") {
    ReviewSentView(
        environment: PreviewEnvironment(),
        model: ReviewPreviewData.sentModel(
            pathType: .checkin,
            delivery: .queued(reason: "The sync folder is unavailable. The provider is signed out.")
        ),
        onOpenReply: { _ in }
    )
}

#Preview("Sent · no return path") {
    ReviewSentView(
        environment: PreviewEnvironment(),
        model: ReviewPreviewData.sentModel(pathType: .none, delivery: .written(at: Date())),
        onOpenReply: { _ in }
    )
}
