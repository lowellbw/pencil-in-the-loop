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
                }
            }
            // Backgrounding mid-recording is a cancellation, not a save. The
            // machine says so (`VoiceRecordingMachine.Event.cancelled`), and
            // nothing else is watching for it.
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
