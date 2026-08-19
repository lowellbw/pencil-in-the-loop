//
//  ReaderPageResolver.swift
//  AppUI · Reader
//
//  The reader's half of the seam with comment capture
//  (Comment/Seam/CommentPageResolving.swift). Six coordinate questions, one
//  small object, and the only place in the reader that the comment unit can
//  see.
//
//  ─── ONE DECISION WORTH KNOWING ABOUT ────────────────────────────────────────
//  `pageHostView` is the `PDFView` itself, not its internal document view.
//
//  The protocol says "normally the PDFView's document view", and that would
//  work for the gestures. It does not work for anything measured: the document
//  view is the scrolling content, so its coordinate space slides under the
//  reader's finger, and a popover anchored in it points somewhere else a frame
//  later. The `PDFView` does not move, PDFKit gives no supported access to the
//  view inside it, and a gesture recogniser installed on an ancestor still
//  receives every touch delivered to its subtree — so the canvases keep their
//  touches, the recognisers still see them, and every rect below is a rect on
//  screen. Everything the seam asks for is in this one space.
//  ─────────────────────────────────────────────────────────────────────────────
//

import CoreGraphics
import Foundation
import PDFKit
import PencilKit
import UIKit
import Annotate
import Core

/// Answers the comment unit's coordinate questions about the open document.
///
/// Owned by `ReaderModel`, so it outlives every view update; held weakly by
/// `CommentGestureController`, which is why it is a class.
///
/// **On failure:** every member returns nil rather than guessing. No PDF view,
/// no document, a page that is not laid out, a page whose canvas has been
/// recycled — all of them are ordinary states while a reader scrolls, and none
/// of them is an error the user should ever hear about.
public final class ReaderPageResolver: CommentPageResolving {

    /// The open PDF view. Set by the reader's coordinator when the view is
    /// made, cleared when it is dismantled. Weak: the view hierarchy owns it.
    public weak var view: PDFView?

    /// The canvases currently on screen, by page index — the same set
    /// `PageCanvasPool` considers active. Kept here rather than asked of the
    /// pool because the pool hands out controllers and does not hand them back.
    private var overlays: [Int: PageCanvasController] = [:]

    public init() {}

    /// Records the canvas now overlaying a page. Called from the overlay
    /// provider, in the same breath as `PageCanvasPool.overlay(forPageIndex:pageSize:)`.
    public func noteOverlay(_ controller: PageCanvasController, forPageIndex pageIndex: Int) {
        // A recycled controller can be handed to a new page before PDFKit says
        // the old one has gone. Leaving both entries in place would answer
        // `inkOverlay(forPageIndex:)` with a controller that is showing a
        // different page, and the comment unit would cancel a stroke on the
        // wrong one.
        let stale = self.overlays
            .filter { $0.value === controller && $0.key != pageIndex }
            .map(\.key)
        for index in stale {
            self.overlays.removeValue(forKey: index)
        }
        self.overlays[pageIndex] = controller
    }

    /// Forgets a page's canvas. Called from
    /// `pdfView(_:willEndDisplayingOverlayView:for:)`, so this map and the
    /// pool's own cannot drift apart.
    public func forgetOverlay(forPageIndex pageIndex: Int) {
        self.overlays.removeValue(forKey: pageIndex)
    }

    /// Drops every canvas. For closing a document.
    public func forgetOverlays() {
        self.overlays.removeAll()
    }

    /// Any canvas currently on screen, for the tool picker to attach to when
    /// the PDF view will not become first responder.
    public var anyCanvas: PKCanvasView? {
        self.overlays.values.first?.canvasView
    }

    // MARK: - CommentPageResolving

    public var pageHostView: UIView? {
        self.view
    }

    public func pageIndex(at point: CGPoint) -> Int? {
        guard let view = self.view, let page = view.page(for: point, nearest: false) else { return nil }
        return self.index(of: page, in: view)
    }

    public func textHit(at point: CGPoint) -> CommentTextHit? {
        guard let view = self.view, let page = view.page(for: point, nearest: false) else { return nil }
        guard let pageIndex = self.index(of: page, in: view) else { return nil }
        let pagePoint = view.convert(point, to: page)
        return ReaderTextHitFactory.hit(atPagePoint: pagePoint, on: page, pageIndex: pageIndex)
    }

    public func inkOverlay(forPageIndex pageIndex: Int) -> PageCanvasController? {
        self.overlays[pageIndex]
    }

    public func viewRect(forNormalisedRect rect: NormalisedRect, pageIndex: Int) -> CGRect? {
        guard let view = self.view, let page = self.page(at: pageIndex, in: view) else { return nil }
        let pdfRect = ReaderPageGeometry.pdfRect(
            normalised: rect,
            cropBox: page.bounds(for: .cropBox),
            rotation: page.rotation
        )
        guard pdfRect.width > 0, pdfRect.height > 0 else { return nil }
        return view.convert(pdfRect, from: page)
    }

    public func viewRect(forPageIndex pageIndex: Int) -> CGRect? {
        guard let view = self.view, let page = self.page(at: pageIndex, in: view) else { return nil }
        let bounds = page.bounds(for: .cropBox)
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        return view.convert(bounds, from: page)
    }

    // MARK: - Support

    /// The pages with a rect on screen right now, for the marker layer.
    ///
    /// `PDFView.visiblePages` is the cheap answer and it is the one the marker
    /// layer wants: markers for pages nobody can see are not drawn
    /// (Comment/Seam/CommentPageResolving.swift).
    public func visiblePageIndices() -> [Int] {
        guard let view = self.view else { return [] }
        return view.visiblePages.compactMap { self.index(of: $0, in: view) }
    }

    private func page(at pageIndex: Int, in view: PDFView) -> PDFPage? {
        guard let document = view.document, pageIndex >= 0, pageIndex < document.pageCount else { return nil }
        return document.page(at: pageIndex)
    }

    /// A page's index, or nil when the document does not own it — which is what
    /// PDFKit reports as `NSNotFound` rather than as a failure.
    private func index(of page: PDFPage, in view: PDFView) -> Int? {
        guard let document = view.document else { return nil }
        let index = document.index(for: page)
        guard index != NSNotFound, index >= 0 else { return nil }
        return index
    }
}
