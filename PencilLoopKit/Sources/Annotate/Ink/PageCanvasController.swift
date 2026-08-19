//
//  PageCanvasController.swift
//  Annotate · Ink
//
//  One `PKCanvasView` per visible page, sized to that page, recycled with the
//  page views. Never one canvas over the whole scroll view — that breaks at
//  length and drifts on zoom (docs/03-architecture.md § 2, and CLAUDE.md's
//  "known hard parts", which calls this the long pole).
//
//  It is a `UIView` rather than a controller object because PDFKit's
//  `PDFPageOverlayViewProvider` hands back views, and because the container it
//  provides is load-bearing: PDFKit resizes the overlay as the reader zooms, and
//  putting a plain view in the way means those resizes never touch the canvas's
//  own bounds. The canvas therefore stays in page coordinates forever, and zoom
//  is expressed as an affine transform on it — a GPU operation, not a re-render.
//

import CoreGraphics
import Foundation
import PencilKit
import UIKit
import Core

/// The ink overlay for exactly one page.
///
/// **Coordinate space — the cross-module part.** The canvas's bounds are the
/// page's displayed size at 1.0 zoom: origin top-left, the crop box with the
/// page's `/Rotate` applied. Every `PKDrawing` this type persists is in that
/// space. Export composites ink over page content and has to assume the same
/// thing (Core/Contracts/Protocols.swift, `InkCropping`).
///
/// **Isolation.** Main actor throughout, because `PKCanvasView` is. The only
/// thing crossing to another actor is `InkChange`, and it crosses through
/// `InkPersistenceCoordinator.record(_:)`, which is synchronous and does not
/// await (STYLE.md § 6).
///
/// **On failure:** every path degrades to an empty canvas that still accepts
/// strokes. Ink bytes that will not unarchive are logged and dropped rather than
/// thrown; a controller with no binding accepts strokes and discards them, which
/// only happens if a caller draws it before `bind(to:pageSize:)`.
@MainActor
public final class PageCanvasController: UIView, PKCanvasViewDelegate {

    /// The canvas itself. Exposed so the reader can hand it to `PKToolPicker`
    /// and so tests can inspect it; do not resize it or set its `drawing`
    /// from outside, or the invariants above stop holding.
    public let canvasView: PKCanvasView

    /// The page this canvas is currently showing, or nil between a
    /// `prepareForReuse()` and the next `bind(to:pageSize:)`.
    public private(set) var binding: InkPageBinding?

    /// The page's size at 1.0 zoom, in points.
    public private(set) var pageSize: CGSize = .zero

    /// Ceiling on the rasterisation scale applied when a zoom settles. Three is
    /// enough to look sharp at the zoom levels a reader actually uses and cheap
    /// enough not to matter.
    public var maximumRenderScale: CGFloat = 3

    private let coordinator: InkPersistenceCoordinator

    /// Bumped on every bind and every release. An asynchronous drawing load
    /// that comes back against an old generation is dropped — that is the
    /// difference between recycling correctly and painting one page's notes onto
    /// another, which is the bug this whole class is arranged around.
    private var generation: UInt64 = 0

    /// True while we are pushing stored ink into the canvas, so the delegate
    /// callback that provokes does not get recorded as a user edit and written
    /// straight back.
    private var isApplyingStoredDrawing = false

    /// Guards `layoutCanvas()` against re-entering itself. Setting `bounds` and
    /// `transform` during rapid scrolling can provoke another layout pass before
    /// the first has finished (docs/03-architecture.md § 2, "canvas
    /// re-entrancy during rapid scrolling").
    private var isLayingOutCanvas = false

    private var appliedScale: CGFloat = 0
    private var appliedRenderScale: CGFloat = 0
    private var appliedDrawingData: Data?

    /// - Parameters:
    ///   - coordinator: where changes go. Shared by every canvas in the reader.
    ///   - defaults: the tool to start with (`AppSettings.ink`).
    public init(coordinator: InkPersistenceCoordinator, defaults: InkDefaults = .standard) {
        self.coordinator = coordinator
        self.canvasView = PKCanvasView(frame: .zero)
        super.init(frame: .zero)
        self.configure(defaults: defaults)
    }

    /// Not supported: these are built in code by `PageCanvasPool`, never
    /// unarchived from a nib. Returns nil rather than trapping (STYLE.md § 4 —
    /// `fatalError` is confined to one file in Core).
    public required init?(coder: NSCoder) {
        return nil
    }

    // MARK: - Binding

    /// Points this canvas at a page.
    ///
    /// Safe to call on a canvas that is already showing something else: the old
    /// page's ink is cleared before the new page's arrives, so no frame ever
    /// shows one page's notes over another's, and the old page's unwritten
    /// changes are flushed. They could not be lost in any case — they live in
    /// the coordinator, keyed by page, not here.
    ///
    /// - Parameters:
    ///   - newBinding: the page to show.
    ///   - newPageSize: its size at 1.0 zoom. Use
    ///     `InkTransform.displaySize(cropBox:rotation:)`.
    ///   - drawingHint: bytes the caller already has, from
    ///     `DocumentDetail.pages`. Applied synchronously so ink is on screen in
    ///     the same frame as the page. The coordinator is consulted regardless,
    ///     and wins if it disagrees.
    public func bind(to newBinding: InkPageBinding, pageSize newPageSize: CGSize, drawingHint: Data? = nil) {
        // Re-binding to the page already on screen is geometry only. PDFKit
        // calls the overlay provider again for pages it is merely re-laying
        // out, and reloading the drawing there would race the strokes the
        // reader is in the middle of making.
        guard self.binding != newBinding else {
            self.updateGeometry(newPageSize)
            return
        }

        self.release()
        self.generation &+= 1
        self.binding = newBinding
        self.updateGeometry(newPageSize)

        // A nil hint says "the caller has nothing"; it does not say "this page
        // is empty", so it must not clear a canvas that is already correct.
        if let drawingHint {
            self.applyStoredDrawing(drawingHint)
        }

        let generation = self.generation
        let coordinator = self.coordinator
        Task { [weak self] in
            let latest = await coordinator.drawingData(for: newBinding)
            guard let self, self.generation == generation else { return }
            self.applyStoredDrawing(latest)
        }
    }

    /// Detaches from the current page, ready to be handed to another one.
    ///
    /// Call from `pdfView(_:willEndDisplayingOverlayView:for:)`. Clearing the
    /// canvas here rather than at the next bind is deliberate: a recycled view
    /// can be re-inserted before it is re-bound, and stale ink flashing on the
    /// wrong page is the recycling bug everyone writes at least once.
    public func prepareForReuse() {
        self.release()
    }

    private func updateGeometry(_ newPageSize: CGSize) {
        guard self.pageSize != newPageSize else { return }
        self.pageSize = newPageSize
        self.appliedScale = 0
        self.setNeedsLayout()
    }

    private func release() {
        guard let previous = self.binding else { return }
        self.binding = nil
        self.generation &+= 1
        self.setDrawingWithoutRecording(PKDrawing())
        self.appliedDrawingData = nil
        let coordinator = self.coordinator
        Task { await coordinator.flush(previous) }
    }

    // MARK: - The comment gesture's stroke

    /// The drawing on this canvas right now.
    ///
    /// Cheap: `PKDrawing` is a value type and taking a copy is a retain, not a
    /// deep copy. Read it before a press that might turn into a comment, so
    /// there is something to restore if PencilKit commits the dot anyway.
    public var currentDrawing: PKDrawing {
        self.canvasView.drawing
    }

    /// Cancels the stroke PencilKit is building right now, if there is one.
    ///
    /// "Let the dot be drawn, and take it back" (docs/02-spec.md § S2). A
    /// stationary Pencil press has already started a stroke by the time the
    /// comment gesture is recognised; disabling the canvas's own drawing
    /// recogniser mid-gesture cancels it, and PencilKit discards what it was
    /// building. Re-enabling in the same breath means the very next Pencil
    /// touch draws normally.
    ///
    /// It is here rather than in the caller because the recogniser it toggles
    /// belongs to `canvasView`, and reaching through a canvas from another
    /// module to poke one of its gesture recognisers is the kind of thing that
    /// stops working silently when PencilKit changes. This is the supported
    /// way to ask for it.
    ///
    /// **On failure:** nothing. There may be no stroke in flight, which is the
    /// common case; the worst outcome of calling it needlessly is nothing at
    /// all.
    public func cancelStrokeInFlight() {
        let drawingGesture = self.canvasView.drawingGestureRecognizer
        drawingGesture.isEnabled = false
        drawingGesture.isEnabled = true
    }

    /// Replaces what is on the canvas, as an ordinary edit.
    ///
    /// Recorded and persisted like anything the reader drew, which is the point:
    /// restoring the pre-press drawing after a dot was committed has to reach
    /// the store, or the dot comes back the next time the page is bound.
    public func replaceDrawing(_ drawing: PKDrawing) {
        self.canvasView.drawing = drawing
    }

    // MARK: - Tools

    /// Applies stored ink defaults to this canvas.
    public func applyDefaults(_ defaults: InkDefaults) {
        self.canvasView.tool = InkToolFactory.tool(for: defaults)
    }

    /// Sets a tool directly, for callers driving `PKToolPicker` themselves.
    public func applyTool(_ tool: PKTool) {
        self.canvasView.tool = tool
    }

    // MARK: - Layout

    public override func layoutSubviews() {
        super.layoutSubviews()
        self.layoutCanvas()
    }

    /// Call when a pinch ends, so PencilKit re-rasterises the page's strokes at
    /// the zoom the reader has settled on.
    ///
    /// Optional. Skip it and the ink is still in exactly the right place at
    /// exactly the right size; it just softens as you zoom past about 2x,
    /// because a transformed layer is drawn at its pre-transform resolution.
    /// It is a separate call rather than part of layout precisely because it
    /// does provoke a re-render, and doing that mid-pinch is the one thing
    /// docs/03-architecture.md § 2 says not to do.
    public func pageScaleDidSettle() {
        guard self.appliedScale > 0 else { return }
        let target = InkTransform.renderScale(
            for: self.appliedScale,
            displayScale: self.traitCollection.displayScale,
            maximum: self.maximumRenderScale
        )
        guard InkTransform.hasChanged(from: self.appliedRenderScale, to: target) else { return }
        self.appliedRenderScale = target
        self.canvasView.contentScaleFactor = target
    }

    private func layoutCanvas() {
        guard !self.isLayingOutCanvas else { return }
        self.isLayingOutCanvas = true
        defer { self.isLayingOutCanvas = false }

        let displayed = self.bounds.size
        guard self.pageSize.width > 0, self.pageSize.height > 0 else { return }
        guard displayed.width > 0, displayed.height > 0 else { return }

        if self.canvasView.bounds.size != self.pageSize {
            self.canvasView.bounds = CGRect(origin: .zero, size: self.pageSize)
            self.canvasView.contentSize = self.pageSize
        }

        let scale = InkTransform.scale(pageSize: self.pageSize, displayedSize: displayed)
        if InkTransform.hasChanged(from: self.appliedScale, to: scale) {
            self.canvasView.transform = InkTransform.transform(scale: scale)
            self.appliedScale = scale
        }

        self.canvasView.center = InkTransform.centre(of: self.bounds)
    }

    // MARK: - PKCanvasViewDelegate

    /// The touch path's only exit. Everything here has to be cheap: capture the
    /// drawing, which is a retain rather than a copy, and hand it over. No
    /// archiving, no store, no await (docs/01-design-principles.md § 10).
    public func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
        guard !self.isApplyingStoredDrawing else { return }
        guard let binding = self.binding else {
            InkLog.canvas.debug("A stroke landed on an unbound canvas and was not persisted.")
            return
        }
        // Any drawing load still in flight is now older than what is on screen.
        // Bumping the generation makes it drop itself rather than paint over a
        // stroke the user has just made.
        self.generation &+= 1
        self.appliedDrawingData = nil
        self.coordinator.record(InkChange(binding: binding, drawing: canvasView.drawing))
    }

    // MARK: - Support

    private func configure(defaults: InkDefaults) {
        self.backgroundColor = UIColor.clear
        self.isOpaque = false
        self.clipsToBounds = true

        // One mode, forever: finger scrolls, Pencil draws, and the user never
        // switches (CLAUDE.md non-negotiable 4, docs/02-spec.md § S2).
        self.canvasView.drawingPolicy = .pencilOnly

        self.canvasView.backgroundColor = UIColor.clear
        self.canvasView.isOpaque = false

        // The canvas is an overlay, not a scroll view. PDFKit owns scrolling and
        // zooming; leaving these on gives two scroll views fighting over the
        // same finger.
        self.canvasView.isScrollEnabled = false
        self.canvasView.bounces = false
        self.canvasView.alwaysBounceVertical = false
        self.canvasView.alwaysBounceHorizontal = false
        self.canvasView.showsVerticalScrollIndicator = false
        self.canvasView.showsHorizontalScrollIndicator = false
        self.canvasView.minimumZoomScale = 1
        self.canvasView.maximumZoomScale = 1
        self.canvasView.contentInsetAdjustmentBehavior = .never

        // PencilKit lightens dark ink in dark mode. Over a page we render and
        // tint rather than invert, that turns graphite into white-on-white
        // (docs/01-design-principles.md § 9). Ink is content; it does not
        // follow the appearance.
        self.canvasView.overrideUserInterfaceStyle = .light

        self.canvasView.tool = InkToolFactory.tool(for: defaults)
        self.canvasView.delegate = self
        self.addSubview(self.canvasView)
    }

    private func setDrawingWithoutRecording(_ drawing: PKDrawing) {
        self.isApplyingStoredDrawing = true
        self.canvasView.drawing = drawing
        self.isApplyingStoredDrawing = false
    }

    private func applyStoredDrawing(_ data: Data?) {
        guard data != self.appliedDrawingData else { return }
        guard let data, !data.isEmpty else {
            self.setDrawingWithoutRecording(PKDrawing())
            self.appliedDrawingData = nil
            return
        }
        guard let drawing = try? PKDrawing(data: data) else {
            InkLog.canvas.error("Stored ink for a page could not be unarchived; the page renders empty.")
            self.setDrawingWithoutRecording(PKDrawing())
            self.appliedDrawingData = nil
            return
        }
        self.setDrawingWithoutRecording(drawing)
        self.appliedDrawingData = data
    }
}
