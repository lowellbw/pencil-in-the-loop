//
//  InkPageBinding.swift
//  Annotate · Ink
//
//  Which page a canvas is currently showing. Identity only — never geometry.
//
//  Geometry is deliberately absent. A page keeps its identity across rotation,
//  zoom and split view; if the size were part of the key, rotating the iPad
//  would silently orphan every debounced save in flight (docs/04-flows.md § F3).
//

import Foundation

/// The identity of one page's ink: a document and a zero-based page index.
///
/// This is the key everything downstream is filed under — the debounce timer,
/// the pending drawing, the cached bytes and the recognition task. It is
/// independent of any `PKCanvasView`, which is what makes canvas recycling
/// safe: recycling moves a view, it never moves the work queued against a page.
public struct InkPageBinding: Sendable, Hashable {

    /// The document the page belongs to.
    public let documentId: UUID

    /// Zero-based page index, matching `PageSnapshot.pageIndex`.
    public let pageIndex: Int

    public init(documentId: UUID, pageIndex: Int) {
        self.documentId = documentId
        self.pageIndex = pageIndex
    }
}
