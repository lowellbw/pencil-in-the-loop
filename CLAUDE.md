# CLAUDE.md

Project context for Claude Code. Read `README.md` next, then the doc for whatever
milestone you're on. Every milestone has been written but none of it has ever been
compiled — if you are heading for a build, read `FirstBuild.md` first.

## What this is

An offline-first iPadOS app for reading long-form documents — research papers, PDFs, and
markdown written by Claude — annotating them with Apple Pencil, dictating comments
anchored to specific passages, and sending the review back to the conversation the
document came from.

Full spec in `docs/`. Read `docs/07-build-plan.md` to find the current milestone, and
`docs/01-design-principles.md` before writing any view code.

## Non-negotiables

1. **Offline first.** Reading and annotating never touch the network. No feature on those
   paths may show a spinner waiting on a request.
2. **Always local.** Documents are downloaded in full and pinned into the app container
   on arrival. Never left living in a file provider, never evicted.
3. **The folder is the API.** No server, no account, no proprietary protocol. See
   `docs/05-file-contracts.md` — those formats are a public contract, don't change them
   casually.
4. **One mode.** Finger scrolls, Pencil draws (`drawingPolicy = .pencilOnly`). The user
   never switches tools to annotate.
5. **Anchors are quoted text, never line numbers.** Documents get regenerated.
6. **It should look like Apple made it.** System fonts, SF Symbols, system colours,
   standard containers. If a screen looks designed, it's wrong.

## Stack

Swift 6 with strict concurrency, SwiftUI, iPadOS 26.0 minimum
(`IPHONEOS_DEPLOYMENT_TARGET` in `Config/Shared.xcconfig`). **No third-party
dependencies.** Everything needed is a system framework: PDFKit, PencilKit, Speech,
SwiftData, swift-markdown.

`PKStrokeRecognizer` — handwriting to text, on device, 29 languages — is public in iPadOS
27, which is above the floor. The engine that uses it compiles only when
`PENCILLOOP_STROKE_RECOGNIZER` is defined (off by default in `Package.swift`) and runs only
under `#available(iOS 27, *)`; everything else holds `any HandwritingRecognising` and gets
an implementation that declines without throwing. So the app builds and runs on a 26 SDK,
and lights recognition up where it exists. Strokes are captured, persisted and exported as
images regardless — recognition is an enhancement, never a dependency. Raising the floor to
27.0 and defining the flag are one commit, not two.

`Core/` and `Storage/` must not import SwiftUI or UIKit.

## Working agreements

- **Ask rather than guess** on anything in `docs/08-open-questions.md`.
- **Build in milestone order.** M0 is a genuinely useful offline PDF reader with no agent
  involvement at all. Get that working and usable before touching ink.
- Prefer small, verifiable commits. After each, say what you'd test by hand on device —
  much of this (Pencil input, hover, squeeze, transcription) can't be unit tested.
- When something in the spec turns out to be wrong or impossible, **update the doc in the
  same commit** rather than silently diverging. The spec is the source of truth and it
  should stay true.
- Performance targets in `docs/03-architecture.md` are requirements, not aspirations.
  The ink path especially: do no work on the touch path.

## Known hard parts

Read `docs/03-architecture.md` § "The four hard parts" before starting M1 or M2. The long
pole is ink over a scrolling, zooming PDF — one `PKCanvasView` per page, recycled with the
page views, never one canvas over the whole scroll view.

## Simulator caveat

Apple Pencil input, hover, and squeeze cannot be tested in the Simulator, and
`PKStrokeRecognizer` is Latin-only there. Anything touching Pencil needs a real device.
