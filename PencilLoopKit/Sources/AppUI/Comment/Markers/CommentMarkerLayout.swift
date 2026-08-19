//
//  CommentMarkerLayout.swift
//  AppUI · Comment · Markers
//
//  Where the dots go. Pure arithmetic on a page rect and a list of anchors, so
//  that the one part of the marker layer with a right answer can be reasoned
//  about — and, when there is a test target for AppUI, tested — without a PDF.
//

import Foundation
import CoreGraphics
import Core

/// Places comment markers down the outer margin of a page.
///
/// **The shape of the answer** (docs/01-design-principles.md): a small filled
/// circle, accent-tinted, ~16pt, at the vertical position of its anchor. Not a
/// speech bubble. Not a number badge — *unless* several comments share a line,
/// which is the one case a count is clearer than a pile of overlapping dots.
///
/// **Never fails.** An empty page rect or an empty comment list yields no
/// placements; nothing here can throw and nothing needs a document.
public enum CommentMarkerLayout {

    /// The numbers the layout uses. All in points except `trailingFraction`.
    public struct Metrics: Sendable, Hashable {

        /// Marker diameter. ~16pt per docs/01-design-principles.md; scale it
        /// with `UIFontMetrics` in the view so it grows with Dynamic Type.
        public var diameter: CGFloat

        /// How far the marker's centre sits from the page's trailing edge, as a
        /// fraction of page width.
        ///
        /// A quarter of the annotation margin: `PageGeometry.annotationFriendly`
        /// gives the right margin 140pt of a 595pt page precisely so
        /// handwriting has somewhere to live (docs/03-architecture.md § 1), and
        /// a marker parked in the middle of it would be sitting on the
        /// marginalia. The outer quarter is the part nobody writes in.
        public var trailingFraction: Double

        /// Floor and ceiling for that inset in points, so the marker neither
        /// hangs off a narrow page nor drifts into the middle of a wide one.
        public var minimumTrailingInset: CGFloat
        public var maximumTrailingInset: CGFloat

        /// Two anchors whose marker centres fall within this many points of
        /// each other are treated as sharing a line, and become one marker with
        /// a count.
        public var clusterSpacing: CGFloat

        /// The least vertical gap between two separate markers, after
        /// clustering. Groups closer than this are nudged apart rather than
        /// merged: they are different lines and should read as different lines.
        public var minimumSeparation: CGFloat

        public init(
            diameter: CGFloat = 16,
            trailingFraction: Double = Metrics.annotationMarginFraction / 4,
            minimumTrailingInset: CGFloat = 14,
            maximumTrailingInset: CGFloat = 34,
            clusterSpacing: CGFloat = 20,
            minimumSeparation: CGFloat = 20
        ) {
            self.diameter = diameter
            self.trailingFraction = trailingFraction
            self.minimumTrailingInset = minimumTrailingInset
            self.maximumTrailingInset = maximumTrailingInset
            self.clusterSpacing = clusterSpacing
            self.minimumSeparation = minimumSeparation
        }

        /// The right margin of the only page geometry v1 ships, as a fraction
        /// of page width. Read from Core rather than re-typed (STYLE.md § 9).
        public static let annotationMarginFraction =
            PageGeometry.annotationFriendly.marginRight / PageGeometry.annotationFriendly.pageWidth

        /// What ships.
        public static let standard = Metrics()
    }

    /// One marker on screen: a position, and the comments it stands for.
    public struct Placement: Sendable, Hashable, Identifiable {

        /// The first comment in the group. Stable across layout passes because
        /// the input is sorted by position before grouping.
        public var id: UUID

        /// Every comment this marker represents, in document order. More than
        /// one means several share a line, and the marker carries a count.
        public var commentIds: [UUID]

        /// Centre of the marker, in the same coordinate space as the page rect
        /// that was passed in.
        public var centre: CGPoint

        public init(id: UUID, commentIds: [UUID], centre: CGPoint) {
            self.id = id
            self.commentIds = commentIds
            self.centre = centre
        }

        /// How many comments this marker stands for. One is the common case and
        /// draws a bare dot.
        public var count: Int { commentIds.count }

        /// True when the marker should carry a number
        /// (docs/01-design-principles.md).
        public var showsCount: Bool { commentIds.count > 1 }
    }

    /// Lays out every marker for one page.
    ///
    /// - Parameters:
    ///   - comments: the page's comments. Comments belonging to other pages are
    ///     ignored rather than rejected, so a caller may pass the whole
    ///     document's list.
    ///   - pageIndex: the page being laid out.
    ///   - pageRect: that page's frame in the view the markers are drawn in.
    ///   - metrics: the dials.
    /// - Returns: placements top to bottom. Empty when the page rect has no
    ///   area — a page mid-layout is not an error.
    public static func placements(
        for comments: [CommentSnapshot],
        pageIndex: Int,
        pageRect: CGRect,
        metrics: Metrics = .standard
    ) -> [Placement] {
        guard pageRect.width > 0, pageRect.height > 0 else { return [] }

        let onPage = comments
            .filter { $0.resolvedOnPage == pageIndex }
            .map { (id: $0.id, y: centreY(of: $0.anchor, in: pageRect)) }
            .sorted { $0.y < $1.y }
        guard !onPage.isEmpty else { return [] }

        let x = markerX(in: pageRect, metrics: metrics)

        // 1 · group anything that reads as the same line.
        var groups: [[(id: UUID, y: CGFloat)]] = []
        for entry in onPage {
            if let last = groups.last?.last, entry.y - last.y <= metrics.clusterSpacing {
                groups[groups.count - 1].append(entry)
            } else {
                groups.append([entry])
            }
        }

        // 2 · one centre per group, then push apart anything still colliding.
        let halfHeight = metrics.diameter / 2
        let lowest = pageRect.minY + halfHeight
        let highest = max(lowest, pageRect.maxY - halfHeight)
        var placements: [Placement] = []
        var previousY: CGFloat?

        for group in groups {
            let mean = group.reduce(CGFloat(0)) { $0 + $1.y } / CGFloat(group.count)
            var y = min(max(mean, lowest), highest)
            if let previousY, y - previousY < metrics.minimumSeparation {
                y = min(previousY + metrics.minimumSeparation, highest)
            }
            previousY = y
            let ids = group.map { $0.id }
            guard let first = ids.first else { continue }
            placements.append(
                Placement(id: first, commentIds: ids, centre: CGPoint(x: x, y: y))
            )
        }
        return placements
    }

    /// The vertical centre of an anchor on a laid-out page.
    ///
    /// `NormalisedRect` is top-left origin with y increasing downwards, the same
    /// as view space, so this is a multiply and an add — no flip. The flip
    /// happened once, in the Reader, on the way out of PDF user space
    /// (NormalisedRect.swift).
    public static func centreY(of anchor: Anchor, in pageRect: CGRect) -> CGFloat {
        let midY = anchor.normalisedRect.y + anchor.normalisedRect.height / 2
        return pageRect.minY + CGFloat(midY) * pageRect.height
    }

    /// The x every marker on a page shares: in from the trailing edge by
    /// `trailingFraction` of the page width, clamped to the inset bounds.
    public static func markerX(in pageRect: CGRect, metrics: Metrics = .standard) -> CGFloat {
        let proportional = CGFloat(metrics.trailingFraction) * pageRect.width
        let inset = min(max(proportional, metrics.minimumTrailingInset), metrics.maximumTrailingInset)
        return pageRect.maxX - inset
    }
}
