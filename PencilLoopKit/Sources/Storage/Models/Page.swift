//
//  Page.swift
//  Storage · Models
//
//  One page's ink. A row exists only for a page something has been done to —
//  see `Document.pageSnapshots()`.
//
//  Deviation from docs/03-architecture.md § Data model: `recognisedInk` is a
//  non-optional String, empty meaning "nothing recognised", rather than
//  `String?`. Optional strings inside a `#Predicate` are the single most
//  reliable way to get a SwiftData fetch that compiles and then fails at
//  runtime, and search has to reach this column (docs/02-spec.md § S1). The DTO
//  keeps the optional: `PageSnapshot.recognisedInk` is nil when this is empty,
//  which loses nothing, because nil there already means "not run, unavailable,
//  or found nothing" (DTOs.swift).
//

import Foundation
import SwiftData
import Core

/// The ink on one page of one document.
@Model
final class Page {

    /// Zero-based, matching `PageSnapshot.pageIndex` and `Anchor.pageIndex`.
    var pageIndex: Int

    /// Archived `PKDrawing` bytes, exactly what `dataRepresentation()`
    /// produced. Storage never interprets them — it does not import PencilKit.
    ///
    /// External storage because a page of dense annotation is measured in
    /// hundreds of kilobytes and no library fetch wants it.
    @Attribute(.externalStorage) var drawingData: Data?

    /// `PKStrokeRecognizer` output. Empty when recognition has not run, is
    /// unavailable, or found nothing (docs/04-flows.md § F3).
    var recognisedInk: String

    /// Whether this page carries any strokes. Maintained by the store rather
    /// than derived, because deriving it means unarchiving a `PKDrawing`, which
    /// Storage cannot do.
    var hasInk: Bool

    /// The owning document. The inverse is declared on `Document.pages`.
    var document: Document?

    init(
        pageIndex: Int,
        drawingData: Data? = nil,
        recognisedInk: String = "",
        hasInk: Bool = false,
        document: Document? = nil
    ) {
        self.pageIndex = pageIndex
        self.drawingData = drawingData
        self.recognisedInk = recognisedInk
        self.hasInk = hasInk
        self.document = document
    }
}

extension Page {

    /// The detached form. Empty recognised ink becomes nil, per the file header.
    func snapshot() -> PageSnapshot {
        PageSnapshot(
            pageIndex: pageIndex,
            drawingData: drawingData,
            recognisedInk: recognisedInk.isEmpty ? nil : recognisedInk,
            hasInk: hasInk
        )
    }

    /// True when the row carries nothing worth keeping, so the store can drop it
    /// rather than leaving an empty row behind after an erase.
    var isEmpty: Bool {
        drawingData == nil && recognisedInk.isEmpty && hasInk == false
    }
}
