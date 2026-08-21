//
//  CommentSurface.swift
//  AppUI · Comment · Views
//
//  How the Reader gets the comment popover: one modifier, one model, no
//  knowledge of any of the parts.
//

import SwiftUI
import CoreGraphics

/// Hosts the comment popover over whatever it is applied to.
///
/// **Apply it to the view that hosts the pages**, the same view the model's
/// `CommentPageResolving` names as `pageHostView`. Every point in this feature
/// — the press, the anchor rect, the popover's attachment — is in that one
/// coordinate space, and applying this modifier to a different view moves the
/// popover away from the passage it is about.
///
/// Prefer `View.commentCapture(_:)` to naming this type.
///
/// **Never fails.** With no popover open it adds nothing but a hidden
/// attachment rect.
public struct CommentSurface: ViewModifier {

    /// The document's capture model.
    public var model: CommentCaptureModel

    @Environment(\.scenePhase) private var scenePhase

    public init(model: CommentCaptureModel) {
        self.model = model
    }

    public func body(content: Content) -> some View {
        content
            .popover(
                isPresented: presentation,
                attachmentAnchor: .rect(.rect(attachmentRect)),
                arrowEdge: .top
            ) {
                if let state = model.popover {
                    CommentPopoverView(
                        state: state,
                        onHoldBegan: { model.beginHoldToTalk() },
                        onHoldEnded: { model.endHoldToTalk() },
                        onToggleRecording: { model.toggleRecording() },
                        onScribble: { model.switchToScribble() },
                        onVoice: { model.switchToVoice() },
                        onSave: { model.saveScribble() },
                        onScribbleTextChanged: { model.updateScribbleText($0) }
                    )
                    .presentationCompactAdaptation(.popover)
                    // ─── WHY A RECORDING PINS THE POPOVER OPEN ───────────────
                    // A popover dismisses when you touch outside it, and the
                    // reader scrolls underneath. Scrolling to see the rest of
                    // the paragraph you are talking about therefore dismissed
                    // the popover, and `dismissPopover` cancels — so the scroll
                    // threw the sentence away. Both modifiers are conditional:
                    // while recording the popover holds and the scroll passes
                    // through to the page, and the moment recording stops it is
                    // an ordinary popover again that tapping away closes.
                    //
                    // Dismissal is deliberately *not* disabled outright. A
                    // recording begun with a squeeze is ended with a squeeze,
                    // and a Pencil that runs out of battery mid-sentence would
                    // leave a popover nothing could close. Letting it dismiss
                    // and making dismissal keep the speech (`dismissPopover`)
                    // is the version with no trap in it.
                    .presentationBackgroundInteraction(
                        model.isRecording ? .enabled : .automatic
                    )
                }
            }
            // Backgrounding ends the recording, because audio does not survive
            // it. What happens to the words is `dismissPopover`'s single rule
            // and not a second one here: mid-recording it keeps them, idle it
            // cancels.
            .onChange(of: scenePhase) { _, phase in
                guard phase != .active, model.popover != nil else { return }
                model.dismissPopover()
            }
    }

    /// A small rect around the touch point, so the popover's arrow points at
    /// the passage rather than at the corner of the page.
    private var attachmentRect: CGRect {
        guard let point = model.popover?.anchorPoint else { return .zero }
        return CGRect(x: point.x - 8, y: point.y - 8, width: 16, height: 16)
    }

    private var presentation: Binding<Bool> {
        Binding(
            get: { model.popover != nil },
            set: { presented in
                guard !presented else { return }
                // Tapped away, or the system took it. Either way this is a
                // cancellation and not a save — `VoiceRecordingMachine` treats
                // a dismissal as `.cancelled`, which leaves nothing behind.
                model.dismissPopover()
            }
        )
    }
}

extension View {

    /// Hosts the comment popover for one document.
    ///
    /// Apply to the page host view. See `CommentSurface` for why that matters.
    public func commentCapture(_ model: CommentCaptureModel) -> some View {
        modifier(CommentSurface(model: model))
    }
}
