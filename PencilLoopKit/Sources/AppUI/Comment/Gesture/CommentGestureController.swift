//
//  CommentGestureController.swift
//  AppUI · Comment · Gesture
//
//  Everything UIKit knows about comment capture. One object, installed on the
//  Reader's page host view, reporting `CommentGestureTrigger`s and nothing else.
//

import Foundation
import PencilKit
import UIKit
import Core

/// Installs the comment gestures on the Reader's page view and reports what
/// they mean.
///
/// **How it coexists with the canvas.** Two `PencilCommentGesture`s — one to
/// arm at `CommentGestureTuning.armingDuration`, one to trigger at
/// `GestureTiming.longPressDuration` — plus an optional
/// `UIHoverGestureRecognizer` and a `UIPencilInteraction`. None of them delays,
/// cancels or otherwise touches the canvas's own recognisers: the delegate
/// below returns `true` for simultaneous recognition with everything, so
/// `PKCanvasView` keeps receiving Pencil touches at full speed and draws the
/// dot it always would have drawn. When the hold wins,
/// `InFlightStrokeCanceller` takes that dot back (docs/02-spec.md § S2).
///
/// **On failure:** installing on a nil host view is a no-op and can be retried;
/// `detach()` is idempotent; a squeeze from an iPad with no Pencil Pro simply
/// never arrives. There is no error path, because every failure here is "the
/// secondary trigger was unavailable", and long-press still works.
public final class CommentGestureController: NSObject, UIGestureRecognizerDelegate, UIPencilInteractionDelegate {

    /// Where triggers go. Set by `CommentCaptureModel` before `attach()`.
    public var onTrigger: ((CommentGestureTrigger) -> Void)?

    /// Whether the reader currently has a comment popover of its own on screen.
    /// Set by `CommentCaptureModel` alongside `onTrigger`.
    ///
    /// Read only by `shouldHandleSqueeze(isCovered:ownsPopover:)`, to tell the
    /// reader's own presentation apart from somebody else's screen over it.
    /// Absent — in a preview, or before the model wires it — reads as false,
    /// which is the conservative answer: the squeeze is scoped as it was.
    public var ownsPopover: (() -> Bool)?

    /// The dials. Replacing this re-installs the recognisers with the new
    /// numbers, which is what makes a device session a one-line change.
    public var tuning: CommentGestureTuning {
        didSet {
            canceller = InFlightStrokeCanceller(tuning: tuning)
            guard isAttached else { return }
            detach()
            attach()
        }
    }

    private weak var resolver: (any CommentPageResolving)?
    private var canceller: InFlightStrokeCanceller

    private var armingGesture: PencilCommentGesture?
    private var holdGesture: PencilCommentGesture?
    private var hoverGesture: UIHoverGestureRecognizer?
    private var pencilInteraction: UIPencilInteraction?
    private weak var hostView: UIView?

    private var lastHoverPoint: CGPoint?
    private var lastHoverAt: Date?

    /// - Parameters:
    ///   - resolver: the Reader's adapter. Held weakly — the Reader owns it.
    ///   - tuning: the dials; `.standard` unless a device session says
    ///     otherwise.
    public init(resolver: any CommentPageResolving, tuning: CommentGestureTuning = .standard) {
        self.resolver = resolver
        self.tuning = tuning
        self.canceller = InFlightStrokeCanceller(tuning: tuning)
        super.init()
    }

    /// True once the recognisers are on a view.
    public private(set) var isAttached = false

    // MARK: - Installation

    /// Installs the recognisers on `CommentPageResolving.pageHostView`.
    ///
    /// Safe to call repeatedly: a second call with the same host view does
    /// nothing, and one with a different host moves the recognisers. Call it
    /// again after the Reader opens a different document — `PDFView` replaces
    /// its document view and the old one takes the recognisers with it.
    public func attach() {
        guard let host = resolver?.pageHostView else { return }
        if isAttached, hostView === host { return }
        if isAttached { detach() }

        let arming = PencilCommentGesture(
            role: .arming,
            tuning: tuning,
            target: self,
            action: #selector(handleArming(_:))
        )
        let hold = PencilCommentGesture(
            role: .hold,
            tuning: tuning,
            target: self,
            action: #selector(handleHold(_:))
        )
        arming.delegate = self
        hold.delegate = self
        host.addGestureRecognizer(arming)
        host.addGestureRecognizer(hold)
        armingGesture = arming
        holdGesture = hold

        if tuning.hoverTrackingEnabled {
            let hover = UIHoverGestureRecognizer(target: self, action: #selector(handleHover(_:)))
            hover.delegate = self
            host.addGestureRecognizer(hover)
            hoverGesture = hover
        }

        if tuning.squeezeEnabled {
            let interaction = UIPencilInteraction()
            interaction.delegate = self
            host.addInteraction(interaction)
            pencilInteraction = interaction
        }

        hostView = host
        isAttached = true
    }

    /// Removes everything this controller installed. Idempotent.
    public func detach() {
        if let host = hostView {
            if let arming = armingGesture { host.removeGestureRecognizer(arming) }
            if let hold = holdGesture { host.removeGestureRecognizer(hold) }
            if let hover = hoverGesture { host.removeGestureRecognizer(hover) }
            if let interaction = pencilInteraction { host.removeInteraction(interaction) }
        }
        armingGesture = nil
        holdGesture = nil
        hoverGesture = nil
        pencilInteraction = nil
        hostView = nil
        lastHoverPoint = nil
        lastHoverAt = nil
        canceller.disarm()
        isAttached = false
    }

    deinit {
        // `detach()` is main-actor work and deinit is not, so the recognisers
        // are released with the host view rather than removed here. A view that
        // has outlived its controller holds recognisers whose target is nil,
        // which UIKit treats as inert.
    }

    // MARK: - Long press

    @objc
    private func handleArming(_ gesture: UILongPressGestureRecognizer) {
        guard let point = (gesture as? PencilCommentGesture)?.pointInHostView else { return }
        switch gesture.state {
        case .began:
            // Remember the canvas and its pre-press drawing now, while the dot
            // is certainly still in flight and certainly not committed.
            let page = resolver?.pageIndex(at: point)
            canceller.arm(page.flatMap { resolver?.inkOverlay(forPageIndex: $0) })
            onTrigger?(.armed(point: point))
        case .ended, .cancelled, .failed:
            canceller.disarm()
            onTrigger?(.armingEnded)
        case .possible, .changed:
            break
        @unknown default:
            break
        }
    }

    @objc
    private func handleHold(_ gesture: UILongPressGestureRecognizer) {
        switch gesture.state {
        case .began:
            guard let point = (gesture as? PencilCommentGesture)?.pointInHostView else { return }
            // Take the dot back before anything is shown, so its life is one
            // runloop turn rather than the life of the popover.
            canceller.cancel()
            onTrigger?(.holdBegan(point: point))
        case .ended:
            onTrigger?(.holdEnded)
        case .cancelled, .failed:
            onTrigger?(.holdCancelled)
        case .possible, .changed:
            break
        @unknown default:
            break
        }
    }

    // MARK: - Hover

    @objc
    private func handleHover(_ gesture: UIHoverGestureRecognizer) {
        guard let host = hostView else { return }
        switch gesture.state {
        case .began, .changed:
            lastHoverPoint = gesture.location(in: host)
            lastHoverAt = Date()
        case .ended, .cancelled, .failed:
            lastHoverPoint = nil
            lastHoverAt = nil
        case .possible:
            break
        @unknown default:
            break
        }
    }

    /// Where a squeeze should anchor: the hover point when the Pencil is over
    /// the screen, otherwise the centre of the host view.
    ///
    /// The fallback matters. A squeeze with no hover is the case where the
    /// Pencil is in a hand at rest, and refusing to open a popover because
    /// nothing was hovering would make the shortcut feel broken rather than
    /// optional.
    public var squeezeAnchorPoint: CGPoint? {
        if let point = lastHoverPoint, let at = lastHoverAt,
           Date().timeIntervalSince(at) <= tuning.hoverFreshness {
            return point
        }
        guard let host = hostView else { return nil }
        return CGPoint(x: host.bounds.midX, y: host.bounds.midY)
    }

    // MARK: - UIGestureRecognizerDelegate

    /// Everything recognises simultaneously with everything.
    ///
    /// This is what keeps the canvas at full speed: these recognisers observe a
    /// press, they never claim it, and `PKCanvasView`'s own drawing recogniser
    /// is never told to wait for or defer to them.
    public func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
    ) -> Bool {
        true
    }

    /// Never require another recogniser to fail first — that is the delay this
    /// whole design exists to avoid.
    public func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRequireFailureOf other: UIGestureRecognizer
    ) -> Bool {
        false
    }

    /// Never make another recogniser wait for these.
    public func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldBeRequiredToFailBy other: UIGestureRecognizer
    ) -> Bool {
        false
    }

    // MARK: - UIPencilInteractionDelegate

    /// Pencil Pro squeeze, mapped to press-and-hold: squeeze and hold to talk,
    /// release to save, exactly like the long press
    /// (docs/04-flows.md § F4).
    ///
    /// **Secondary, always.** A user who has remapped the squeeze system-wide,
    /// or who has no Pencil Pro, loses nothing — every one of these paths is
    /// reachable by long press (docs/01-design-principles.md rule 5).
    public func pencilInteraction(
        _ interaction: UIPencilInteraction,
        didReceiveSqueeze squeeze: UIPencilInteraction.Squeeze
    ) {
        guard tuning.squeezeEnabled else { return }

        // ─── WHOSE SQUEEZE IS THIS? ──────────────────────────────────────────
        // A squeeze is device-level: it arrives at every `UIPencilInteraction`
        // in a visible hierarchy, and the reader stays visible underneath a
        // sheet. So with the review sheet open, one squeeze reached both its
        // reporter *and* this controller, and this one opened a comment popover
        // and started recording behind the sheet.
        //
        // That is not merely untidy. Both recordings resolve to the same engine
        // (one per language), and starting a second resets the accumulated
        // transcript of the first — so a stray recording behind a sheet silently
        // threw away the comment being dictated in front of it.
        //
        // "Is anything presented over me" was the first answer and it was the
        // wrong question, because **the reader's own comment popover is a
        // presentation too** (`CommentSurface` uses SwiftUI's `.popover`, which
        // on iPadOS is a real UIKit one). So the guard fired hardest exactly
        // when the popover was open — which is when the user squeezes to *stop*
        // — and ate the gesture, leaving the microphone running with nothing
        // able to close it. It did so silently and intermittently, since
        // whether the presentation lands on the root or on a descendant
        // hosting controller depends on the split view's state.
        //
        // `ReviewSheet.squeezeToggled` had already reasoned this out for the
        // other consumer: **stopping is not scoped, starting is.** Same rule
        // here, in the same shape — a pure function, because a squeeze cannot
        // be simulated and this is the part that can be wrong on its own.
        let isCovered = hostView?.window?.rootViewController?.presentedViewController != nil
        let ownsPopover = self.ownsPopover?() ?? false
        let handles = Self.shouldHandleSqueeze(isCovered: isCovered, ownsPopover: ownsPopover)
        plsq("reader squeeze phase=\(squeeze.phase) covered=\(isCovered) ownsPopover=\(ownsPopover) handles=\(handles)")
        guard handles else { return }

        switch squeeze.phase {
        case .ended:
            // `ended` is the phase that means *recognised*: the header defines
            // it as a continuous gesture ending or a discrete one being
            // recognised. `cancelled` is deliberately not folded in, as it was
            // when this drove a press-and-hold. There the risk was a microphone
            // left live by an untidy gesture, so cancelling had to stop it;
            // here a cancelled squeeze is one the user never completed, and
            // toggling on the strength of it starts a recording nobody asked
            // for. A toggle has no half-finished state to unwind.
            guard let point = squeezeAnchorPoint else { return }
            CommentHaptics.squeezeRecognised()
            onTrigger?(.squeezeToggled(point: point))
        case .began, .changed, .cancelled:
            break
        @unknown default:
            break
        }
    }

    /// Whether a squeeze arriving now is the reader's to act on.
    ///
    /// Static and pure so it can be tested: a squeeze cannot be simulated and
    /// a Pencil Pro does not exist in the Simulator, but this rule can be wrong
    /// on its own, in two opposite directions. Too loose and a squeeze meant
    /// for a sheet starts a recording behind it; too strict and a live
    /// recording cannot be stopped.
    ///
    /// - Parameters:
    ///   - isCovered: whether anything is presented over the reader — including,
    ///     unavoidably, the reader's own comment popover.
    ///   - ownsPopover: whether that presentation is the reader's own popover.
    ///
    /// The asymmetry is the whole point, and it is `ReviewSheet`'s: **a squeeze
    /// that might stop something the reader is already running is never
    /// refused.** Scoping a stop is how a microphone gets left open with no
    /// gesture able to close it.
    static func shouldHandleSqueeze(isCovered: Bool, ownsPopover: Bool) -> Bool {
        ownsPopover || isCovered == false
    }
}
