//
//  ReviewSheet.swift
//  AppUI · Review
//
//  S4, the review sheet (docs/02-spec.md § S4, docs/04-flows.md § F5).
//
//  A `.large` sheet with a grabber, an inset-grouped list of comments in
//  document order, the Include toggles as a section, the closing instruction as
//  a vertical text field, and one prominent button — the shape
//  docs/01-design-principles.md § Specific choices names, and nothing else.
//
//  Presented by the reader:
//
//      .sheet(isPresented: $isReviewing) {
//          ReviewSheet(environment: environment, document: detail) { id in … }
//      }
//
//  The trailing closure is handed the id of a document created from an agent's
//  reply, so the host can open it (docs/04-flows.md § F6). It is optional.
//

import SwiftUI
import Core

/// The review sheet, and the Sent screen it becomes.
public struct ReviewSheet: View {

    @Environment(\.dismiss) private var dismiss

    @State private var model: ReviewSheetModel

    private let environment: any AppEnvironment

    /// Holding is not a gesture VoiceOver passes through, so the dictation
    /// control becomes a button when it is on (`CommentHintRow` does the same).
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled

    /// When the Pencil was last seen hovering over the closing instruction.
    ///
    /// A timestamp rather than a bool because a squeeze is not instantaneous:
    /// the hand tightens, the Pencil can drift out of the 12mm hover range, and
    /// refusing then would make the gesture feel unreliable rather than
    /// scoped. `ReviewSheet.hoverFreshness` is the grace period, and it is
    /// `CommentGestureTuning`'s number for the same reason.
    @State private var lastInstructionHoverAt: Date?
    private let onOpenReply: (UUID) -> Void

    /// - Parameters:
    ///   - environment: the one route to every dependency.
    ///   - document: what the reader already holds. Nothing is re-fetched.
    ///   - onOpenReply: called with a new document's id after the user opens an
    ///     agent's reply as a document. The sheet dismisses itself first.
    public init(
        environment: any AppEnvironment,
        document: DocumentDetail,
        onOpenReply: @escaping (UUID) -> Void = { _ in }
    ) {
        self.environment = environment
        self.onOpenReply = onOpenReply
        _model = State(initialValue: ReviewSheetModel(document: document))
    }

    /// Previews and tests, which need to seed state the environment cannot
    /// supply.
    init(
        environment: any AppEnvironment,
        model: ReviewSheetModel,
        onOpenReply: @escaping (UUID) -> Void = { _ in }
    ) {
        self.environment = environment
        self.onOpenReply = onOpenReply
        _model = State(initialValue: model)
    }

    public var body: some View {
        NavigationStack {
            content
                .navigationTitle(model.phase == .sent ? "Sent" : "Review")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(model.phase == .sent ? "Done" : "Cancel") {
                            self.dismiss()
                        }
                        .accessibilityHint(model.phase == .sent ? "Closes the review." : "Closes the review sheet without sending.")
                    }
                }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .interactiveDismissDisabled(model.phase == .sending)
        .task { await model.load(environment: environment) }
        .task { await model.observe(environment: environment) }
    }

    @ViewBuilder
    private var content: some View {
        if model.phase == .sent, model.outcome != nil {
            ReviewSentView(environment: environment, model: model) { newDocumentId in
                self.dismiss()
                self.onOpenReply(newDocumentId)
            }
        } else {
            composer
        }
    }

    // MARK: - S4

    private var composer: some View {
        List {
            Section {
                header
            }

            previousReviewSection

            commentsSection

            ReviewIncludeSection(
                include: model.include,
                commentCount: model.comments.count,
                inkedPageCount: model.inkedPageCount,
                recognisedPageCount: model.recognisedPageCount,
                onChange: { updated in self.model.include = updated }
            )

            Section {
                TextField("Anything to add?", text: instructionBinding, axis: .vertical)
                    .lineLimit(3...10)
                    .accessibilityLabel("Closing instruction")
                    .accessibilityHint("One free-text field. Turns a pile of notes into a request.")
                    .onContinuousHover { phase in self.noteHover(phase) }

                instructionDictationRow
                    .onContinuousHover { phase in self.noteHover(phase) }
            } header: {
                Text("Closing instruction")
            } footer: {
                Text("This is the one line that turns a pile of notes into a request.")
            }
        }
        .listStyle(.insetGrouped)
        .background {
            // Squeeze is device-level: it arrives wherever the Pencil is, so
            // the reporter can live anywhere in the sheet and the *hover* is
            // what decides whether this sheet should act on it.
            PencilSqueezeReporter(
                onBegan: { self.squeezeBegan() },
                onEnded: { self.model.endInstructionDictation(environment: self.environment) }
            )
        }
        .safeAreaInset(edge: .bottom) {
            ReviewSendBar(
                path: model.returnPath,
                title: model.sendButtonTitle,
                isSending: model.phase == .sending,
                isEnabled: model.canSend,
                failureMessage: model.failureMessage,
                onSend: { Task { await self.model.send(environment: self.environment) } }
            )
        }
    }

    /// A review sent before this sheet was opened, and the agent's reply to it
    /// if one has arrived (docs/04-flows.md § F6).
    ///
    /// This is the case that used to be unreachable. A reply takes minutes, the
    /// sheet is closed long before it lands, and the only route to it was a
    /// `SyncEvent` that no screen was listening for. The store had the text all
    /// along; nothing could ask.
    @ViewBuilder
    private var previousReviewSection: some View {
        if model.phase == .composing, let status = model.priorReview, status.hasBeenSent {
            Section {
                if let text = status.replyText, text.isEmpty == false {
                    Text(text)
                        .font(.body)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.vertical, 2)
                    Button {
                        Task {
                            if let id = await self.model.openReply(environment: self.environment) {
                                self.dismiss()
                                self.onOpenReply(id)
                            }
                        }
                    } label: {
                        Label("Open reply as document", systemImage: "doc.badge.plus")
                    }
                    .disabled(model.isOpeningReply)
                } else {
                    Text("Nothing back yet. A reply appears here when the agent writes one.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } header: {
                Text(ReviewSheet.previousReviewHeading(status))
            } footer: {
                Text("Sending again writes a second bundle to the same folder. The comments below are the ones you have now, not the ones you sent.")
            }
        }
    }

    private static func previousReviewHeading(_ status: ReviewStatus) -> String {
        guard let sentAt = status.sentAt else { return "Previously sent" }
        return "Sent " + sentAt.formatted(date: .abbreviated, time: .shortened)
    }

    /// "3 comments, 2 inked pages", then the document and the time spent.
    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(model.headline)
                .font(.headline)
            Text(model.subtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    @ViewBuilder
    private var commentsSection: some View {
        Section {
            if model.comments.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("No comments")
                        .foregroundStyle(.secondary)
                    Text("The inked pages and a closing instruction are still worth sending on their own.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 2)
            } else {
                ForEach(Array(model.comments.enumerated()), id: \.element.id) { pair in
                    ReviewCommentRow(
                        index: pair.offset + 1,
                        comment: pair.element,
                        text: model.textBinding(for: pair.element.id, environment: environment)
                    )
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) {
                            Task { await self.model.delete(commentId: pair.element.id, environment: self.environment) }
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            }
        } header: {
            Text("Comments")
        } footer: {
            commentsFooter
        }
    }

    @ViewBuilder
    private var commentsFooter: some View {
        if model.canUndoDelete {
            Button("Undo delete") {
                Task { await self.model.undoDelete(environment: self.environment) }
            }
            .font(.footnote)
        } else if model.comments.isEmpty == false {
            Text("In document order. Swipe a comment to delete it, tap its text to edit.")
        }
    }

    /// Hold to talk, the same gesture the comment popover uses.
    ///
    /// The review sheet is where somebody says what they actually want done,
    /// and it used to be the one screen that asked them to put the Pencil down
    /// and find the keyboard's microphone. Same gesture, same wording, so there
    /// is one way to speak to this app rather than two.
    ///
    /// Under VoiceOver a hold is a tap, exactly as `CommentHintRow` does it:
    /// holding is not a gesture VoiceOver passes through, and a control that
    /// only responds to one is a control some people do not have.
    @ViewBuilder
    private var instructionDictationRow: some View {
        if voiceOverEnabled {
            Button(model.isDictatingInstruction ? "Stop dictating" : "Dictate") {
                if model.isDictatingInstruction {
                    model.endInstructionDictation(environment: environment)
                } else {
                    model.beginInstructionDictation(environment: environment)
                }
            }
        } else {
            Label {
                Text(model.isDictatingInstruction ? "Listening\u{2026}" : "**Hold** or squeeze to talk")
                    .foregroundStyle(model.isDictatingInstruction ? .primary : .secondary)
            } icon: {
                Image(systemName: model.isDictatingInstruction ? "mic.fill" : "mic")
                    .foregroundStyle(model.isDictatingInstruction ? Color.accentColor : .secondary)
            }
            .contentShape(.rect)
            .onLongPressGesture(
                minimumDuration: 0.05,
                perform: {},
                onPressingChanged: { isPressing in
                    if isPressing {
                        model.beginInstructionDictation(environment: environment)
                    } else {
                        model.endInstructionDictation(environment: environment)
                    }
                }
            )
            .accessibilityLabel("Hold to dictate the closing instruction")
        }
    }

    /// How stale the last hover may be and still count as "over the section".
    ///
    /// `CommentGestureTuning`'s value, and the same reasoning: a Pencil resting
    /// in a case reports no hover, and one lifted a second ago is still being
    /// aimed at what it was over.
    private static let hoverFreshness: TimeInterval = 1.5

    private func noteHover(_ phase: HoverPhase) {
        switch phase {
        case .active:
            lastInstructionHoverAt = Date()
        case .ended:
            lastInstructionHoverAt = nil
        }
    }

    /// Squeeze to talk, but only over the closing instruction.
    ///
    /// Scoped rather than global on purpose. The reader is still behind this
    /// sheet with its own squeeze handler attached, and a gesture that means
    /// two things at once means neither; requiring the Pencil to be over the
    /// field makes the intent unambiguous to the user as well as to the code.
    private func squeezeBegan() {
        guard ReviewSheet.shouldDictate(lastHoverAt: lastInstructionHoverAt, now: Date()) else { return }
        CommentHaptics.squeezeRecognised()
        model.beginInstructionDictation(environment: environment)
    }

    /// Whether a squeeze arriving now was aimed at the closing instruction.
    ///
    /// Static and pure so it can be tested: a squeeze cannot be simulated, but
    /// the rule deciding what one means is the part that can be wrong, and it
    /// is wrong in two opposite directions. Too strict and the gesture feels
    /// broken; too loose and squeezing for something else starts recording.
    static func shouldDictate(lastHoverAt: Date?, now: Date) -> Bool {
        guard let lastHoverAt else { return false }
        let age = now.timeIntervalSince(lastHoverAt)
        return age >= 0 && age <= ReviewSheet.hoverFreshness
    }

    private var instructionBinding: Binding<String> {
        Binding(
            get: { self.model.closingInstruction },
            set: { value in self.model.closingInstruction = value }
        )
    }
}

#Preview("Review sheet · check-in, comments and ink") {
    ReviewSheet(environment: PreviewEnvironment(), model: ReviewPreviewData.model(origin: ReviewPreviewData.origin(.checkin), readingSeconds: 740))
}

#Preview("Review sheet · check-in, no comments") {
    ReviewSheet(environment: PreviewEnvironment(), model: ReviewPreviewData.model(origin: ReviewPreviewData.origin(.checkin), comments: []))
}

#Preview("Review sheet · poke") {
    ReviewSheet(environment: PreviewEnvironment(), model: ReviewPreviewData.model(origin: ReviewPreviewData.origin(.poke)))
}

#Preview("Review sheet · resume") {
    ReviewSheet(environment: PreviewEnvironment(), model: ReviewPreviewData.model(origin: ReviewPreviewData.origin(.resume)))
}

#Preview("Review sheet · cloud") {
    ReviewSheet(environment: PreviewEnvironment(), model: ReviewPreviewData.model(origin: ReviewPreviewData.origin(.cloud)))
}

#Preview("Review sheet · no return path") {
    ReviewSheet(environment: PreviewEnvironment(), model: ReviewPreviewData.model(origin: ReviewPreviewData.shareOrigin))
}

#Preview("Review sheet · accessibility sizes") {
    ReviewSheet(environment: PreviewEnvironment(), model: ReviewPreviewData.model(origin: ReviewPreviewData.origin(.poke), readingSeconds: 740))
        .environment(\.dynamicTypeSize, .accessibility3)
}
