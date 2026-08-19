//
//  CommentMarkerLayer.swift
//  AppUI · Comment · Markers
//
//  The markers for one page, and the popover a tap on one opens.
//

import SwiftUI
import Core

/// Draws one page's comment markers and handles taps on them.
///
/// The Reader overlays one of these per visible page, passing the page's frame
/// in the same coordinate space the overlay is laid out in. Positions come from
/// `CommentMarkerLayout`, which is pure arithmetic and knows nothing about
/// PDFKit; this view adds only the tap target and the popover.
///
/// **Why the popover is presented by the layer and not by each marker.**
/// Deleting the only comment behind a marker removes the marker, and a popover
/// hosted by a view that has just disappeared goes with it — taking the Undo
/// with it. The attachment rect is remembered when the marker is tapped, so the
/// popover outlives the marker by exactly as long as the undo is on offer.
///
/// **Never fails.** A page mid-layout has no rect and draws nothing.
public struct CommentMarkerLayer: View {

    /// The document's capture model.
    public var model: CommentCaptureModel

    /// The page these markers belong to.
    public var pageIndex: Int

    /// That page's frame, in this overlay's coordinate space.
    public var pageRect: CGRect

    /// The layout dials.
    public var metrics: CommentMarkerLayout.Metrics

    @State private var attachmentRect: CGRect = .zero

    public init(
        model: CommentCaptureModel,
        pageIndex: Int,
        pageRect: CGRect,
        metrics: CommentMarkerLayout.Metrics = .standard
    ) {
        self.model = model
        self.pageIndex = pageIndex
        self.pageRect = pageRect
        self.metrics = metrics
    }

    public var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(placements) { placement in
                Button {
                    attachmentRect = rect(around: placement.centre)
                    model.selectComments(ids: placement.commentIds)
                } label: {
                    CommentMarkerView(
                        count: placement.count,
                        isSelected: isSelected(placement),
                        diameter: metrics.diameter
                    )
                }
                .buttonStyle(.plain)
                .position(placement.centre)
            }
        }
        .popover(
            isPresented: presentation,
            attachmentAnchor: .rect(.rect(attachmentRect)),
            arrowEdge: .trailing
        ) {
            CommentMarkerDetailView(
                comments: model.selectedComments,
                deletedComment: model.lastDeleted,
                onDelete: { model.delete($0) },
                onUndo: { model.undoDeletion() }
            )
            .presentationCompactAdaptation(.popover)
        }
    }

    private var placements: [CommentMarkerLayout.Placement] {
        CommentMarkerLayout.placements(
            for: model.comments,
            pageIndex: pageIndex,
            pageRect: pageRect,
            metrics: metrics
        )
    }

    private func isSelected(_ placement: CommentMarkerLayout.Placement) -> Bool {
        let selected = Set(model.selectedComments.map(\.id))
        return placement.commentIds.contains { selected.contains($0) }
    }

    /// True only when the open selection belongs to this page, so that two
    /// visible pages do not both try to present it.
    private var isPresenting: Bool {
        if let first = model.selectedComments.first {
            return first.resolvedOnPage == pageIndex
        }
        if let deleted = model.lastDeleted {
            return deleted.resolvedOnPage == pageIndex
        }
        return false
    }

    private var presentation: Binding<Bool> {
        Binding(
            get: { isPresenting },
            set: { presented in
                guard !presented else { return }
                model.clearSelection()
            }
        )
    }

    private func rect(around centre: CGPoint) -> CGRect {
        CGRect(
            x: centre.x - metrics.diameter / 2,
            y: centre.y - metrics.diameter / 2,
            width: metrics.diameter,
            height: metrics.diameter
        )
    }
}

// MARK: - Previews

private let markerPreviewPageRect = CGRect(x: 20, y: 20, width: 320, height: 452)

private func markerPreviewComment(
    _ ordinal: Int,
    y: Double,
    text: String
) -> CommentSnapshot {
    CommentSnapshot(
        id: UUID(uuidString: "C0FFEE00-0000-4000-8000-00000000000\(ordinal)") ?? UUID(),
        createdAt: Date(timeIntervalSince1970: 1_787_000_000 + Double(ordinal)),
        text: text,
        source: .voice,
        anchor: Anchor(
            quoted: text,
            pageIndex: 0,
            normalisedRect: NormalisedRect(x: 0.12, y: y, width: 0.7, height: 0.02)
        ),
        resolvedOnPage: 0
    )
}

#Preview("Markers on a page") {
    let model = CommentCaptureModel(
        environment: PreviewEnvironment(),
        documentId: UUID(),
        documentText: "",
        documentTitle: "Auth refactor plan",
        comments: [
            markerPreviewComment(1, y: 0.18, text: "No dual-write window."),
            markerPreviewComment(2, y: 0.42, text: "Shadow read for a day."),
            // Two within a line of each other, which become one marker with a
            // count (docs/01-design-principles.md).
            markerPreviewComment(3, y: 0.60, text: "Infinite retry loop?"),
            markerPreviewComment(4, y: 0.612, text: "And what happens on a 429?")
        ]
    )
    ZStack(alignment: .topLeading) {
        Rectangle()
            .fill(Color(uiColor: .secondarySystemBackground))
            .frame(width: markerPreviewPageRect.width, height: markerPreviewPageRect.height)
            .position(x: markerPreviewPageRect.midX, y: markerPreviewPageRect.midY)
        CommentMarkerLayer(model: model, pageIndex: 0, pageRect: markerPreviewPageRect)
    }
    .frame(width: 360, height: 492)
}
