# 07 · Build plan

Milestones in dependency order. Each is independently demoable — if a milestone can't be
shown working end to end, it's scoped wrong.

## M0 · Shell — the reading app

*Goal: a genuinely useful offline PDF reader. No agent involvement at all.*

- Folder picker, security-scoped bookmark, `inbox/`+`outbox/` creation
- `NSFilePresenter` folder watcher; ingest for PDFs only
- SwiftData schema; library sidebar with sections, search, offline state
- **Full-download-and-pin on ingest** — copy into the app container, never leave a
  document living only in a file provider. Verify by turning the network off.
- Reader: `PDFView` continuous scroll, auto-hiding chrome, page tints, last-read position

**Ship this to yourself and use it for a week before M1.** If it isn't already worth
opening, later milestones won't rescue it.

## M1 · Markdown ingest

- `swift-markdown` → `AttributedString` → `UIGraphicsPDFRenderer`
- Annotation-friendly page geometry (wide right margin, generous leading)
- **`sourcemap.json` generation** — build it now, retrofitting is painful
- Title and metadata extraction

## M2 · Ink

- Per-page `PKCanvasView` overlay, `drawingPolicy = .pencilOnly`
- Persistence with debounce; correct behaviour under zoom and fast scroll
- `PKToolPicker` in floating form, summoned from the toolbar
- `PKStrokeRecognizer` → `Page.recognisedInk`, off the main actor, feeding search

Test hard here: several hundred strokes on one page, rapid scrolling while drawing,
rotation, and split view.

## M3 · Comments

- Anchor capture from a touch point; `AnchorResolver` with the four-step fallback
- Pencil long-press gesture; `UIPencilInteraction` squeeze as a secondary trigger
- Comment popover; press-and-hold recording model
- `SpeechAnalyzer` integration behind a protocol, with asset download on first run
- Document term list and transcript post-correction
- Scribble alternative path
- Margin markers, tap to edit, swipe to delete

## M4 · Review and send

- Review sheet: list, toggles, closing instruction, destination row
- `ReviewBundleBuilder` → `review.md`, `review.json`, `manifest.json`
  (`review.docx` is deferred to v1.1 — it needs a ZIP container and iOS has no system zip
  API; see `05-file-contracts.md`)
- `InkCropper` — bounding box union, 15% padding, page content rendered beneath
- Atomic outbox write
- `ReturnPathResolver` and the Sent screen, including the share-sheet fallback
- Reply watcher

## M5 · Share extension

- "Review" extension accepting PDFs and URLs
- Extension writes an inbox-shaped directory into `<App Group>/staging/`; the app imports
  it into the real `inbox/` on next foreground. The extension cannot write to the sync
  folder itself — the security-scoped bookmark does not cross processes
- URL handling: fetch and render, or save the reader-mode text as PDF

This is small and disproportionately valuable. Don't leave it to last if M4 slips.

## M6 · Agent integrations *(separate repo — not Swift)*

- `send-to-reader` Cowork skill, including the authoring guidance
- Claude Code MCP server: `send_to_ipad`, `list_reviews`, `get_review`
- Mac-side watcher: fires the poke trigger, or runs `claude -p … --resume` / `--cloud`
- Codex variant

The watcher's poke path is built against a command that has not been confirmed to exist
(`06-integrations.md` § Inbound, route 1). The scheduled check-in is the v1 default and
needs none of it, so M6 is not blocked — but do not ship `poke` as a sender default until
that command is real.

## Definition of done for v1

- [ ] Fully usable with the network off, from launch to a written review bundle
- [ ] Every document in the library opens with the network off, including ones added
      weeks earlier — verified after an iCloud purge, not just in airplane mode
- [ ] A document sent from Cowork is readable on the iPad within seconds, with no
      action taken by the user beyond opening the app
- [ ] A review returns into the same Cowork thread with its context intact
- [ ] A PDF shared from Safari is in the library in under three taps
- [ ] 60fps sustained while inking a page carrying 300+ strokes
- [ ] Every screen passes VoiceOver and Dynamic Type at accessibility sizes

## Rough effort

M0–M1 a weekend each; M2–M4 roughly a week each with an agent doing most of the typing;
M5 a day; M6 an evening. The long pole is M2 — ink over a scrolling, zooming PDF is where
the real bugs live.
