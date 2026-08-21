# 03 · Architecture

## Stack

- Swift 6, strict concurrency. SwiftUI. iPadOS 26.0 minimum. Handwriting recognition
  needs 27 and is compiled behind a flag, so it is an enhancement and never a dependency.
- **No third-party dependencies.** Everything below is a system framework.
- Targets: the app, a **share extension**, and a shared framework for the model layer.
  App Group for the shared container.

| Concern | Framework |
|---|---|
| Rendering, pagination, text selection | PDFKit |
| Ink capture | PencilKit (`PKCanvasView`, `PKDrawing`, `PKToolPicker`) |
| Handwriting → text | PencilKit (`PKStrokeRecognizer`, iPadOS 27, availability-guarded) |
| Voice → text | Speech (`SpeechAnalyzer`, `SpeechTranscriber`) |
| Markdown parsing | `swift-markdown` (Apple, first-party) |
| md → PDF | `UIGraphicsPDFRenderer` over an `NSAttributedString` |
| Library index | SwiftData |
| Folder access & watching | `fileImporter`, security-scoped bookmarks, `NSFileCoordinator` + `NSFilePresenter` |
| Pencil gestures | `UIPencilInteraction` (squeeze), `UIHoverGestureRecognizer` |

**Deployment floor.** `IPHONEOS_DEPLOYMENT_TARGET = 26.0`. `PKStrokeRecognizer` is public
in iPadOS 27 — an on-device Swift actor covering 29 languages — so the engine built on it
compiles only when `PENCILLOOP_STROKE_RECOGNIZER` is defined and runs only under
`#available(iOS 27, *)`. Every other module holds `any HandwritingRecognising` and, on a
build or a device without it, gets an implementation that declines everything without
throwing. Ink is captured, persisted and exported as images either way; recognition only
makes it searchable. Raising the floor to 27.0 in `Config/Shared.xcconfig` and defining the
flag are one commit, not two.

## Module layout

```
PencilLoopKit/Sources/
├─ Core/            models, anchors, ID types, protocols — Foundation only
├─ Storage/         SwiftData schema, file layout, bookmark management
├─ Sync/            folder watcher, inbox scanner, outbox writer
├─ Ingest/          MarkdownRenderer, PDFImporter, MetadataExtractor
├─ Annotate/        InkLayer, AnchorResolver, VoiceRecorder, HandwritingRecogniser
├─ Export/          ReviewBundleBuilder, InkCropper, ReturnPathResolver
└─ AppUI/           Library, Reader, CommentPopover, ReviewSheet, Settings
```

The two app shells — `Apps/PencilLoop` and `Apps/ReviewShareExtension` — are about forty
lines between them and hold no logic; everything is in the package.

`Core` and `Storage` must not import SwiftUI or UIKit. Everything else may. `Sync` depends
on `Core` alone and reaches the library through `DocumentStoring`, which is what keeps
SwiftData out of the product the share extension links.

Beyond the model types below, `Core` holds the protocols every module is written against —
`DocumentStoring`, `DocumentIngesting`, `InboxScanning`, `SyncCoordinating`,
`FolderAccessing`, `SettingsStoring`, `SpeechTranscribing`, `TranscriptCorrecting`,
`HandwritingRecognising`, `InkCropping`, `ReviewBundleBuilding` — along with
`PencilLoopError`, the `FolderEvent`/`SyncEvent` streams, `ContractCoding` (one encoder
configuration, so two modules cannot spell the same JSON differently), `Slug`,
`DocumentFileNames` and `DocumentContainer` (the file names from `05-file-contracts.md` and
the container layout, spelled once), and `GestureTiming` (the 0.4s long-press and the 0.3s
minimum hold, shared by the recogniser and the recording state machine). A module that
needs a type another module owns is a module that needs a contract in `Core`.

## Data model

```swift
@Model final class Document {
  var id: UUID
  var title: String
  var addedAt: Date
  var origin: Origin              // see 05-file-contracts.md
  var folderPath: String          // relative to the sync root
  var pageCount: Int
  var state: DocState             // .unread .reviewing .read .archived
  var extractedText: String       // for search
  @Relationship var pages: [Page]
  @Relationship var comments: [Comment]
}

@Model final class Page {
  var index: Int
  var drawingData: Data?          // PKDrawing
  var recognisedInk: String?      // PKStrokeRecognizer output, for search
  var hasInk: Bool
}

@Model final class Comment {
  var id: UUID
  var createdAt: Date
  var text: String
  var source: CommentSource       // .voice .handwriting .typed
  var anchor: Anchor
  var resolvedOnPage: Int
}

struct Anchor: Codable {
  var quoted: String              // the selected text
  var prefix: String              // 32 chars before
  var suffix: String              // 32 chars after
  var pageIndex: Int
  var normalisedRect: NormalisedRect  // fallback when text matching fails
  var sourceRange: SourceRange?       // into source.md, when a source map exists
}
```

`NormalisedRect` and `SourceRange` are `Core` types, not `CGRect` and `Range<Int>`. Both
exist because the on-disk shape wins: `05-file-contracts.md` shows four-element and
two-element JSON arrays, and both Foundation types encode as keyed objects instead. Their
units are frozen — see `05-file-contracts.md` § Units and coordinate spaces, which is the
one place to read before converting anything.

## The four hard parts

### 1 · Markdown → PDF with a source map

The whole architecture rests on freezing layout at ingest. Parse with `swift-markdown`,
build an `AttributedString`, render page by page with `UIGraphicsPDFRenderer` at a fixed
page size: A4 portrait (595.276 × 841.89pt), 11pt body on 1.35 leading, 56pt margins at
the top, left and bottom — and **140pt on the right**.

**While rendering, record a source map**: for each laid-out text run, store
`(pageIndex, rect) → range in the original markdown`. Persist as `sourcemap.json`.

This is what lets a comment anchored on a rendered page resolve back to a character range
in the markdown Claude actually wrote. Without it you only have the quoted string — which
is still workable, but the source map makes the round trip precise. **Build it in M1, not
as an afterthought.**

#### The right margin is the product

The 140pt right margin is the feature, not generosity. It leaves a 399.3pt text column and
a strip of empty page beside every line, and that strip is where handwriting goes: a margin
note sits next to the sentence it is about, and an arrow has somewhere to start. A page set
for density has nowhere to write on, so the note ends up in a separate app — which is the
failure this whole thing exists to remove. Everything else about the page follows from the
same choice: generous leading, short measure, nothing running edge to edge.

`PageGeometry.annotationFriendly` in `Core` is the only place these numbers live. The
renderer, the ink cropper and the source map all derive from it, so none of them can
disagree about how big anything is.

#### Code blocks do not fit, and the fix is provisional

`06-integrations.md` tells Claude to keep code under about 76 characters so nothing wraps
on an A4 page. Against a 399.3pt column that is not true: 76 monospaced characters need
roughly 456pt at 10pt, and only about 66 fit. Ingest resolves it by measuring the
monospaced advance and scaling the code font down until the promised 76 fit — about 8.75pt
against an 11pt body. Nothing wraps, nothing overflows, and code reads noticeably smaller
than the prose around it.

Whether 8.75pt is *legible* is a judgement about a physical page held at arm's length, and
it cannot be made in a simulator or from a screenshot. Read a code-heavy document on the
iPad before treating this as settled. If it is too small there are two honest ways out and
they trade against each other: narrow the right margin — about 83pt would fit 76 characters
at 10pt, at the cost of 57pt of the writing strip — or lower `maxCodeColumnCharacters` to
66 and change the same number in `06-integrations.md`'s authoring guidance, which is what
Claude is actually told. Changing one without the other puts the promise back where it
started.

### 2 · Ink over a scrolling PDF

One `PKCanvasView` per visible page, sized to that page's bounds, added as an overlay on
the `PDFPage`'s view. Do **not** use a single canvas over the whole scroll view — it
breaks at length and drifts on zoom.

- Recycle canvases with the page views; persist `PKDrawing` on `canvasViewDrawingDidChange`
  after a 500ms debounce.
- On zoom, scale the canvas transform with the page, never re-render the strokes.
- `drawingPolicy = .pencilOnly` so finger touches fall through to the scroll view.

Watch for: strokes lagging past a few hundred per page (split into render groups), and
canvas re-entrancy during rapid scrolling.

### 3 · Anchor resolution

When writing the review, and when the agent later re-resolves it:

1. **Exact match** on `prefix + quoted + suffix` in the source text. Almost always hits.
2. **Exact match** on `quoted` alone.
3. **Fuzzy match** on `quoted` — normalised whitespace, Levenshtein within 15%.
4. **Fallback**: page index + normalised rect, reported as approximate.

Never emit a line number as the primary anchor. Include it as a hint only.

### 4 · On-device speech

`SpeechAnalyzer` with `SpeechTranscriber`. Language assets download once via the system
asset catalog — trigger this on first run, in the background, and surface a one-line
Settings row if it hasn't completed. After that, no network.

**Jargon:** `SpeechAnalyzer` has no vocabulary-biasing API. Post-process instead — build a
term list from the document (identifiers, capitalised nouns, code spans, title words) and
fuzzy-correct transcript tokens against it. Cheap, effective, and it works regardless of
which recogniser is used. If accuracy is still poor, `SFSpeechRecognizer` with
`requiresOnDeviceRecognition = true` accepts ~100 `contextualStrings`; keep it as a
fallback path behind a protocol so either engine can be swapped in.

**The fallback is also what covers the download.** `SpeechAnalyzer` refuses a recording
outright until its language model is on the device, which on a fresh install is the first
few holds — and "the dictation model is still downloading" is indistinguishable, to
somebody holding a Pencil, from dictation being broken. So `SpeechEngineFactory` chooses
`SFSpeechRecognizer` while the analyser's model is missing and iOS has already provisioned
the fallback's, and the analyser once its assets land. The download still starts; it just
no longer costs the user the comment they were speaking.

**Ending a recording is not a failure.** Stopping an engine finishes its stream normally,
so "the stream finished" alone cannot tell a released hold apart from a recogniser that
died mid-sentence. Every consumer of `SpeechTranscribing` must know which of the two it is
looking at before it reports anything — the review sheet by a stopping flag it sets before
it calls `stop()`, the comment popover by `VoiceRecordingMachine`'s phase.

## Performance targets

| | Target |
|---|---|
| Cold launch to readable page (cached) | < 1s |
| Page turn / scroll | 60fps sustained, no dropped frames while inking |
| Ink latency | Whatever the display allows — do no work on the touch path |
| Voice transcript first token | < 400ms from press |
| Handwriting recognition per page | < 500ms, off the main actor |
| Review bundle write | < 2s for a 50-page document with 20 comments |
