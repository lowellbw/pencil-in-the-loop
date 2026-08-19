import XCTest
import CoreGraphics
import PencilKit
import Core
@testable import Annotate

/// The recycle path's state hand-off — the place docs/03-architecture.md § 2
/// says the real bugs live. Pencil input itself cannot be tested here; what can
/// be is what happens to a canvas when it is handed to a different page.
@MainActor
final class PageCanvasControllerTests: XCTestCase {

    private let documentId = UUID(uuidString: "F7A1C0DE-0000-4000-8000-0000000000B1")!
    private let a4 = CGSize(width: 595, height: 842)

    private func binding(_ pageIndex: Int) -> InkPageBinding {
        InkPageBinding(documentId: documentId, pageIndex: pageIndex)
    }

    private func makeController(store: InkTestStore = InkTestStore()) -> PageCanvasController {
        PageCanvasController(coordinator: InkPersistenceCoordinator(store: store, policy: .standard))
    }

    func testTheCanvasIsPencilOnlyAndDoesNotScroll() {
        let controller = makeController()
        XCTAssertEqual(controller.canvasView.drawingPolicy, .pencilOnly)
        XCTAssertFalse(controller.canvasView.isScrollEnabled)
        XCTAssertEqual(controller.canvasView.overrideUserInterfaceStyle, .light)
    }

    func testBindingAdoptsThePage() {
        let controller = makeController()
        controller.bind(to: binding(4), pageSize: a4)
        XCTAssertEqual(controller.binding, binding(4))
        XCTAssertEqual(controller.pageSize, a4)
    }

    func testHandingTheCanvasToAnotherPageClearsTheOldPagesInk() {
        let controller = makeController()
        controller.bind(to: binding(0), pageSize: a4, drawingHint: InkTestDrawings.drawing(strokeCount: 3).dataRepresentation())
        XCTAssertFalse(controller.canvasView.drawing.strokes.isEmpty)

        controller.bind(to: binding(1), pageSize: a4)
        XCTAssertEqual(controller.binding, binding(1))
        XCTAssertTrue(
            controller.canvasView.drawing.strokes.isEmpty,
            "A recycled canvas must never show the previous page's notes, even for one frame."
        )
    }

    func testPrepareForReuseDetachesAndClears() {
        let controller = makeController()
        controller.bind(to: binding(2), pageSize: a4, drawingHint: InkTestDrawings.drawing(strokeCount: 1).dataRepresentation())
        controller.prepareForReuse()
        XCTAssertNil(controller.binding)
        XCTAssertTrue(controller.canvasView.drawing.strokes.isEmpty)
    }

    func testReBindingToTheSamePageDoesNotDisturbTheInkOnScreen() {
        // PDFKit asks for the overlay again whenever it re-lays-out a page it is
        // already showing. Treating that as a fresh bind would reload the
        // drawing underneath a stroke the reader is in the middle of.
        let controller = makeController()
        controller.bind(to: binding(6), pageSize: a4)
        controller.canvasView.drawing = InkTestDrawings.drawing(strokeCount: 2)
        controller.canvasViewDrawingDidChange(controller.canvasView)

        controller.bind(to: binding(6), pageSize: a4)
        XCTAssertEqual(controller.canvasView.drawing.strokes.count, 2)
    }

    func testRotationChangesTheGeometryWithoutChangingTheBinding() {
        let controller = makeController()
        controller.bind(to: binding(0), pageSize: a4)
        let rotated = InkTransform.displaySize(cropBox: a4, rotation: 90)
        controller.bind(to: binding(0), pageSize: rotated)
        XCTAssertEqual(controller.binding, binding(0))
        XCTAssertEqual(controller.pageSize, rotated)
    }

    func testStrokesMadeBeforeARecycleAreStillWritten() async {
        // The data-loss test. A stroke lands, the page scrolls away, the canvas
        // is handed to a different page, and nothing else ever happens to it.
        // The write must still reach the store.
        let store = InkTestStore()
        let coordinator = InkPersistenceCoordinator(store: store, policy: .standard)
        let controller = PageCanvasController(coordinator: coordinator)

        controller.bind(to: binding(9), pageSize: a4)
        controller.canvasView.drawing = InkTestDrawings.drawing(strokeCount: 2)
        controller.canvasViewDrawingDidChange(controller.canvasView)

        controller.prepareForReuse()
        controller.bind(to: binding(10), pageSize: a4)

        await coordinator.flushAll()

        let writes = await store.drawingWrites
        XCTAssertTrue(writes.contains { $0.pageIndex == 9 && $0.byteCount != nil })
    }

    func testStrokesOnAnUnboundCanvasAreDiscardedRatherThanMisfiled() async {
        let store = InkTestStore()
        let coordinator = InkPersistenceCoordinator(store: store, policy: .standard)
        let controller = PageCanvasController(coordinator: coordinator)

        controller.canvasView.drawing = InkTestDrawings.drawing(strokeCount: 1)
        controller.canvasViewDrawingDidChange(controller.canvasView)
        await coordinator.flushAll()

        let writes = await store.drawingWrites
        XCTAssertTrue(writes.isEmpty, "Ink with no page cannot be filed under someone else's page.")
    }

    func testLayoutScalesTheCanvasByTransformAndLeavesItsBoundsInPageSpace() {
        let controller = makeController()
        controller.bind(to: binding(0), pageSize: a4)
        controller.frame = CGRect(origin: .zero, size: CGSize(width: a4.width * 2, height: a4.height * 2))
        controller.setNeedsLayout()
        controller.layoutIfNeeded()

        XCTAssertEqual(controller.canvasView.bounds.size.width, a4.width, accuracy: 0.5)
        XCTAssertEqual(controller.canvasView.bounds.size.height, a4.height, accuracy: 0.5)
        XCTAssertEqual(controller.canvasView.transform.a, 2, accuracy: 0.01)
        XCTAssertEqual(controller.canvasView.transform.d, 2, accuracy: 0.01)
        XCTAssertEqual(controller.canvasView.center.x, controller.bounds.midX, accuracy: 0.5)
    }

    func testZoomingOutAgainRestoresTheIdentityTransform() {
        let controller = makeController()
        controller.bind(to: binding(0), pageSize: a4)
        controller.frame = CGRect(origin: .zero, size: CGSize(width: a4.width * 3, height: a4.height * 3))
        controller.setNeedsLayout()
        controller.layoutIfNeeded()
        controller.frame = CGRect(origin: .zero, size: a4)
        controller.setNeedsLayout()
        controller.layoutIfNeeded()

        XCTAssertEqual(controller.canvasView.transform.a, 1, accuracy: 0.01)
        XCTAssertEqual(controller.canvasView.bounds.size.width, a4.width, accuracy: 0.5)
    }
}
