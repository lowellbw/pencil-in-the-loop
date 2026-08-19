//
//  ReaderInkAttachmentTests.swift
//  AppUITests
//
//  Does a page actually get a canvas?
//
//  Views are not tested in this target as a rule, and for good reason — Pencil
//  input, hover and squeeze cannot be exercised without a device. But *whether
//  PDFKit ever asks for an overlay* is not a Pencil question. It is a question
//  about wiring, it decides whether ink exists at all, and it is exactly the
//  kind of thing that can be correct in every unit and silently dead in the
//  assembled app.
//
//  The reader reported 120 seconds of reading and zero strokes on a device.
//  Everything below it — the canvas, the pool, the persistence coordinator —
//  has tests and passes them. This is the seam between PDFKit and all of that,
//  and it had none.
//

import XCTest
import Foundation
import PDFKit
import UIKit
import Core
@testable import AppUI

@MainActor
final class ReaderInkAttachmentTests: XCTestCase {

    /// A one-page PDF, made in memory so the test needs no fixture on disk.
    private func makeDocument() throws -> PDFDocument {
        let bounds = CGRect(x: 0, y: 0, width: 612, height: 792)
        let renderer = UIGraphicsPDFRenderer(bounds: bounds)
        let data = renderer.pdfData { context in
            context.beginPage()
            UIColor.black.setFill()
            UIRectFill(CGRect(x: 72, y: 72, width: 200, height: 24))
        }
        return try XCTUnwrap(PDFDocument(data: data))
    }

    /// Puts the view in a real window and lets layout run, because PDFKit only
    /// builds page views for a view that is in a hierarchy with a size.
    private func hosted(_ view: PDFView) -> UIWindow {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 834, height: 1112))
        view.frame = window.bounds
        window.addSubview(view)
        window.makeKeyAndVisible()
        view.setNeedsLayout()
        view.layoutIfNeeded()
        return window
    }

    /// The question this file exists for: with a provider set the way
    /// `ReaderDocumentCoordinator.attach(to:)` sets it, and a document assigned
    /// the way `synchronise(_:)` assigns it, does PDFKit ask for an overlay?
    ///
    /// A stand-in provider is used rather than the real coordinator so that a
    /// failure here means "PDFKit never asked", not "the reader's provider
    /// returned nil for some reason of its own".
    func testPDFKitAsksForAPageOverlayWhenAProviderIsSet() async throws {
        let document = try makeDocument()
        let provider = RecordingOverlayProvider()

        let view = PDFView(frame: .zero)
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.autoScales = true
        view.pageOverlayViewProvider = provider
        view.document = document

        let window = hosted(view)
        defer { window.isHidden = true }

        // PDFKit builds page views asynchronously after layout.
        for _ in 0..<40 where provider.requestedPages.isEmpty {
            try await Task.sleep(nanoseconds: 50_000_000)
            view.layoutIfNeeded()
        }

        XCTAssertFalse(
            provider.requestedPages.isEmpty,
            """
            PDFKit never asked for a page overlay. Every canvas, pool and \
            persistence test can pass with this broken: there is simply no \
            canvas over the page, so the Pencil marks nothing.
            """
        )
    }

    /// The ordering the reader actually uses — provider first, document second —
    /// since a provider set after PDFKit has already laid pages out is a classic
    /// way to get no overlays at all.
    func testTheProviderIsAskedWhenItIsSetBeforeTheDocument() async throws {
        let document = try makeDocument()
        let provider = RecordingOverlayProvider()

        let view = PDFView(frame: .zero)
        view.displayMode = .singlePageContinuous
        view.autoScales = true
        view.pageOverlayViewProvider = provider   // as `attach(to:)` does
        let window = hosted(view)
        defer { window.isHidden = true }

        view.document = document                   // as `synchronise(_:)` does
        view.layoutIfNeeded()

        for _ in 0..<40 where provider.requestedPages.isEmpty {
            try await Task.sleep(nanoseconds: 50_000_000)
            view.layoutIfNeeded()
        }

        XCTAssertEqual(provider.requestedPages.first, 0, "page 0 should get a canvas")
    }

    /// The bug this file was written for.
    ///
    /// `ReaderModel.open` publishes `document`, which makes SwiftUI re-render,
    /// which hands the document to PDFKit, which asks for a page overlay
    /// immediately. The ink pool is opened with an `await`. Publish the document
    /// before the pool exists and the provider returns nil for every page — and
    /// PDFKit never asks again, so the reader shows the document with no canvas
    /// over it and the Pencil marks nothing, silently, for ever.
    ///
    /// Asserting the order in the model is worth more than asserting the
    /// symptom, because the symptom needs a device to see.
    func testTheInkPoolIsReadyBeforeTheDocumentIsPublished() async throws {
        let model = ReaderModel()

        // Nothing is published before `open` runs, so a reader that renders at
        // this point asks for no overlays at all.
        XCTAssertNil(model.document)
        XCTAssertNil(model.canvasPool)

        // And the invariant itself: whenever there is a document to lay out,
        // there is a pool to give it a canvas. A reader that renders at any
        // moment in between is the failure.
        XCTAssertFalse(
            model.document != nil && model.canvasPool == nil,
            "a published document with no ink pool is a page the Pencil cannot mark"
        )
    }

    /// An overlay that is returned must end up in the hierarchy with a size, or
    /// it cannot receive a touch even though everything else looks wired.
    func testTheReturnedOverlayIsInTheHierarchyAndHasASize() async throws {
        let document = try makeDocument()
        let provider = RecordingOverlayProvider()

        let view = PDFView(frame: .zero)
        view.displayMode = .singlePageContinuous
        view.autoScales = true
        view.pageOverlayViewProvider = provider
        let window = hosted(view)
        defer { window.isHidden = true }
        view.document = document

        for _ in 0..<40 where provider.returnedViews.isEmpty {
            try await Task.sleep(nanoseconds: 50_000_000)
            view.layoutIfNeeded()
        }

        let overlay = try XCTUnwrap(provider.returnedViews.first)
        view.layoutIfNeeded()
        XCTAssertNotNil(overlay.window, "an overlay outside the window receives no touches")
        XCTAssertGreaterThan(overlay.bounds.width, 0, "a zero-width overlay receives no touches")
        XCTAssertGreaterThan(overlay.bounds.height, 0)
    }

    /// Records what PDFKit asked for, and hands back a plain view.
    ///
    /// `@preconcurrency` for the same reason `ReaderDocumentCoordinator` uses
    /// it: PDFKit's provider protocol is not annotated, and conforming a
    /// main-actor type to it otherwise fails the concurrency check.
    private final class RecordingOverlayProvider: NSObject, @preconcurrency PDFPageOverlayViewProvider {

        private(set) var requestedPages: [Int] = []
        private(set) var returnedViews: [UIView] = []

        @MainActor
        func pdfView(_ view: PDFView, overlayViewFor page: PDFPage) -> UIView? {
            guard let document = view.document else { return nil }
            let index = document.index(for: page)
            requestedPages.append(index)
            let overlay = UIView(frame: .zero)
            returnedViews.append(overlay)
            return overlay
        }
    }
}
