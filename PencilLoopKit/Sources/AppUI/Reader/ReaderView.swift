//
//  ReaderView.swift
//  AppUI · Reader
//
//  S2. The reader: a full-bleed continuous-scroll PDF with chrome that hides on
//  scroll and comes back on tap, exactly like Books
//  (docs/01-design-principles.md § 4, docs/02-spec.md § S2).
//
//  What this file does is arrange four layers and a toolbar. The page is
//  `ReaderDocumentView`, the ink is `PageCanvasPool` behind it, the wash is a
//  multiply-blended rectangle over it, and the markers are the comment unit's
//  dots placed in the reader's coordinate space. The comment popover is the
//  comment unit's own modifier, applied here to the page host view because that
//  is the one space every point in this feature is measured in.
//

import PDFKit
import SwiftUI
import Core

/// The reader.
///
/// **On failure:** a document that cannot be opened shows one sentence
/// (`ReaderUnavailableView`) with the toolbar still working, so the way out is
/// where it always is. Nothing in this screen waits on the network, and nothing
/// in it can fail in a way that costs the reader their ink: the autosave is a
/// debounce inside `InkPersistenceCoordinator`, and it is flushed on close, on
/// backgrounding, and by `InkLifecycleObserver` on the way to suspension.
public struct ReaderView: View {

    private let environment: any AppEnvironment
    private let documentId: UUID
    private let placeholderTitle: String
    private let onBack: (() -> Void)?
    private let onDocumentChanged: () -> Void
    private let onReview: (UUID) -> Void

    @Environment(\.scenePhase) private var scenePhase
    @State private var model = ReaderModel()

    /// - Parameters:
    ///   - environment: the one route to every dependency. Passed in rather than
    ///     read from the SwiftUI environment because the key that would carry it
    ///     is not declared yet — see this unit's report.
    ///   - documentId: the row the library selected.
    ///   - title: what the toolbar says until the store answers. The library
    ///     already knows it, and a title that appears a beat after the page has
    ///     is a beat of nothing at the top of the screen.
    ///   - onBack: a back button, for a container that does not supply one. In
    ///     the app's `NavigationSplitView` the sidebar is the way back, so this
    ///     is normally nil.
    ///   - onDocumentChanged: called when a comment or the ink has reached the
    ///     store, so a library beside this reader can re-read the row
    ///     (`LibraryReloadSignal`). Says nothing about what changed. A container
    ///     with no library to refresh leaves it out.
    ///   - onReview: the Review button. The review sheet is another unit's
    ///     screen and another unit's decision about how to present it.
    public init(
        environment: any AppEnvironment,
        documentId: UUID,
        title: String = "",
        onBack: (() -> Void)? = nil,
        onDocumentChanged: @escaping () -> Void = {},
        onReview: @escaping (UUID) -> Void = { _ in }
    ) {
        self.environment = environment
        self.documentId = documentId
        self.placeholderTitle = title
        self.onBack = onBack
        self.onDocumentChanged = onDocumentChanged
        self.onReview = onReview
    }

    public var body: some View {
        ZStack {
            Color(uiColor: .secondarySystemBackground)
                .ignoresSafeArea()

            if let message = self.model.unavailableMessage {
                ReaderUnavailableView(message: message)
            }

            if self.model.isReady, let capture = self.model.capture {
                ReaderDocumentView(model: self.model)
                    .ignoresSafeArea()
                    .overlay {
                        self.pageOverlays
                    }
                    // The popover belongs to the comment unit; where it points
                    // belongs to the reader. Applying the modifier here — to the
                    // page host, and to nothing else — is what makes those the
                    // same coordinate space (Comment/Views/CommentSurface.swift).
                    .commentCapture(capture)
                    .compositingGroup()
            }
        }
        .navigationTitle(self.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            self.toolbarContent
        }
        .toolbarVisibility(self.model.isChromeVisible ? .visible : .hidden, for: .navigationBar)
        .persistentSystemOverlays(self.model.isChromeVisible ? .automatic : .hidden)
        .task(id: self.documentId) {
            // Set before the open: the comment capture is built inside it and
            // takes its own hook from this one.
            self.model.onDocumentChanged = self.onDocumentChanged
            await self.model.open(documentId: self.documentId, environment: self.environment)

            // Runs until the view goes away, then falls through to close, which
            // is what flushes the last strokes and the last minute of reading.
            await self.model.trackReadingTime()
            await self.model.close()
        }
        .onChange(of: self.scenePhase) { _, phase in
            Task {
                await self.model.noteActive(phase == .active)
            }
        }
    }

    // MARK: - Layers

    /// Everything drawn on top of the page, in the page's own coordinate space.
    ///
    /// An `.overlay` rather than another member of the `ZStack` on purpose: an
    /// overlay is laid out in exactly the modified view's frame, so a point in
    /// here is the same point in the `PDFView`, which is what
    /// `CommentPageResolving` promises about every rect it returns.
    private var pageOverlays: some View {
        ZStack {
            if self.wash.isVisible {
                // Render the page and tint it; never invert it
                // (docs/01-design-principles.md § 9). Multiply leaves black text
                // black and turns a white page the colour of the wash, which is
                // what paper does and what inversion does not.
                Rectangle()
                    .fill(self.wash.fill.opacity(self.wash.opacity))
                    .blendMode(.multiply)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }

            // Above the wash: markers are chrome, not page content, and the
            // accent colour is the accent colour on every tint.
            ReaderMarkerLayer(model: self.model)
        }
        // Fill the overlay whatever is in it. A `ZStack` sizes itself to its
        // children, and a marker placed with `.position` inside a collapsed
        // stack is placed against the wrong rectangle.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Toolbar

    /// Back, title, comment count, tool picker, Review (docs/02-spec.md § S2).
    /// A standard `.toolbar`, not a hand-rolled bar
    /// (docs/01-design-principles.md § 3).
    /// How many sheets one press adds.
    ///
    /// The same number a new notebook starts with, so running out and pressing
    /// this feels like turning to a fresh signature rather than rationing.
    private static let pagesPerAddition = 8

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if let onBack = self.onBack {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    onBack()
                } label: {
                    Label("Library", systemImage: "chevron.backward")
                }
                .accessibilityLabel("Library")
            }
        }

        ToolbarItem(placement: .topBarTrailing) {
            Label(self.model.commentCount.formatted(), systemImage: "bubble.left")
                .labelStyle(.titleAndIcon)
                .font(.body)
                .foregroundStyle(.secondary)
                .accessibilityLabel(self.commentCountLabel)
        }

        // Only for a notebook. There is no sensible meaning to appending blank
        // paper to a document somebody sent you, so the button is not there at
        // all rather than there and refusing.
        if self.model.canAddPages {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task {
                        await self.model.addPages(
                            ReaderView.pagesPerAddition, environment: self.environment
                        )
                    }
                } label: {
                    Label("Add Pages", systemImage: "plus.rectangle.on.rectangle")
                }
                .accessibilityLabel("Add \(ReaderView.pagesPerAddition) more pages")
            }
        }

        ToolbarItem(placement: .topBarTrailing) {
            Button {
                self.model.toggleToolPicker()
            } label: {
                Label("Markup", systemImage: "pencil.tip.crop.circle")
            }
            .disabled(self.model.isReady == false)
            .accessibilityLabel(self.model.isToolPickerVisible ? "Hide markup tools" : "Show markup tools")
        }

        ToolbarItem(placement: .topBarTrailing) {
            Button("Review") {
                self.onReview(self.documentId)
            }
            .disabled(self.model.isReady == false)
        }
    }

    // MARK: - Derived

    private var title: String {
        self.model.detail?.title ?? self.placeholderTitle
    }

    private var wash: ReaderTintWash {
        ReaderTintWash.wash(for: self.model.pageTint)
    }

    private var commentCountLabel: String {
        self.model.commentCount == 1 ? "1 comment" : "\(self.model.commentCount) comments"
    }
}

#Preview("Reader") {
    NavigationStack {
        ReaderView(
            environment: PreviewEnvironment(detail: ReaderPreviewSample.detail()),
            documentId: ReaderPreviewSample.documentId,
            title: "Auth refactor plan"
        )
    }
}

#Preview("Sepia") {
    NavigationStack {
        ReaderView(
            environment: PreviewEnvironment(
                detail: ReaderPreviewSample.detail(),
                settings: AppSettings(pageTint: .sepia)
            ),
            documentId: ReaderPreviewSample.documentId,
            title: "Auth refactor plan"
        )
    }
}

#Preview("No file") {
    NavigationStack {
        ReaderView(
            environment: PreviewEnvironment(
                detail: DocumentDetail(
                    id: ReaderPreviewSample.documentId,
                    title: "Q3 platform postmortem",
                    folderName: "2026-08-07-q3-platform-postmortem",
                    pdfURL: nil,
                    pageCount: 0,
                    state: .unread,
                    origin: .manual,
                    addedAt: Date(timeIntervalSince1970: 1_786_000_000),
                    lastReadPage: 0,
                    extractedText: "",
                    pages: [],
                    comments: []
                )
            ),
            documentId: ReaderPreviewSample.documentId,
            title: "Q3 platform postmortem"
        )
    }
}
