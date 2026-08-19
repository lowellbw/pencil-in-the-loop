//
//  CommentPageResolving.swift
//  AppUI · Comment · Seam
//
//  ─── THE SEAM WITH THE READER (U8) ───────────────────────────────────────────
//  Comment capture needs four things from whoever owns the `PDFView`, and
//  nothing else. They are all coordinate questions: this unit knows what a
//  comment is, the Reader knows where the pages are, and neither needs the
//  other's internals.
//
//  This protocol is AppUI-internal by design. It is not a Core contract because
//  it never crosses a module boundary — Reader and Comment are both AppUI — and
//  it takes `UIView`, `CGPoint` and `PageCanvasController`, none of which Core
//  is allowed to name (STYLE.md § 7).
//
//  The Reader adopts it on a small adapter object rather than on its main view,
//  so that these five members do not have to be unique names in a type that
//  already has fifty.
//  ─────────────────────────────────────────────────────────────────────────────
//

import Foundation
import PencilKit
import UIKit
import Annotate
import Core

/// What the Reader must answer for comment capture to work
/// (docs/02-spec.md § S2, § S3).
///
/// **One coordinate space.** Every point and rect below is in the coordinate
/// space of `pageHostView`. That is also the view the gesture recogniser is
/// installed on and the view the popover's attachment anchor is measured in, so
/// there is exactly one conversion in the whole feature and it lives here.
///
/// **On failure:** every member may return nil, and nil is never an error. A
/// point outside any page, a page whose canvas has been recycled, an anchor
/// scrolled off screen — each of those is an ordinary state, and the caller
/// degrades: no text hit means a rect-only anchor, no canvas means no stroke to
/// cancel, no rect means the marker is not drawn this frame.
public protocol CommentPageResolving: AnyObject {

    /// The view that receives Pencil touches and defines the coordinate space
    /// for everything else here — normally the `PDFView`'s document view.
    ///
    /// Read every time it is needed rather than cached: `PDFView` replaces its
    /// document view when the document changes. Nil while no document is open,
    /// which is a state the gesture controller handles by installing nothing.
    var pageHostView: UIView? { get }

    /// Which page a point is on, and nothing else.
    ///
    /// Separate from `textHit(at:)` because it is asked much earlier and much
    /// more often: every stationary Pencil press asks it after
    /// `CommentGestureTuning.armingDuration` so that the page's canvas can be
    /// remembered before its dot stroke could have been committed. Keep it to a
    /// hit test — no text extraction, no selection building — because it runs
    /// while a Pencil is on the glass.
    ///
    /// - Returns: nil when the point is not over a page.
    func pageIndex(at point: CGPoint) -> Int?

    /// The text nearest `point`, unexpanded.
    ///
    /// - Parameter point: in `pageHostView` coordinates.
    /// - Returns: nil when the point is outside every page or the page has no
    ///   text layer. Return `CommentTextHit.pageOnly(pageIndex:normalisedRect:)`
    ///   — not nil — when the point *is* on a page but there is no text there:
    ///   the difference is a comment anchored to a figure versus no comment at
    ///   all.
    func textHit(at point: CGPoint) -> CommentTextHit?

    /// The ink overlay currently on a page, so that the dot stroke a stationary
    /// Pencil press has already drawn can be taken back (docs/02-spec.md § S2,
    /// "The long-press is a stroke until it isn't").
    ///
    /// The controller rather than its `PKCanvasView`: cancelling a stroke in
    /// flight is `PageCanvasController.cancelStrokeInFlight()`, and going
    /// through the controller is what stops this unit reaching into PencilKit's
    /// own gesture recognisers from the outside.
    ///
    /// - Returns: nil when that page is not on screen or has no canvas. Nil
    ///   costs nothing: there was no stroke to cancel.
    func inkOverlay(forPageIndex pageIndex: Int) -> PageCanvasController?

    /// Where a stored anchor's rect currently sits on screen, for placing its
    /// margin marker.
    ///
    /// - Returns: nil when that page is not laid out right now. Markers for
    ///   pages off screen are simply not drawn.
    func viewRect(forNormalisedRect rect: NormalisedRect, pageIndex: Int) -> CGRect?

    /// The whole page's frame on screen, which is what the marker layout
    /// measures its margin against.
    ///
    /// - Returns: nil when that page is not laid out right now.
    func viewRect(forPageIndex pageIndex: Int) -> CGRect?
}
