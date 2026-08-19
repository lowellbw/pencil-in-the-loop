import XCTest
import PencilKit
import Core
@testable import Annotate

/// Autosave behaviour: coalescing, flushing, the pending-first read that makes
/// canvas recycling safe, and the retry path.
///
/// Timings here are deliberately an order of magnitude faster than the shipping
/// policy so the suite stays quick; the shipping numbers themselves are checked
/// in `InkDebouncePolicyTests`, which needs no clock at all.
final class InkPersistenceCoordinatorTests: XCTestCase {

    private let policy = InkDebouncePolicy(debounceInterval: 0.05, maximumDelay: 0.2, recognitionDelay: 0.02)
    private let documentId = UUID(uuidString: "F7A1C0DE-0000-4000-8000-0000000000A1")!

    private func binding(_ pageIndex: Int) -> InkPageBinding {
        InkPageBinding(documentId: documentId, pageIndex: pageIndex)
    }

    func testAStrokeIsWrittenAfterTheDebounce() async throws {
        let store = InkTestStore()
        let coordinator = InkPersistenceCoordinator(store: store, policy: policy)

        coordinator.record(InkChange(binding: binding(0), drawing: InkTestDrawings.drawing(strokeCount: 1)))
        try await Task.sleep(nanoseconds: 300_000_000)

        let writes = await store.drawingWrites
        XCTAssertEqual(writes.count, 1)
        XCTAssertEqual(writes.first?.pageIndex, 0)
        XCTAssertNotNil(writes.first?.byteCount ?? nil)
    }

    func testRapidStrokesCoalesceIntoOneWrite() async throws {
        let store = InkTestStore()
        let coordinator = InkPersistenceCoordinator(store: store, policy: policy)

        for count in 1...6 {
            coordinator.record(InkChange(binding: binding(0), drawing: InkTestDrawings.drawing(strokeCount: count)))
        }
        try await Task.sleep(nanoseconds: 300_000_000)

        let writes = await store.drawingWrites
        XCTAssertEqual(writes.count, 1, "Six strokes in one burst must produce one write, not six.")
    }

    func testContinuousDrawingIsWrittenAtTheCapRatherThanNever() async throws {
        let store = InkTestStore()
        let coordinator = InkPersistenceCoordinator(store: store, policy: policy)

        // Keep resetting the debounce for longer than the cap allows.
        for count in 1...12 {
            coordinator.record(InkChange(binding: binding(0), drawing: InkTestDrawings.drawing(strokeCount: count)))
            try await Task.sleep(nanoseconds: 30_000_000)
        }

        let writes = await store.drawingWrites
        XCTAssertGreaterThanOrEqual(writes.count, 1, "The maximum delay must force a write during a long unbroken scribble.")
    }

    func testFlushWritesWithoutWaitingForTheDebounce() async {
        let store = InkTestStore()
        let coordinator = InkPersistenceCoordinator(store: store, policy: .standard)

        coordinator.record(InkChange(binding: binding(3), drawing: InkTestDrawings.drawing(strokeCount: 2)))
        await coordinator.flush(binding(3))

        let writes = await store.drawingWrites
        XCTAssertEqual(writes.count, 1)
        XCTAssertEqual(writes.first?.pageIndex, 3)
    }

    func testFlushAllWritesEveryPendingPage() async {
        let store = InkTestStore()
        let coordinator = InkPersistenceCoordinator(store: store, policy: .standard)

        for page in 0..<4 {
            coordinator.record(InkChange(binding: binding(page), drawing: InkTestDrawings.drawing(strokeCount: 1)))
        }
        await coordinator.flushAll()

        let writes = await store.drawingWrites
        XCTAssertEqual(Set(writes.map(\.pageIndex)), Set(0..<4))
        let remaining = await coordinator.pendingPageCount()
        XCTAssertEqual(remaining, 0)
    }

    func testAPendingChangeSurvivesTheCanvasItCameFrom() async {
        // The recycle case, reduced to its essentials: a change is recorded and
        // then nothing else ever happens to the canvas. The write must still
        // land, because the pending work is keyed by page and lives here.
        let store = InkTestStore()
        let coordinator = InkPersistenceCoordinator(store: store, policy: .standard)

        coordinator.record(InkChange(binding: binding(7), drawing: InkTestDrawings.drawing(strokeCount: 3)))
        await coordinator.flushAll()

        let writes = await store.drawingWrites
        XCTAssertEqual(writes.first?.pageIndex, 7)
    }

    func testReadingAPageReturnsUnwrittenInkRatherThanTheStore() async {
        // Scroll away and straight back inside the 500ms window. Reading the
        // store here would show the reader their last strokes vanishing.
        let store = InkTestStore()
        let coordinator = InkPersistenceCoordinator(store: store, policy: .standard)
        await coordinator.preload([PageSnapshot(pageIndex: 1)], documentId: documentId)

        coordinator.record(InkChange(binding: binding(1), drawing: InkTestDrawings.drawing(strokeCount: 2)))

        let data = await coordinator.drawingData(for: binding(1))
        XCTAssertNotNil(data, "Ink that has not been written yet is still the truth about the page.")

        let writes = await store.drawingWrites
        XCTAssertTrue(writes.isEmpty, "Reading must not have provoked a write.")
    }

    /// The window that used to lose ink: `commit` takes the page out of
    /// `pending` and only puts the bytes in the cache once the store has
    /// returned. A canvas recycled back onto the page during that write finds
    /// nothing pending, reads the cache, and — before the fix — was handed the
    /// ink as it was when the document opened. It then painted that, and the
    /// next stroke wrote it back over the top of the strokes in flight.
    ///
    /// The recycle is what triggers the flush, so this is not a rare
    /// interleaving; it is the ordinary one.
    func testAReadDuringAWriteSeesTheInkBeingWrittenAndNotTheInkBeforeIt() async throws {
        let openedWith = InkTestDrawings.drawing(strokeCount: 1).dataRepresentation()
        let store = InkTestStore()
        let coordinator = InkPersistenceCoordinator(store: store, policy: .standard)

        // The document opens with one stroke on page 3, seeded from its
        // snapshots exactly as the reader does it.
        await coordinator.preload(
            [PageSnapshot(pageIndex: 3, drawingData: openedWith, hasInk: true)],
            documentId: documentId
        )

        // Two more strokes, then the page scrolls away and is flushed.
        coordinator.record(InkChange(binding: binding(3), drawing: InkTestDrawings.drawing(strokeCount: 3)))
        await store.setWriteDuration(0.4)
        // Bound outside the Task: calling `binding(3)` inside it would capture
        // `self`, and a non-Sendable XCTestCase cannot cross into a new task.
        let page = binding(3)
        let flush = Task { await coordinator.flush(page) }

        // Long enough for the flush to have reached the store and be waiting
        // there; short enough that it is still waiting.
        try await Task.sleep(nanoseconds: 80_000_000)

        // The page scrolls back: the pool's hint was consumed on first
        // appearance, so the canvas asks for the bytes.
        let drawing = await coordinator.drawingData(for: binding(3))
        let served = try XCTUnwrap(drawing)
        await flush.value

        XCTAssertNotEqual(
            served,
            openedWith,
            "A page read while its own write is in flight was handed the ink from before the strokes that provoked the write."
        )
        let strokeCount = try PKDrawing(data: served).strokes.count
        XCTAssertEqual(strokeCount, 3, "The latest ink for the page is the ink being written, not the ink it replaced.")
    }

    /// The cache has to be able to say "this page is empty" — most pages are —
    /// or `preload` buys nothing for them and every clean page scrolled into
    /// view costs an actor hop and a store read.
    func testAPreloadedPageWithNoInkIsServedWithoutTouchingTheStore() async {
        let store = InkTestStore()
        let coordinator = InkPersistenceCoordinator(store: store, policy: .standard)
        await coordinator.preload(
            (0..<4).map { PageSnapshot(pageIndex: $0) },
            documentId: documentId
        )

        for page in 0..<4 {
            let data = await coordinator.drawingData(for: binding(page))
            XCTAssertNil(data)
        }

        let singleReads = await store.singlePageReadCount
        XCTAssertEqual(singleReads, 0, "A page preloaded without ink must be answered from the cache, not read back.")
        let wholeDocumentReads = await store.pageReadCount
        XCTAssertEqual(wholeDocumentReads, 0)
    }

    /// The same property one step further on: a page whose ink was erased is
    /// known to be empty, and reading it back must not go to the store either.
    func testAnErasedPageIsRememberedAsEmpty() async {
        let store = InkTestStore()
        let coordinator = InkPersistenceCoordinator(store: store, policy: .standard)
        await coordinator.preload([PageSnapshot(pageIndex: 0)], documentId: documentId)

        coordinator.record(InkChange(binding: binding(0), drawing: InkTestDrawings.empty))
        await coordinator.flushAll()

        let data = await coordinator.drawingData(for: binding(0))
        XCTAssertNil(data)
        let singleReads = await store.singlePageReadCount
        XCTAssertEqual(singleReads, 0)
    }

    func testPreloadedInkIsServedWithoutTouchingTheStore() async {
        let bytes = InkTestDrawings.drawing(strokeCount: 2).dataRepresentation()
        let store = InkTestStore()
        let coordinator = InkPersistenceCoordinator(store: store, policy: .standard)
        await coordinator.preload([PageSnapshot(pageIndex: 2, drawingData: bytes, hasInk: true)], documentId: documentId)

        let data = await coordinator.drawingData(for: binding(2))
        XCTAssertEqual(data, bytes)
        let reads = await store.pageReadCount
        XCTAssertEqual(reads, 0)
        let singleReads = await store.singlePageReadCount
        XCTAssertEqual(singleReads, 0)
    }

    func testACacheMissReadsOnePageAndNotTheWholeDocument() async {
        let bytes = InkTestDrawings.drawing(strokeCount: 2).dataRepresentation()
        let store = InkTestStore(pages: [PageSnapshot(pageIndex: 7, drawingData: bytes, hasInk: true)])
        let coordinator = InkPersistenceCoordinator(store: store, policy: .standard)

        let data = await coordinator.drawingData(for: binding(7))

        XCTAssertEqual(data, bytes)
        let wholeDocumentReads = await store.pageReadCount
        XCTAssertEqual(
            wholeDocumentReads,
            0,
            "Drawing one page must not fetch the ink of every page (DocumentStoring.drawingData)."
        )
        let singleReads = await store.singlePageReadCount
        XCTAssertEqual(singleReads, 1)
    }

    func testErasingEveryStrokeClearsThePageRatherThanStoringAnEmptyArchive() async {
        let store = InkTestStore()
        let coordinator = InkPersistenceCoordinator(store: store, policy: .standard)

        coordinator.record(InkChange(binding: binding(0), drawing: InkTestDrawings.empty))
        await coordinator.flushAll()

        let writes = await store.drawingWrites
        XCTAssertEqual(writes.count, 1)
        XCTAssertNil(writes.first?.byteCount ?? nil, "An empty drawing has to clear the page's ink, not save zero strokes.")
    }

    func testAFailedWriteKeepsTheInkAndSucceedsOnTheNextFlush() async {
        let store = InkTestStore(failWrites: true)
        let coordinator = InkPersistenceCoordinator(store: store, policy: .standard)

        coordinator.record(InkChange(binding: binding(5), drawing: InkTestDrawings.drawing(strokeCount: 1)))
        await coordinator.flush(binding(5))

        let afterFailure = await store.drawingWrites
        XCTAssertTrue(afterFailure.isEmpty)
        let stillPending = await coordinator.pendingPageCount()
        XCTAssertEqual(stillPending, 1, "A write that failed must not take the ink with it.")

        await store.setFailWrites(false)
        await coordinator.flushAll()

        let afterRecovery = await store.drawingWrites
        XCTAssertEqual(afterRecovery.count, 1)
    }

    func testTheNullRecogniserNeverWritesRecognisedInk() async throws {
        let store = InkTestStore()
        let coordinator = InkPersistenceCoordinator(store: store, policy: policy)

        coordinator.record(InkChange(binding: binding(0), drawing: InkTestDrawings.drawing(strokeCount: 1)))
        await coordinator.flushAll()
        try await Task.sleep(nanoseconds: 200_000_000)

        let recognised = await store.recognisedWrites
        XCTAssertTrue(recognised.isEmpty, "A recogniser that reports itself unavailable must not be asked to do work.")
    }
}
