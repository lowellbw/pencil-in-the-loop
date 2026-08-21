//
//  ReaderDocumentCoordinator.swift
//  AppUI · Reader
//
//  The UIKit half of the reader: the overlay provider that drives
//  `PageCanvasPool`, the reader's own finger gestures, and the "Comment" item
//  in the text-selection menu.
//
//  ─── THE OVERLAY CONTRACT, AND THE BUG IT AVOIDS ─────────────────────────────
//  One canvas per page, recycled with the page views, never one canvas over the
//  whole scroll view (docs/03-architecture.md § 2). All of that lives in
//  `PageCanvasPool`; this file's only job is to ask it the right question and to
//  tell it the truth about when a page has gone.
//
//  The failure worth naming: scroll a page away and straight back inside the
//  500ms autosave debounce, and the strokes must still be there. They are, and
//  not because of anything here — the pending drawing lives in
//  `InkPersistenceCoordinator`, keyed by document and page, and its
//  `drawingData(for:)` answers pending-first. What this file must not do is
//  break that, which means: never close the coordinator on a page change, never
//  build a second pool for the same document, and always hand the pool the same
//  page index for the same page, so the binding it rebuilds is the binding it
//  flushed. `PDFDocument.index(for:)` reports `NSNotFound` rather than failing,
//  which is why every index here is checked before it is used.
//  ─────────────────────────────────────────────────────────────────────────────
//

import CoreGraphics
import Foundation
import PDFKit
import QuartzCore
import UIKit
import Annotate
import Core

/// Drives `PDFView` on the reader's behalf.
///
/// **Isolation.** Main actor. PDFKit's protocols are not annotated for
/// concurrency, so the two conformances below are `@preconcurrency`; every
/// callback in them arrives on the main thread in practice, which is what that
/// attribute asserts.
///
/// **On failure:** every path degrades to "no ink layer on this page" or "no
/// menu item", logged, never thrown. A reader that will not scroll because a
/// page index could not be resolved would be a far worse outcome than a page
/// without a canvas.
public final class ReaderDocumentCoordinator: NSObject {

    private let model: ReaderModel

    private weak var pdfView: PDFView?
    private var observers: [any NSObjectProtocol] = []
    private var scaleSettleTask: Task<Void, Never>?
    private var displayLink: CADisplayLink?
    private var motionDeadline = Date.distantPast
    private var lastMotionRect: CGRect?
    private var appliedDocumentId: UUID?
    private var hasRestoredPosition = false

    /// The one recogniser here that a Pencil can reach. Kept so the delegate
    /// can tell it apart from the finger-only three and ask the extra question
    /// only of it (`installGestures`).
    private weak var offPageTap: UITapGestureRecognizer?

    /// How long after the last movement the marker layer stops being redrawn
    /// every frame. Long enough to cover a flick's momentum, short enough that
    /// nothing keeps ticking while the reader reads.
    private static let motionTail: TimeInterval = 0.6

    public init(model: ReaderModel) {
        self.model = model
        super.init()
    }

    // MARK: - Installation

    /// Takes ownership of a freshly made `PDFView`.
    public func attach(to view: PDFView) {
        self.pdfView = view
        self.model.pageResolver.view = view
        view.pageOverlayViewProvider = self
        view.delegate = self
        self.installGestures(on: view)
        self.observe(view)
    }

    /// Lets go of everything. Called from `dismantleUIView`.
    public func detach() {
        self.scaleSettleTask?.cancel()
        self.scaleSettleTask = nil
        self.stopMotionTracking()
        let centre = NotificationCenter.default
        for token in self.observers {
            centre.removeObserver(token)
        }
        self.observers = []
        if let view = self.pdfView {
            view.pageOverlayViewProvider = nil
            view.delegate = nil
        }
        self.model.pageResolver.view = nil
        self.model.pageResolver.forgetOverlays()
        self.pdfView = nil
    }

    /// Brings the view into line with the model. Called from `updateUIView`,
    /// which SwiftUI runs often, so everything here is guarded on having
    /// actually changed.
    public func synchronise(_ view: PDFView) {
        guard let document = self.model.document, self.model.documentId != nil else { return }
        guard self.appliedDocumentId != self.model.documentId else { return }
        self.appliedDocumentId = self.model.documentId
        self.hasRestoredPosition = false

        view.document = document
        self.restoreReadingPosition(in: view)

        // The gesture layer installs on `CommentPageResolving.pageHostView`,
        // which only exists once the view does.
        self.model.capture?.attach()
        self.noteMotion()
    }

    // MARK: - Reading position

    private func restoreReadingPosition(in view: PDFView) {
        guard !self.hasRestoredPosition else { return }
        guard let document = view.document else { return }
        let index = self.model.currentPageIndex
        guard index > 0, index < document.pageCount, let page = document.page(at: index) else {
            self.hasRestoredPosition = true
            return
        }
        view.go(to: page)
        self.hasRestoredPosition = true

        // PDFKit sometimes has not laid the document out yet when the document
        // is set, and silently ignores the jump. One retry on the next turn of
        // the run loop is enough, costs nothing, and happens before anything is
        // on screen to flicker.
        Task { @MainActor [weak self] in
            guard let self, let view = self.pdfView, let document = view.document else { return }
            guard let currentPage = view.currentPage, let target = document.page(at: index) else { return }
            guard document.index(for: currentPage) != index else { return }
            view.go(to: target)
            self.noteMotion()
        }
    }

    // MARK: - Gestures

    /// The reader's own recognisers, three finger-only and one that a Pencil
    /// can reach off the page.
    ///
    /// The finger-only three exist as they do because none of them can see a
    /// Pencil touch, so none of them can delay, cancel or otherwise interfere
    /// with drawing. Pencil gestures on this same view belong to the comment
    /// unit, which configures its own not to interfere either
    /// (Comment/Gesture/CommentGestureController.swift).
    ///
    /// ─── WHY THERE IS A FOURTH ───────────────────────────────────────────────
    /// The chrome hides on scroll and comes back on tap, and every tap in this
    /// file was a *finger* tap. So with a Pencil in hand and nothing else, the
    /// toolbar could not be brought back at all: a Pencil tap on the page draws
    /// a dot, and the only remaining route to the library was the system's
    /// edge swipe, which under a Pencil draws a line across the page instead of
    /// revealing the sidebar. "I can't navigate with the sidebar entirely with
    /// the pen — sometimes it thinks I'm trying to write" is exactly that, and
    /// it is a hole in rule 5 of docs/01-design-principles.md: everything the
    /// Pencil starts, the Pencil must be able to finish.
    ///
    /// The fix is a Pencil tap that is only ever delivered where there is no
    /// page — the surround, and the gap between two pages. Nothing is drawn
    /// there, because a `PKCanvasView` only ever covers a page, so this cannot
    /// take a stroke away from anybody: it is a tap on the desk beside the
    /// paper. `shouldReceive` below is where that is decided, per touch.
    /// ─────────────────────────────────────────────────────────────────────────
    private func installGestures(on view: PDFView) {
        let fingerOnly = [NSNumber(value: UITouch.TouchType.direct.rawValue)]

        let tap = UITapGestureRecognizer(target: self, action: #selector(self.handleTap(_:)))
        tap.allowedTouchTypes = fingerOnly
        ReaderDocumentCoordinator.makeNonBlocking(tap, delegate: self)
        view.addGestureRecognizer(tap)

        let undo = UITapGestureRecognizer(target: self, action: #selector(self.handleUndoTap(_:)))
        undo.numberOfTouchesRequired = 2
        undo.allowedTouchTypes = fingerOnly
        ReaderDocumentCoordinator.makeNonBlocking(undo, delegate: self)
        view.addGestureRecognizer(undo)

        let pan = UIPanGestureRecognizer(target: self, action: #selector(self.handlePan(_:)))
        pan.allowedTouchTypes = fingerOnly
        ReaderDocumentCoordinator.makeNonBlocking(pan, delegate: self)
        view.addGestureRecognizer(pan)

        let margin = UITapGestureRecognizer(target: self, action: #selector(self.handleTap(_:)))
        margin.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.pencil.rawValue)]
        ReaderDocumentCoordinator.makeNonBlocking(margin, delegate: self)
        view.addGestureRecognizer(margin)
        self.offPageTap = margin
    }

    private static func makeNonBlocking(_ recogniser: UIGestureRecognizer, delegate: any UIGestureRecognizerDelegate) {
        recogniser.cancelsTouchesInView = false
        recogniser.delaysTouchesBegan = false
        recogniser.delaysTouchesEnded = false
        recogniser.delegate = delegate
    }

    @objc private func handleTap(_ recogniser: UITapGestureRecognizer) {
        guard recogniser.state == .ended else { return }
        self.model.toggleChrome()
    }

    @objc private func handlePan(_ recogniser: UIPanGestureRecognizer) {
        switch recogniser.state {
        case .began, .changed:
            self.model.noteScrollActivity()
            self.noteMotion()
        case .ended, .cancelled:
            self.noteMotion()
        default:
            break
        }
    }

    /// Two-finger tap: undo, the system's own way
    /// (docs/02-spec.md § S2). PencilKit registers each stroke with the undo
    /// manager it finds from the canvas, so the canvas's is the one to ask —
    /// the PDF view's may be a different manager holding annotation edits.
    @objc private func handleUndoTap(_ recogniser: UITapGestureRecognizer) {
        guard recogniser.state == .ended else { return }
        let resolver = self.model.pageResolver
        let candidates: [UIResponder?] = [
            resolver.inkOverlay(forPageIndex: self.model.currentPageIndex)?.canvasView,
            resolver.anyCanvas,
            self.pdfView
        ]
        for candidate in candidates {
            guard let manager = candidate?.undoManager, manager.canUndo else { continue }
            manager.undo()
            return
        }
    }

    // MARK: - Notifications

    private func observe(_ view: PDFView) {
        let centre = NotificationCenter.default
        self.observers.append(
            centre.addObserver(forName: .PDFViewPageChanged, object: view, queue: OperationQueue.main) { [weak self] _ in
                Task { @MainActor in
                    self?.handlePageChanged()
                }
            }
        )
        self.observers.append(
            centre.addObserver(forName: .PDFViewScaleChanged, object: view, queue: OperationQueue.main) { [weak self] _ in
                Task { @MainActor in
                    self?.handleScaleChanged()
                }
            }
        )
    }

    private func handlePageChanged() {
        guard let view = self.pdfView, let document = view.document, let page = view.currentPage else { return }
        let index = document.index(for: page)
        guard index != NSNotFound else { return }
        self.model.notePageChanged(index)
        self.noteMotion()
    }

    /// A pinch is in progress. The strokes are already in the right place — the
    /// canvas is scaled by an affine transform, not re-rendered
    /// (Annotate/Ink/InkTransform.swift) — so all that is owed here is one
    /// re-rasterisation once the pinch settles, which is the one thing
    /// docs/03-architecture.md § 2 says not to do mid-pinch.
    private func handleScaleChanged() {
        self.noteMotion()
        self.scaleSettleTask?.cancel()
        self.scaleSettleTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(0.25))
            } catch {
                return
            }
            self?.model.canvasPool?.pageScaleDidSettle()
        }
    }

    // MARK: - Motion

    /// Starts redrawing the marker layer every frame, for as long as the pages
    /// are moving.
    ///
    /// Only when there is something to redraw. A document with no comments never
    /// starts a display link at all, which is the common case and the one the
    /// 60fps budget is measured on.
    private func noteMotion() {
        guard self.model.capture?.comments.isEmpty == false else { return }
        self.motionDeadline = Date().addingTimeInterval(ReaderDocumentCoordinator.motionTail)
        guard self.displayLink == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(self.handleDisplayTick))
        link.add(to: RunLoop.main, forMode: .common)
        self.displayLink = link
    }

    @objc private func handleDisplayTick() {
        self.model.noteGeometryChanged()

        // Momentum outlives the finger. Rather than guess how long a flick
        // lasts, watch whether the page is still moving: any change extends the
        // tail, and the tick stops a beat after everything has settled.
        let rect = self.model.pageResolver.viewRect(forPageIndex: self.model.currentPageIndex)
        if rect != self.lastMotionRect {
            self.lastMotionRect = rect
            self.motionDeadline = Date().addingTimeInterval(ReaderDocumentCoordinator.motionTail)
        }
        guard Date() >= self.motionDeadline else { return }
        self.stopMotionTracking()
    }

    private func stopMotionTracking() {
        self.displayLink?.invalidate()
        self.displayLink = nil
        self.lastMotionRect = nil
    }
}

// MARK: - PDFPageOverlayViewProvider

extension ReaderDocumentCoordinator: @preconcurrency PDFPageOverlayViewProvider {

    /// One canvas per page, from the pool, sized in page space.
    ///
    /// The size handed over is the page's size at 1.0 zoom —
    /// `InkTransform.displaySize(cropBox:rotation:)` — and never the size PDFKit
    /// has laid the overlay out at. `PageCanvasController` derives the zoom
    /// itself, by comparing its own bounds with that page size, so this works
    /// whether PDFKit sizes the overlay in page space and scales an ancestor or
    /// sizes it in zoomed space directly. That is deliberate: the reader cannot
    /// tell which of the two PDFKit does without a device, and it does not have
    /// to.
    public func pdfView(_ view: PDFView, overlayViewFor page: PDFPage) -> UIView? {
        guard let pool = self.model.canvasPool else {
            ReaderLog.overlay.error("PDFKit asked for an overlay before the ink pool was open; that page has no canvas.")
            return nil
        }
        guard let document = view.document else { return nil }
        let index = document.index(for: page)
        guard index != NSNotFound else {
            ReaderLog.overlay.error("PDFKit asked for an overlay for a page the document does not own; that page has no canvas.")
            return nil
        }
        let size = InkTransform.displaySize(
            cropBox: page.bounds(for: .cropBox).size,
            rotation: page.rotation
        )
        let controller = pool.overlay(forPageIndex: index, pageSize: size)
        self.model.pageResolver.noteOverlay(controller, forPageIndex: index)
        return controller
    }

    /// The page has gone. The pool clears the canvas and flushes that page;
    /// anything unwritten stays in the coordinator, keyed by page, and comes
    /// straight back if the reader scrolls back before it has been written
    /// (Annotate/Ink/InkPersistenceCoordinator.swift).
    public func pdfView(_ pdfView: PDFView, willEndDisplayingOverlayView overlayView: UIView, for page: PDFPage) {
        guard let document = pdfView.document else { return }
        let index = document.index(for: page)
        guard index != NSNotFound else { return }
        self.model.pageResolver.forgetOverlay(forPageIndex: index)
        self.model.canvasPool?.willEndDisplaying(pageIndex: index)
    }
}

// MARK: - PDFViewDelegate

extension ReaderDocumentCoordinator: @preconcurrency PDFViewDelegate {

    /// Adds "Comment" to the standard text-selection menu
    /// (docs/02-spec.md § S2).
    ///
    /// The item is the reader's; everything it opens is the comment unit's. The
    /// suggested actions are kept and ours is appended, so Copy, Look Up,
    /// Translate and Share stay exactly where the system put them.
    public func pdfView(
        _ view: PDFView,
        editMenuFor selection: PDFSelection,
        suggestedActions: [UIMenuElement]
    ) -> UIMenu? {
        guard self.model.capture != nil, let quoted = selection.string, !quoted.isEmpty else {
            return UIMenu(children: suggestedActions)
        }
        let comment = UIAction(
            title: "Comment",
            image: UIImage(systemName: "bubble.and.pencil")
        ) { [weak self] _ in
            self?.beginComment(from: selection)
        }
        let children: [UIMenuElement] = suggestedActions + [comment]
        return UIMenu(children: children)
    }

    private func beginComment(from selection: PDFSelection) {
        guard let view = self.pdfView, let capture = self.model.capture else { return }
        guard let document = view.document, let page = selection.pages.first else { return }
        let index = document.index(for: page)
        guard index != NSNotFound else { return }

        let hit = ReaderTextHitFactory.hit(for: selection, on: page, pageIndex: index)
        let bounds = view.convert(selection.bounds(for: page), from: page)
        let point = CGPoint(x: bounds.midX, y: bounds.minY)
        capture.beginComment(from: hit, at: point)
        self.noteMotion()
    }
}

// MARK: - UIGestureRecognizerDelegate

extension ReaderDocumentCoordinator: UIGestureRecognizerDelegate {

    /// The reader's recognisers never take a touch away from anything.
    ///
    /// PDFKit owns scrolling and selection, PencilKit owns drawing, and the
    /// comment unit owns the Pencil hold. All of them keep their touches; these
    /// three only ever watch.
    public func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
    ) -> Bool {
        true
    }

    /// The Pencil tap is delivered only where there is no page under the point.
    ///
    /// `page(for:nearest:)` with `nearest: false` answers exactly the question
    /// worth asking — "is there paper here?" — and answers nil in the surround
    /// and in the gap between two pages, which is where this gesture lives. A
    /// Pencil touch anywhere on a page is never seen by this recogniser at all,
    /// so the canvas keeps every touch it would have had.
    ///
    /// The finger-only three are unconditional; they were installed before this
    /// one and nothing about them has changed.
    public func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldReceive touch: UITouch
    ) -> Bool {
        guard gestureRecognizer === self.offPageTap else { return true }
        guard let view = self.pdfView else { return false }
        return view.page(for: touch.location(in: view), nearest: false) == nil
    }
}
