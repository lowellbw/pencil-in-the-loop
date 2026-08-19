//
//  PageCanvasPool.swift
//  Annotate · Ink
//
//  The thing PDFKit's `PDFPageOverlayViewProvider` talks to. It hands out one
//  `PageCanvasController` per visible page and takes them back when the page
//  scrolls away, which is the recycling the architecture calls for
//  (docs/03-architecture.md § 2) and the path where the real bugs live.
//
//  Deliberately free of PDFKit: `Annotate` may not import it (STYLE.md § 7), and
//  it does not need to. Wave 2's reader converts a `PDFPage` into a page index
//  and a size and calls in here.
//

import CoreGraphics
import Foundation
import PencilKit
import UIKit
import Core

/// Creates, recycles and retires the reader's ink overlays.
///
/// Wire it into `PDFPageOverlayViewProvider` like this:
///
/// ```swift
/// func pdfView(_ view: PDFView, overlayViewFor page: PDFPage) -> UIView? {
///     guard let index = view.document?.index(for: page) else { return nil }
///     let box = page.bounds(for: .cropBox).size
///     let size = InkTransform.displaySize(cropBox: box, rotation: page.rotation)
///     return pool.overlay(forPageIndex: index, pageSize: size)
/// }
///
/// func pdfView(_ view: PDFView, willEndDisplayingOverlayView overlay: UIView, for page: PDFPage) {
///     guard let index = view.document?.index(for: page) else { return }
///     pool.willEndDisplaying(pageIndex: index)
/// }
/// ```
///
/// **On failure:** asking for an overlay before `open(documentId:pages:)` gives
/// you a working canvas that is not bound to anything — it draws, and it
/// discards. That is logged, and it is a programmer error rather than a
/// user-visible one; returning nil instead would leave the reader with no ink
/// layer at all and no explanation.
@MainActor
public final class PageCanvasPool {

    /// Where changes go, and the only thing that knows what the latest ink for a
    /// page is. Exposed because the reader needs to `await` its `close()`.
    public let coordinator: InkPersistenceCoordinator

    /// How many idle canvases to keep. PencilKit canvases are not cheap to
    /// build, and a continuous-scroll reader typically shows two or three pages
    /// at once, so a handful covers scrolling without holding memory.
    public var spareLimit = 4

    private let toolPicker: InkToolPickerController?
    private var defaults: InkDefaults
    private var active: [Int: PageCanvasController] = [:]
    private var spare: [PageCanvasController] = []
    private var documentId: UUID?
    private var hints: [Int: Data] = [:]
    private var lifecycle: InkLifecycleObserver?

    /// - Parameters:
    ///   - coordinator: shared with every canvas this pool makes.
    ///   - toolPicker: the reader's picker, if it has one. Canvases are
    ///     registered with it as they are created.
    ///   - defaults: the tool new canvases start with (`AppSettings.ink`).
    public init(
        coordinator: InkPersistenceCoordinator,
        toolPicker: InkToolPickerController? = nil,
        defaults: InkDefaults = .standard
    ) {
        self.coordinator = coordinator
        self.toolPicker = toolPicker
        self.defaults = defaults
        self.lifecycle = InkLifecycleObserver {
            await coordinator.flushAll()
        }
    }

    // MARK: - Documents

    /// Opens a document. Call before the first overlay is asked for.
    ///
    /// Seeds both the coordinator's cache and the pool's own synchronous copy
    /// from `DocumentDetail.pages`, so a page scrolling into view gets its ink
    /// in the same frame rather than one actor hop later.
    public func open(documentId newDocumentId: UUID, pages: [PageSnapshot]) async {
        if let current = self.documentId, current != newDocumentId {
            await self.close()
        }
        self.documentId = newDocumentId
        self.hints = [:]
        for page in pages where page.drawingData != nil {
            self.hints[page.pageIndex] = page.drawingData
        }
        await self.coordinator.preload(pages, documentId: newDocumentId)
    }

    /// Retires every canvas and writes everything outstanding. Call when the
    /// reader closes.
    public func close() async {
        for controller in self.active.values {
            controller.prepareForReuse()
        }
        self.active.removeAll()
        self.spare.removeAll()
        self.hints = [:]
        self.documentId = nil
        await self.coordinator.close()
    }

    /// Writes everything outstanding without retiring anything. For scene-phase
    /// changes and for anywhere else the app wants to be sure.
    public func flush() async {
        await self.coordinator.flushAll()
    }

    // MARK: - Overlays

    /// The overlay for a page, created or recycled.
    ///
    /// - Parameters:
    ///   - pageIndex: zero-based, matching `PageSnapshot.pageIndex`.
    ///   - pageSize: the page's displayed size at 1.0 zoom. Build it with
    ///     `InkTransform.displaySize(cropBox:rotation:)` so a rotated page gets
    ///     the dimensions the reader actually shows.
    public func overlay(forPageIndex pageIndex: Int, pageSize: CGSize) -> PageCanvasController {
        let controller = self.active[pageIndex] ?? self.dequeue()
        self.active[pageIndex] = controller

        guard let documentId = self.documentId else {
            InkLog.canvas.error("An ink overlay was requested before a document was opened; strokes on it will not be saved.")
            return controller
        }

        // The hint is consumed rather than kept. It is only ever the state at
        // the moment the document opened, so re-using it on a second appearance
        // would paint pre-edit ink over post-edit ink for a frame. After the
        // first use, the coordinator answers — one actor hop, always current.
        let hint = self.hints.removeValue(forKey: pageIndex)
        let binding = InkPageBinding(documentId: documentId, pageIndex: pageIndex)
        controller.bind(to: binding, pageSize: pageSize, drawingHint: hint)
        return controller
    }

    /// Takes an overlay back. Call from
    /// `pdfView(_:willEndDisplayingOverlayView:for:)`.
    ///
    /// The canvas is cleared and its page flushed; the page's unwritten strokes
    /// are unaffected either way, because they live in the coordinator keyed by
    /// page, not in the view.
    public func willEndDisplaying(pageIndex: Int) {
        guard let controller = self.active.removeValue(forKey: pageIndex) else { return }
        controller.prepareForReuse()
        guard self.spare.count < self.spareLimit else {
            self.retire(controller)
            return
        }
        self.spare.append(controller)
    }

    /// Whether a page currently has a live overlay. For the reader's own
    /// bookkeeping and for tests.
    public func isDisplaying(pageIndex: Int) -> Bool {
        self.active[pageIndex] != nil
    }

    // MARK: - Zoom and tools

    /// Forward from the reader's `PDFViewScaleChanged` handling once a pinch
    /// settles, so every visible page re-rasterises its strokes at the new zoom.
    /// See `PageCanvasController.pageScaleDidSettle()`.
    public func pageScaleDidSettle() {
        for controller in self.active.values {
            controller.pageScaleDidSettle()
        }
    }

    /// Applies stored ink defaults to every canvas, live or spare.
    public func applyDefaults(_ newDefaults: InkDefaults) {
        self.defaults = newDefaults
        for controller in self.active.values {
            controller.applyDefaults(newDefaults)
        }
        for controller in self.spare {
            controller.applyDefaults(newDefaults)
        }
    }

    // MARK: - Support

    private func dequeue() -> PageCanvasController {
        if let recycled = self.spare.popLast() {
            return recycled
        }
        let controller = PageCanvasController(coordinator: self.coordinator, defaults: self.defaults)
        self.toolPicker?.attach(controller.canvasView)
        return controller
    }

    private func retire(_ controller: PageCanvasController) {
        self.toolPicker?.detach(controller.canvasView)
        controller.removeFromSuperview()
    }
}
