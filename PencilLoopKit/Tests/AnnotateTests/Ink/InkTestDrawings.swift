import CoreGraphics
import Foundation
import PencilKit
import UIKit

/// Synthetic `PKDrawing`s for the ink tests.
///
/// Real strokes cannot be produced without a Pencil, but a `PKDrawing` built
/// from `PKStrokePath`s archives and unarchives through exactly the same code
/// path as one drawn by hand, which is all the persistence tests need
/// (STYLE.md § 10 — test the pure logic, hand-test the input).
enum InkTestDrawings {

    /// A drawing with `strokeCount` short diagonal strokes.
    static func drawing(strokeCount: Int) -> PKDrawing {
        var strokes: [PKStroke] = []
        for index in 0..<strokeCount {
            strokes.append(InkTestDrawings.stroke(offset: Double(index)))
        }
        return PKDrawing(strokes: strokes)
    }

    /// A drawing with nothing in it, which the coordinator stores as nil.
    static var empty: PKDrawing {
        PKDrawing()
    }

    private static func stroke(offset: Double) -> PKStroke {
        let points = (0..<8).map { step -> PKStrokePoint in
            PKStrokePoint(
                location: CGPoint(x: Double(step) * 4 + offset, y: Double(step) * 4),
                timeOffset: TimeInterval(step) * 0.01,
                size: CGSize(width: 3, height: 3),
                opacity: 1,
                force: 1,
                azimuth: 0,
                altitude: CGFloat.pi / 2
            )
        }
        let path = PKStrokePath(controlPoints: points, creationDate: Date(timeIntervalSince1970: 0))
        return PKStroke(ink: PKInk(.pen, color: UIColor.black), path: path)
    }
}
