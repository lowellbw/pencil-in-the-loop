//
//  CommentMarkersOverlay.swift
//  AppUI · Comment · Markers
//
//  One view for every visible page's markers, so the Reader's side of this is a
//  single line.
//

import SwiftUI
import CoreGraphics

/// Every visible page's comment markers, laid over the reader.
///
/// Apply it over the same view the model's `CommentPageResolving` names as
/// `pageHostView` — the coordinate space the resolver answers in.
///
/// **How it keeps up with a scrolling document.** It does not observe anything.
/// The Reader bumps `geometryVersion` when the pages move, that changes this
/// view's stored properties, SwiftUI re-runs the body, and the body asks the
/// resolver for each page's rect again. One integer in, one layout pass out —
/// no display link of its own, no observation of `PDFView`, and nothing at all
/// happening while the document is still.
///
/// **Never fails.** A page the resolver cannot place is a page whose markers are
/// not drawn this frame, which is what should happen to a page that is not on
/// screen.
public struct CommentMarkersOverlay: View {

    /// The document's capture model.
    public var model: CommentCaptureModel

    /// The Reader's adapter, asked for each page's frame.
    public var resolver: any CommentPageResolving

    /// Which pages to draw markers for — the visible ones, plus whatever
    /// margin of prefetch the Reader keeps.
    public var pageIndices: [Int]

    /// Bumped by the Reader whenever the pages have moved. Its value is never
    /// read; changing it is the whole point.
    public var geometryVersion: Int

    /// The layout dials.
    public var metrics: CommentMarkerLayout.Metrics

    public init(
        model: CommentCaptureModel,
        resolver: any CommentPageResolving,
        pageIndices: [Int],
        geometryVersion: Int,
        metrics: CommentMarkerLayout.Metrics = .standard
    ) {
        self.model = model
        self.resolver = resolver
        self.pageIndices = pageIndices
        self.geometryVersion = geometryVersion
        self.metrics = metrics
    }

    public var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(pageIndices, id: \.self) { pageIndex in
                if let pageRect = resolver.viewRect(forPageIndex: pageIndex) {
                    CommentMarkerLayer(
                        model: model,
                        pageIndex: pageIndex,
                        pageRect: pageRect,
                        metrics: metrics
                    )
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // The markers are the only thing here that should take a touch. The
        // pages underneath keep every other one — scrolling, inking, selection.
        .allowsHitTesting(true)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Comment markers")
    }
}
