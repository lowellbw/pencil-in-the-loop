//
//  CommentCaptureModel.swift
//  AppUI · Comment · Model
//
//  The driver. It owns no rules — `VoiceRecordingMachine` has those — and no
//  geometry — `CommentPageResolving` has that. What it owns is the wiring:
//  gesture in, effects out, anchor captured, transcript corrected, comment
//  saved.
//

import Foundation
import CoreGraphics
import Core
import Annotate

/// One document's comment capture: the gesture, the popover, the recording, the
/// markers.
///
/// The Reader creates one per open document, hands it an adapter conforming to
/// `CommentPageResolving`, and calls `attach()`. Everything after that is
/// driven by `CommentGestureTrigger`s and by the popover's own controls.
///
/// **It does not re-implement the recording rules.** `VoiceRecordingMachine` is
/// a pure value type that already encodes them — including that a lift under
/// `GestureTiming.minimumHoldDuration` leaves nothing behind — and this class
/// feeds it events, performs the `Effect`s it returns, and renders its phase.
/// Every "if the hold was long enough" in this file would be a second copy of a
/// rule that is already tested (docs/04-flows.md § F4).
///
/// **On failure:** nothing here throws. A store write that fails leaves the
/// popover open showing why, with the transcript still in it, so the words are
/// not lost. A speech engine that fails moves the popover to
/// `CommentPopoverState.Stage.failed` and the scribble hint is still there.
/// A missing resolver means no popover opens at all, which is the correct
/// behaviour when no document is on screen.
@Observable
public final class CommentCaptureModel {

    // MARK: - Published state

    /// The open popover, or nil when there isn't one.
    public private(set) var popover: CommentPopoverState?

    /// Every comment on this document, in document order: page, then vertical
    /// position within the page.
    public private(set) var comments: [CommentSnapshot]

    /// The saved comments a marker tap opened, for review or deletion. More
    /// than one when several share a line and were drawn as a single marker
    /// with a count (docs/01-design-principles.md).
    public private(set) var selectedComments: [CommentSnapshot] = []

    /// The most recently deleted comment, while an undo is still offered.
    ///
    /// The store holds the real undo stack — restoring keeps the comment's
    /// original id, timestamp and anchor, which re-adding could not
    /// (Protocols.swift § DocumentStoring.deleteComment). This is only what the
    /// UI shows.
    public private(set) var lastDeleted: CommentSnapshot?

    /// Whether on-device speech can run right now. Polled once when the model
    /// is created and again whenever a popover opens; never blocks anything.
    public private(set) var speechAssetState: SpeechAssetState = .ready

    /// The gesture layer, so the Reader can retune it on a device without
    /// reaching through this class.
    public let gestures: CommentGestureController?

    /// Called after the store's copy of this document's comments has changed —
    /// one saved, one deleted, one restored.
    ///
    /// The library row's section and its comment count both come from the
    /// store, and the first comment on a document is what moves it to
    /// "Reviewing" (docs/04-flows.md § F2). The sidebar sits beside the reader
    /// and has nothing else to tell it (`LibraryReloadSignal`). Nil everywhere
    /// but the reader.
    public var onCommentsChanged: (() -> Void)?

    // MARK: - Dependencies

    private let environment: any AppEnvironment
    private let documentId: UUID
    private let documentText: String
    private let documentTitle: String
    private let sourceMap: SourceMap?
    private weak var resolver: (any CommentPageResolving)?

    // MARK: - Machinery

    private var machine = VoiceRecordingMachine()

    /// What is holding the current recording open.
    ///
    /// ─── WHY A RECORDING NEEDS AN OWNER ──────────────────────────────────
    /// Until squeeze became a toggle, every recording was owned by a touch
    /// that was still down, and "the Pencil lifted" and "this recording is
    /// over" were the same fact. `.armingEnded` could therefore be forwarded
    /// as `touchUp` unconditionally, on the reasoning that the machine would
    /// be in `.arming` and would ignore it.
    ///
    /// A squeeze-started recording is owned by nothing. The Pencil is free,
    /// and the arming recogniser watches *every* Pencil touch on the page —
    /// inking included, by design (`CommentGestureController`). So an ordinary
    /// stroke's lift arrived as `touchUp` while the machine was in
    /// `.recording`, which is a real transition, and ended a dictation the
    /// stroke had nothing to do with. Drawing while talking is not an exotic
    /// case: `CommentSurface` deliberately lets touches through to the page
    /// while recording.
    ///
    /// So a lift only ends the recording that lift started.
    private var owner: RecordingOwner = .none

    /// Which gesture a live recording belongs to.
    private enum RecordingOwner {

        /// Nothing is recording.
        case none

        /// A press that is still down: the page long-press, or the popover's
        /// hold-to-talk control. Its release is what ends the recording.
        case touch

        /// A squeeze or a VoiceOver tap. No touch is holding it, so no lift
        /// may end it — only another toggle, a cancel, or a failure.
        case toggle
    }
    private var streamTask: Task<Void, Never>?
    private var stopTask: Task<Void, Never>?
    private var prewarmTask: Task<Void, Never>?
    private var termsTask: Task<[String], Never>?
    private var terms: [String] = []

    /// True while a mode switch is in flight, so that the `dismiss` effect a
    /// cancellation carries does not close a popover the user is still using.
    private var isSwitchingMode = false

    // MARK: - Life cycle

    /// - Parameters:
    ///   - environment: the only way this reaches a store, a transcriber or a
    ///     corrector.
    ///   - documentId: the document comments are saved against.
    ///   - documentText: `DocumentDetail.extractedText`. Anchors are captured
    ///     against exactly this string, and `CommentTextHit.selection` indexes
    ///     into it.
    ///   - documentTitle: seeds the term list along with the text.
    ///   - sourceMap: present only for documents rendered from markdown; it is
    ///     what turns a page rect back into a byte range in `source.md`.
    ///   - comments: what the store already holds, so markers are on screen
    ///     before any asynchronous read completes.
    ///   - resolver: the Reader's adapter. Nil in previews and in tests, where
    ///     there is no page to hit-test against.
    ///   - tuning: the gesture dials.
    public init(
        environment: any AppEnvironment,
        documentId: UUID,
        documentText: String,
        documentTitle: String,
        sourceMap: SourceMap? = nil,
        comments: [CommentSnapshot] = [],
        resolver: (any CommentPageResolving)? = nil,
        tuning: CommentGestureTuning = .standard
    ) {
        self.environment = environment
        self.documentId = documentId
        self.documentText = documentText
        self.documentTitle = documentTitle
        self.sourceMap = sourceMap
        self.comments = Self.inDocumentOrder(comments)
        self.resolver = resolver
        self.gestures = resolver.map { CommentGestureController(resolver: $0, tuning: tuning) }

        self.gestures?.onTrigger = { [weak self] trigger in
            self?.handle(trigger)
        }
        // What tells the reader's own popover apart from a sheet over it, so a
        // squeeze can always stop what the reader is already running
        // (`CommentGestureController.shouldHandleSqueeze`).
        self.gestures?.ownsPopover = { [weak self] in
            self?.popover != nil
        }
        startTermExtraction()
        refreshSpeechAvailability()
    }

    /// Convenience for the Reader, which already holds the whole detail.
    public convenience init(
        environment: any AppEnvironment,
        detail: DocumentDetail,
        resolver: (any CommentPageResolving)? = nil,
        tuning: CommentGestureTuning = .standard
    ) {
        self.init(
            environment: environment,
            documentId: detail.id,
            documentText: detail.extractedText,
            documentTitle: detail.title,
            sourceMap: detail.sourceMap,
            comments: detail.comments,
            resolver: resolver,
            tuning: tuning
        )
    }

    /// Installs the gestures on the Reader's page host view. Idempotent, and
    /// worth calling again whenever that view is replaced.
    public func attach() {
        gestures?.attach()
    }

    /// Removes them. Call when the reader closes.
    public func detach() {
        gestures?.detach()
        cancelEverything()
    }

    // MARK: - Gesture input

    /// The single entry point from UIKit.
    ///
    /// Public so that a device session can drive it from a debug control — and
    /// so that the squeeze path, the long-press path and any future trigger all
    /// arrive the same way rather than each growing its own branch.
    public func handle(_ trigger: CommentGestureTrigger) {
        switch trigger {
        case .armed:
            // Only a plausible comment pre-warms the microphone. Inking is a
            // touch too, and this is why the machine's `touchDown` is not sent
            // for every Pencil contact (VoiceRecordingMachine.Event.touchDown).
            send(.touchDown(at: Date()))

        case .armingEnded:
            // Only the press that started a recording may end it. While arming
            // this is the lift that abandons the gesture, which is what it is
            // for; during a squeeze-started recording it is somebody drawing,
            // and forwarding it stopped their dictation mid-sentence (`owner`).
            guard endsTouchOwnedRecording else { break }
            send(.touchUp(at: Date()))

        case let .holdBegan(point):
            // A pause mid-stroke reaches the hold recogniser too. While
            // something is already being dictated that used to call `present`,
            // which replaces `machine` and `popover` outright and threw the
            // sentence in progress away; a second popover is not what a pause
            // means (`owner`).
            guard machine.isRecording == false else { break }
            open(at: point, recording: true)

        case let .squeezeToggled(point):
            // Squeeze is a toggle, and it reuses the path VoiceOver already
            // takes (`toggleRecording`) so there is one definition of what
            // toggling means rather than two that can drift. With a popover
            // open it starts or stops whatever is in front of the user —
            // including one opened from the selection menu that has not begun
            // recording yet. With no popover there is nothing to toggle, so the
            // squeeze opens one and starts, exactly as it always did.
            plsq("reader squeezeToggled popover=\(popover != nil) recording=\(machine.isRecording)")
            // `isRecording` is asked first, ahead of `popover != nil`, so that
            // stopping never depends on the popover still being there. The two
            // are kept in step today and the order should not matter; making
            // the stop the first question means a squeeze can always end a
            // recording even if some future path lets them drift apart, which
            // is the failure worth being structurally safe against — a
            // microphone left open has no other way out.
            if machine.isRecording {
                owner = .none
                send(.touchUp(at: Date()))
            } else if popover != nil {
                toggleRecording()
            } else {
                open(at: point, recording: true, startedBy: .toggle)
            }

        case .holdEnded:
            guard endsTouchOwnedRecording else { break }
            send(.touchUp(at: Date()))

        case .holdCancelled:
            send(.cancelled)
        }
    }

    /// The text-selection menu's "Comment" item (docs/02-spec.md § S2).
    ///
    /// Opens the popover on an existing selection without starting a recording:
    /// there is no press to hold, so the user holds the popover's own
    /// hold-to-talk control, or taps through to scribble.
    ///
    /// - Parameter point: where to anchor the popover, in
    ///   `CommentPageResolving.pageHostView` coordinates — normally the
    ///   selection's own rect.
    public func beginComment(from hit: CommentTextHit, at point: CGPoint) {
        present(anchor: anchor(from: hit), at: point, recording: false)
    }

    // MARK: - Popover controls

    /// The popover's hold-to-talk control went down.
    public func beginHoldToTalk() {
        guard popover != nil else { return }
        owner = .touch
        send(.holdRecognised(at: Date()))
    }

    /// The popover's hold-to-talk control came up. Under
    /// `GestureTiming.minimumHoldDuration` this discards, exactly as a Pencil
    /// lift does — the rule lives in the machine and applies to both.
    public func endHoldToTalk() {
        guard endsTouchOwnedRecording else { return }
        owner = .none
        send(.touchUp(at: Date()))
    }

    /// Start or stop recording with a tap rather than a hold.
    ///
    /// For VoiceOver, where holding a control is not a gesture anyone can make.
    /// It drives the same machine and the same rules — a start and stop less
    /// than `GestureTiming.minimumHoldDuration` apart still discards, because
    /// that rule is about how little was said, not about how it was triggered.
    public func toggleRecording() {
        guard popover != nil else { return }
        if machine.isRecording {
            owner = .none
            send(.touchUp(at: Date()))
        } else {
            owner = .toggle
            send(.holdRecognised(at: Date()))
        }
    }

    /// "✎ scribble instead": swap the popover's body for a Scribble field,
    /// keeping the same anchor (docs/02-spec.md § S3).
    ///
    /// A recording in progress is cancelled rather than saved. The words spoken
    /// so far are dropped on purpose: the user has just said, by tapping, that
    /// speaking was the wrong choice.
    public func switchToScribble() {
        guard popover != nil else { return }
        isSwitchingMode = true
        send(.cancelled)
        isSwitchingMode = false
        machine = VoiceRecordingMachine()
        popover?.mode = .scribble
        popover?.stage = .waiting
    }

    /// Back from the Scribble field to press-and-hold.
    public func switchToVoice() {
        guard popover != nil else { return }
        machine = VoiceRecordingMachine()
        popover?.mode = .voice
        popover?.stage = .waiting
    }

    /// What the Scribble field currently holds.
    public func updateScribbleText(_ text: String) {
        popover?.scribbleText = text
    }

    /// Saves what was scribbled, as `CommentSource.handwriting`.
    ///
    /// Not run through the term-list corrector: that repairs a speech
    /// transcript, and a handwriting field has already produced the characters
    /// the user meant (Protocols.swift § TranscriptCorrecting).
    public func saveScribble() {
        guard let state = popover, state.mode == .scribble else { return }
        let text = state.scribbleText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            close()
            return
        }
        save(text: text, source: .handwriting, anchor: state.anchor, correcting: false)
    }

    /// Whether audio is being captured right now.
    ///
    /// Read by `CommentSurface` to hold the popover open while it is true. A
    /// popover dismissal *discards* (`dismissPopover`), and the reader scrolls
    /// under an open popover — so without this a scroll to see the rest of the
    /// paragraph you are talking about throws away the sentence you just said.
    public var isRecording: Bool { machine.isRecording }

    /// Whether a Pencil lift arriving now should be forwarded as `touchUp`.
    ///
    /// True while arming — the lift that abandons a gesture before it becomes
    /// anything still has to be reported — and while a *touch-owned* recording
    /// is running. False for a squeeze- or VoiceOver-started one, which no lift
    /// may end (`owner`).
    private var endsTouchOwnedRecording: Bool {
        machine.isRecording ? owner == .touch : true
    }

    /// The popover went away — tapped away, scrolled out from under, or the
    /// app went to the background.
    ///
    /// **A dismissal mid-recording keeps what was said.** It used to cancel, on
    /// the reasoning that a dismissal is not a save. That reasoning holds for
    /// an idle popover and fails badly for a recording one: every way a popover
    /// can be dismissed is something the user did *to the document* — scrolled
    /// it, tapped it, took a call — and none of them mean "throw away the
    /// sentence I just spoke". Discarding is unrecoverable; a comment saved by
    /// mistake is one marker to delete.
    ///
    /// Nothing is closed here in that case. The machine moves to `finishing`,
    /// the transcript settles, and the `commit`/`dismiss` effects close the
    /// popover in their own time — closing now would cut the final word off
    /// (`VoiceRecordingMachine` § finishing).
    ///
    /// The mis-touch rule is untouched: under `minimumHoldDuration` still
    /// discards, because that rule is about how little was said.
    public func dismissPopover() {
        guard popover != nil else { return }
        if machine.isFinished {
            close()
        } else if machine.isRecording {
            send(.touchUp(at: Date()))
        } else {
            send(.cancelled)
            close()
        }
    }

    // MARK: - Markers

    /// A marker was tapped: open what it stands for, for review or deletion
    /// (docs/02-spec.md § S2).
    public func selectComments(ids: [UUID]) {
        let wanted = Set(ids)
        selectedComments = comments.filter { wanted.contains($0.id) }
        lastDeleted = nil
    }

    /// The one comment a marker stands for, when it stands for one.
    public var selectedComment: CommentSnapshot? { selectedComments.first }

    /// Close the marker's popover.
    public func clearSelection() {
        selectedComments = []
        lastDeleted = nil
    }

    /// Deletes a comment, undoably for the session.
    ///
    /// The marker disappears immediately and the popover switches to its
    /// "Deleted — Undo" state rather than closing, so the undo is where the
    /// user is looking (docs/02-spec.md § Cross-cutting: nothing is destructive
    /// without undo).
    public func delete(_ comment: CommentSnapshot) {
        comments.removeAll { $0.id == comment.id }
        selectedComments.removeAll { $0.id == comment.id }
        lastDeleted = comment
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.environment.store.deleteComment(id: comment.id)
                self.onCommentsChanged?()
            } catch {
                // The delete did not happen, so neither should the disappearance.
                self.comments = Self.inDocumentOrder(self.comments + [comment])
                self.selectedComments = Self.inDocumentOrder(self.selectedComments + [comment])
                self.lastDeleted = nil
            }
        }
    }

    /// Restores the most recently deleted comment, with its original id and
    /// timestamp.
    ///
    /// - Returns: nothing; an empty undo stack is an answer, not a failure, and
    ///   the UI may call this without checking first.
    public func undoDeletion() {
        lastDeleted = nil
        Task { [weak self] in
            guard let self else { return }
            guard let restored = try? await self.environment.store.undoLastCommentDeletion() else { return }
            self.comments = Self.inDocumentOrder(self.comments + [restored])
            self.selectedComments = Self.inDocumentOrder(self.selectedComments + [restored])
            self.onCommentsChanged?()
        }
    }

    /// Re-reads the comment list from the store. For after a review is sent, or
    /// a reply arrives.
    public func refreshComments() {
        Task { [weak self] in
            guard let self else { return }
            guard let stored = try? await self.environment.store.comments(documentId: self.documentId) else { return }
            self.comments = Self.inDocumentOrder(stored)
        }
    }

    // MARK: - Anchor capture

    /// Builds an anchor from a hit, expanding it to a sentence or a line.
    ///
    /// The expansion, the 32 characters of context either side and the
    /// verbatim quote all come from `AnchorResolver.captureAnchor(…)`, which is
    /// idempotent and is the same code the review's consumer climbs back up. A
    /// second implementation here is exactly how a comment lands in the wrong
    /// place after a document is regenerated (docs/03-architecture.md § 3).
    public func anchor(from hit: CommentTextHit) -> Anchor {
        let mappedRange = sourceMap?.range(nearest: hit.normalisedRect, page: hit.pageIndex)

        guard hit.hasText else {
            // A figure, a margin, a page with no text layer. A rect-only anchor
            // is honest and resolves as `AnchorResolution.rectFallback`, which
            // every consumer is required to describe as approximate.
            return Anchor(
                quoted: "",
                pageIndex: hit.pageIndex,
                normalisedRect: hit.normalisedRect,
                sourceRange: mappedRange
            )
        }

        // The Reader may not be able to say where its selection sits in the
        // extracted text; finding the quote is cheap and exact when it is
        // unique, which for a sentence it almost always is.
        let selection = hit.selection
            ?? AnchorResolver.exactQuoteRange(quoted: hit.quotedText, in: documentText)

        guard let selection else {
            return Anchor(
                quoted: hit.quotedText,
                pageIndex: hit.pageIndex,
                normalisedRect: hit.normalisedRect,
                sourceRange: mappedRange
            )
        }

        return AnchorResolver.captureAnchor(
            in: documentText,
            selection: selection,
            pageIndex: hit.pageIndex,
            normalisedRect: hit.normalisedRect,
            sourceRange: mappedRange
        )
    }

    // MARK: - Private

    private func open(at point: CGPoint, recording: Bool, startedBy: RecordingOwner = .touch) {
        guard let hit = resolver?.textHit(at: point) else { return }
        present(anchor: anchor(from: hit), at: point, recording: recording, startedBy: startedBy)
    }

    private func present(
        anchor: Anchor,
        at point: CGPoint,
        recording: Bool,
        startedBy: RecordingOwner = .touch
    ) {
        refreshSpeechAvailability()
        let canSpeak = isSpeechUsable
        machine = VoiceRecordingMachine()
        popover = CommentPopoverState(
            anchor: anchor,
            anchorPoint: point,
            mode: canSpeak ? .voice : .scribble,
            stage: .waiting,
            isSpeechAvailable: canSpeak
        )
        guard recording, canSpeak else {
            owner = .none
            return
        }
        owner = startedBy
        send(.holdRecognised(at: Date()))
    }

    private var isSpeechUsable: Bool {
        if case .unavailable = speechAssetState { return false }
        return true
    }

    private func send(_ event: VoiceRecordingMachine.Event) {
        apply(machine.handle(event))
        syncPopover()
    }

    private func apply(_ effects: [VoiceRecordingMachine.Effect]) {
        for effect in effects {
            switch effect {
            case .prewarmCapture:
                prewarm()
            case .startTranscribing:
                startTranscribing()
            case .stopTranscribing:
                stopTranscribing()
            case .releaseCapture:
                streamTask?.cancel()
                streamTask = nil
            case let .commit(text):
                guard let anchor = popover?.anchor else { break }
                save(text: text, source: .voice, anchor: anchor, correcting: true)
            case .dismiss:
                guard !isSwitchingMode else { break }
                close()
            }
        }
    }

    /// Mirrors the machine into the popover. The machine is the truth; this is
    /// only the projection the view reads.
    private func syncPopover() {
        guard var state = popover else { return }
        state.update = machine.update
        switch machine.phase {
        case .idle, .arming, .discarded:
            state.stage = .waiting
        case .recording:
            state.stage = .recording
        case .finishing:
            state.stage = .finishing
        case .completed:
            state.stage = .saving
        case let .failed(error):
            state.stage = .failed(message: error.message)
        }
        popover = state
    }

    private func prewarm() {
        let transcriber = environment.transcriber
        prewarmTask?.cancel()
        prewarmTask = Task {
            // Best-effort and never waited on: it is an optimisation, and
            // dictation works without it (Protocols.swift § prewarm).
            await transcriber.prewarm()
        }
    }

    private func startTranscribing() {
        let transcriber = environment.transcriber
        let contextualTerms = terms
        streamTask?.cancel()
        streamTask = Task { [weak self] in
            do {
                for try await value in transcriber.transcribe(contextualTerms: contextualTerms) {
                    guard let self else { return }
                    self.send(.transcriptUpdated(value))
                }
                // Finished with no error and no stop: recognition gave up on
                // its own. `ContinuousTranscriber` already restarts an engine
                // that merely finalised an utterance, so this is the real
                // thing. Reporting it keeps whatever was transcribed and tells
                // the user, rather than leaving the popover listening to
                // nothing (ContinuousTranscriber § the bug this exists for).
                self?.send(.failed(.speechUnavailable(reason: "Dictation stopped.")))
            } catch let error as PencilLoopError {
                self?.send(.failed(error))
            } catch {
                self?.send(.failed(.speechUnavailable(reason: error.localizedDescription)))
            }
        }
    }

    private func stopTranscribing() {
        let transcriber = environment.transcriber
        stopTask?.cancel()
        stopTask = Task { [weak self] in
            // The contract says to prefer this over the last streamed update:
            // the engine may finalise a trailing word after the last yield.
            let settled = await transcriber.stop()
            self?.send(.finalText(settled))
        }
    }

    private func save(text: String, source: CommentSource, anchor: Anchor, correcting: Bool) {
        popover?.stage = .saving
        let identifier = documentId
        let corrector = environment.corrector
        let store = environment.store
        Task { [weak self] in
            guard let self else { return }
            let resolved: String
            if correcting {
                // `SpeechAnalyzer` has no vocabulary-biasing API, so document
                // jargon is repaired here, once, at save
                // (docs/03-architecture.md § 4).
                resolved = corrector.correct(text, against: await self.currentTerms())
            } else {
                resolved = text
            }
            let draft = CommentDraft(
                text: resolved,
                source: source,
                anchor: anchor,
                resolvedOnPage: anchor.pageIndex
            )
            do {
                let saved = try await store.addComment(draft, documentId: identifier)
                self.comments = Self.inDocumentOrder(self.comments + [saved])
                CommentHaptics.commentSaved()
                self.close()
                self.onCommentsChanged?()
            } catch {
                // The words stay on screen. Losing a spoken sentence to a
                // storage error would be the worst failure this feature has.
                self.popover?.stage = .failed(message: Self.message(for: error))
            }
        }
    }

    private func close() {
        popover = nil
        machine = VoiceRecordingMachine()
        owner = .none
        streamTask?.cancel()
        streamTask = nil
    }

    private func cancelEverything() {
        streamTask?.cancel()
        stopTask?.cancel()
        prewarmTask?.cancel()
        streamTask = nil
        stopTask = nil
        prewarmTask = nil
        popover = nil
        machine = VoiceRecordingMachine()
        owner = .none
    }

    private func startTermExtraction() {
        let corrector = environment.corrector
        let text = documentText
        let title = documentTitle
        // Off the main actor: it walks the whole document once, and it is
        // wanted only by the time a recording ends.
        let task = Task.detached(priority: .utility) {
            corrector.terms(forDocumentText: text, title: title)
        }
        termsTask = task
        Task { [weak self] in
            let extracted = await task.value
            self?.terms = extracted
        }
    }

    private func currentTerms() async -> [String] {
        guard let termsTask else { return terms }
        return await termsTask.value
    }

    private func refreshSpeechAvailability() {
        let transcriber = environment.transcriber
        Task { [weak self] in
            let state = await transcriber.assetState()
            self?.speechAssetState = state
        }
    }

    /// Page, then vertical position within the page — the order the review
    /// sheet and the exported bundle both use.
    static func inDocumentOrder(_ input: [CommentSnapshot]) -> [CommentSnapshot] {
        input.sorted { left, right in
            if left.resolvedOnPage != right.resolvedOnPage {
                return left.resolvedOnPage < right.resolvedOnPage
            }
            if left.anchor.normalisedRect.y != right.anchor.normalisedRect.y {
                return left.anchor.normalisedRect.y < right.anchor.normalisedRect.y
            }
            return left.createdAt < right.createdAt
        }
    }

    static func message(for error: any Error) -> String {
        guard let known = error as? PencilLoopError else {
            return "Could not save this comment."
        }
        return known.message
    }
}
