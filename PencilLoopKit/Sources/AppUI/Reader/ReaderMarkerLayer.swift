//
//  ReaderMarkerLayer.swift
//  AppUI · Reader
//
//  The reader's one line of marker code: which pages are on screen, and when
//  they last moved. Everything else about markers — where each dot goes down the
//  margin, what a cluster is, the tap target, the popover a tap opens — belongs
//  to the comment unit and is reached through `CommentMarkersOverlay`.
//
//  ─── WHY THIS FILE STILL EXISTS ──────────────────────────────────────────────
//  It used to walk the visible pages itself and build one `CommentMarkerLayer`
//  per page, which is exactly what `CommentMarkersOverlay` does — the same loop,
//  written twice, from the same two inputs. That copy is gone.
//
//  What is left is the one thing that cannot move into the comment unit: reading
//  `ReaderModel.geometryRevision`. Reading it *here*, in a view whose whole body
//  is the marker layer, is what subscribes this view — and only this view — to
//  scrolling. Passing it in from `ReaderView.body` instead would re-evaluate the
//  toolbar, the tint and the document view on every frame of every flick.
//  ─────────────────────────────────────────────────────────────────────────────
//

import SwiftUI

/// The comment markers for every page currently on screen.
///
/// **On failure:** a page that is not laid out yet contributes nothing, and a
/// document with no comments draws nothing at all. Neither is an error: a marker
/// briefly missing during a scroll is invisible to the reader, and a comment is
/// never lost because its dot was not drawn — the review sheet lists it either
/// way.
struct ReaderMarkerLayer: View {

    let model: ReaderModel

    var body: some View {
        // Reading the revision is the subscription: without it this layer would
        // be laid out once and then sit still while the page scrolled out from
        // under it.
        let version = self.model.geometryRevision

        if let capture = self.model.capture, capture.comments.isEmpty == false {
            CommentMarkersOverlay(
                model: capture,
                resolver: self.model.pageResolver,
                pageIndices: self.model.pageResolver.visiblePageIndices(),
                geometryVersion: version
            )
        }
    }
}
