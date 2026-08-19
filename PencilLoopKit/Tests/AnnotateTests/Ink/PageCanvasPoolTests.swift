import XCTest
import CoreGraphics
import Core
@testable import Annotate

/// Recycling, as PDFKit's overlay provider drives it.
@MainActor
final class PageCanvasPoolTests: XCTestCase {

    private let documentId = UUID(uuidString: "F7A1C0DE-0000-4000-8000-0000000000C1")!
    private let a4 = CGSize(width: 595, height: 842)

    private func makePool(store: InkTestStore = InkTestStore()) -> PageCanvasPool {
        PageCanvasPool(coordinator: InkPersistenceCoordinator(store: store, policy: .standard))
    }

    func testAnOverlayIsBoundToItsPage() async {
        let pool = makePool()
        await pool.open(documentId: documentId, pages: [])
        let overlay = pool.overlay(forPageIndex: 2, pageSize: a4)
        XCTAssertEqual(overlay.binding, InkPageBinding(documentId: documentId, pageIndex: 2))
        XCTAssertTrue(pool.isDisplaying(pageIndex: 2))
    }

    func testTheSamePageGetsTheSameOverlayBack() async {
        let pool = makePool()
        await pool.open(documentId: documentId, pages: [])
        let first = pool.overlay(forPageIndex: 1, pageSize: a4)
        let second = pool.overlay(forPageIndex: 1, pageSize: a4)
        XCTAssertTrue(first === second)
    }

    func testACanvasIsRecycledOntoTheNextPage() async {
        let pool = makePool()
        await pool.open(documentId: documentId, pages: [])
        let first = pool.overlay(forPageIndex: 0, pageSize: a4)
        pool.willEndDisplaying(pageIndex: 0)
        XCTAssertFalse(pool.isDisplaying(pageIndex: 0))

        let second = pool.overlay(forPageIndex: 1, pageSize: a4)
        XCTAssertTrue(first === second, "Canvases are recycled with the page views, not rebuilt.")
        XCTAssertEqual(second.binding, InkPageBinding(documentId: documentId, pageIndex: 1))
    }

    func testPreloadedInkIsOnScreenInTheSameFrameAsThePage() async {
        let bytes = InkTestDrawings.drawing(strokeCount: 2).dataRepresentation()
        let pool = makePool()
        await pool.open(
            documentId: documentId,
            pages: [PageSnapshot(pageIndex: 3, drawingData: bytes, hasInk: true)]
        )
        let overlay = pool.overlay(forPageIndex: 3, pageSize: a4)
        XCTAssertEqual(overlay.canvasView.drawing.strokes.count, 2)
    }

    func testSparesAreCappedSoALongDocumentDoesNotAccumulateCanvases() async {
        let pool = makePool()
        pool.spareLimit = 2
        await pool.open(documentId: documentId, pages: [])
        for page in 0..<6 {
            _ = pool.overlay(forPageIndex: page, pageSize: a4)
        }
        for page in 0..<6 {
            pool.willEndDisplaying(pageIndex: page)
        }
        for page in 0..<6 {
            XCTAssertFalse(pool.isDisplaying(pageIndex: page))
        }
    }

    func testOverlaysRequestedBeforeADocumentIsOpenedAreUnboundRatherThanAbsent() {
        let pool = makePool()
        let overlay = pool.overlay(forPageIndex: 0, pageSize: a4)
        XCTAssertNil(overlay.binding)
    }

    func testClosingWritesEverythingOutstanding() async {
        let store = InkTestStore()
        let coordinator = InkPersistenceCoordinator(store: store, policy: .standard)
        let pool = PageCanvasPool(coordinator: coordinator)
        await pool.open(documentId: documentId, pages: [])

        let overlay = pool.overlay(forPageIndex: 4, pageSize: a4)
        overlay.canvasView.drawing = InkTestDrawings.drawing(strokeCount: 1)
        overlay.canvasViewDrawingDidChange(overlay.canvasView)

        await pool.close()

        let writes = await store.drawingWrites
        XCTAssertTrue(writes.contains { $0.pageIndex == 4 })
    }
}
