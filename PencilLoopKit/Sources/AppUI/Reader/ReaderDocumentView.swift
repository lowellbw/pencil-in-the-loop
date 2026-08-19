//
//  ReaderDocumentView.swift
//  AppUI · Reader
//
//  `PDFView` in `.singlePageContinuous`, wrapped for SwiftUI and nothing else.
//  Every decision that is not "how do I hold a PDFView" lives in
//  `ReaderDocumentCoordinator`; this file exists to make sure the view is built
//  once and never rebuilt, because rebuilding it would rebuild the ink overlays
//  with it.
//

import PDFKit
import SwiftUI
import UIKit

/// The page itself, full bleed.
///
/// **On failure:** a model with no document produces an empty `PDFView`, which
/// is a grey rectangle rather than a crash. The reader does not show this view
/// at all until `ReaderModel.isReady`, so that state is not reachable in
/// practice; it is handled anyway because `updateUIView` runs on SwiftUI's
/// schedule and not on ours.
public struct ReaderDocumentView: UIViewRepresentable {

    private let model: ReaderModel

    public init(model: ReaderModel) {
        self.model = model
    }

    public func makeCoordinator() -> ReaderDocumentCoordinator {
        ReaderDocumentCoordinator(model: self.model)
    }

    public func makeUIView(context: Context) -> PDFView {
        let view = PDFView(frame: .zero)

        // Continuous vertical scrolling, scaled to fit the width PDFKit is
        // given. `autoScales` is what makes a page fill an iPad in portrait and
        // still fit in split view (docs/02-spec.md § S2).
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.autoScales = true

        // Full bleed: no side margins, a hairline of separation between pages so
        // a page break still reads as one.
        view.displaysPageBreaks = true
        view.pageBreakMargins = UIEdgeInsets(top: 0, left: 0, bottom: 8, right: 0)
        view.backgroundColor = UIColor.secondarySystemBackground

        context.coordinator.attach(to: view)
        return view
    }

    public func updateUIView(_ view: PDFView, context: Context) {
        context.coordinator.synchronise(view)
    }

    public static func dismantleUIView(_ view: PDFView, coordinator: ReaderDocumentCoordinator) {
        coordinator.detach()
    }
}
