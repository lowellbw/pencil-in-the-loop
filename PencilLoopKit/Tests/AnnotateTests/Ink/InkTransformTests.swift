import XCTest
import CoreGraphics
@testable import Annotate

/// Zoom and rotation arithmetic. "On zoom, scale the canvas transform with the
/// page, never re-render the strokes" (docs/03-architecture.md § 2) only works
/// if this is right; everything else about ink drift on zoom follows from here.
final class InkTransformTests: XCTestCase {

    private let a4 = CGSize(width: 595, height: 842)

    func testUnzoomedPageScalesByOne() {
        XCTAssertEqual(InkTransform.scale(pageSize: a4, displayedSize: a4), 1, accuracy: 0.0001)
    }

    func testZoomingScalesProportionally() {
        let displayed = CGSize(width: a4.width * 2.5, height: a4.height * 2.5)
        XCTAssertEqual(InkTransform.scale(pageSize: a4, displayedSize: displayed), 2.5, accuracy: 0.0001)
    }

    func testScaleNeverOverhangsTheContainer() {
        // A container that is wider than it is tall relative to the page must
        // not stretch the canvas past the bottom of the page.
        let displayed = CGSize(width: a4.width * 3, height: a4.height * 2)
        XCTAssertEqual(InkTransform.scale(pageSize: a4, displayedSize: displayed), 2, accuracy: 0.0001)
    }

    func testDegenerateSizesFallBackToIdentity() {
        XCTAssertEqual(InkTransform.scale(pageSize: .zero, displayedSize: a4), 1, accuracy: 0.0001)
        XCTAssertEqual(InkTransform.scale(pageSize: a4, displayedSize: .zero), 1, accuracy: 0.0001)
        XCTAssertTrue(InkTransform.transform(scale: .nan).isIdentity)
        XCTAssertTrue(InkTransform.transform(scale: 0).isIdentity)
    }

    func testTransformIsAPureScale() {
        let transform = InkTransform.transform(pageSize: a4, displayedSize: CGSize(width: a4.width * 2, height: a4.height * 2))
        XCTAssertEqual(transform.a, 2, accuracy: 0.0001)
        XCTAssertEqual(transform.d, 2, accuracy: 0.0001)
        XCTAssertEqual(transform.tx, 0, accuracy: 0.0001)
        XCTAssertEqual(transform.ty, 0, accuracy: 0.0001)
    }

    func testCentreIsTheMiddleOfTheOverlay() {
        let centre = InkTransform.centre(of: CGRect(x: 10, y: 20, width: 100, height: 200))
        XCTAssertEqual(centre.x, 60, accuracy: 0.0001)
        XCTAssertEqual(centre.y, 120, accuracy: 0.0001)
    }

    func testUprightPagesKeepTheirBox() {
        XCTAssertEqual(InkTransform.displaySize(cropBox: a4, rotation: 0), a4)
        XCTAssertEqual(InkTransform.displaySize(cropBox: a4, rotation: 180), a4)
        XCTAssertEqual(InkTransform.displaySize(cropBox: a4, rotation: 360), a4)
    }

    func testQuarterTurnedPagesSwapTheirDimensions() {
        let landscape = CGSize(width: 842, height: 595)
        XCTAssertEqual(InkTransform.displaySize(cropBox: a4, rotation: 90), landscape)
        XCTAssertEqual(InkTransform.displaySize(cropBox: a4, rotation: 270), landscape)
        XCTAssertEqual(InkTransform.displaySize(cropBox: a4, rotation: -90), landscape)
    }

    func testARotationThatIsNotAQuarterTurnIsIgnored() {
        XCTAssertEqual(InkTransform.displaySize(cropBox: a4, rotation: 45), a4)
    }

    func testTinyScaleChangesAreNotWorthATransform() {
        XCTAssertFalse(InkTransform.hasChanged(from: 2, to: 2.0001))
        XCTAssertTrue(InkTransform.hasChanged(from: 2, to: 2.05))
    }

    func testRenderScaleIsCappedAndNeverBelowTheDisplayScale() {
        XCTAssertEqual(InkTransform.renderScale(for: 1, displayScale: 2, maximum: 3), 2, accuracy: 0.0001)
        XCTAssertEqual(InkTransform.renderScale(for: 2, displayScale: 2, maximum: 3), 4, accuracy: 0.0001)
        XCTAssertEqual(InkTransform.renderScale(for: 12, displayScale: 2, maximum: 3), 6, accuracy: 0.0001)
        XCTAssertEqual(InkTransform.renderScale(for: 4, displayScale: 0, maximum: 3), 6, accuracy: 0.0001)
    }
}
