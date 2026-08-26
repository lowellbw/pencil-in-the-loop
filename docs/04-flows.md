# 04 · Flows

## F1 · Ingest

```
   source writes inbox/<slug>/
                 │
                 ▼
   poll every 15s ──or── NSFilePresenter says "now"
                 │
                 ▼
   scan inbox/ — which directories are new or changed?
                 │
                 ▼
   download and pin into the app container, then verify
                 │
                 ▼
        is there a document.pdf?
          │yes                  │no
          ▼                     ▼
   use it directly     render source.md → PDF
          │            + emit sourcemap.json
          └───────────┬─────────┘
                      ▼
     extract title, page count, full text
                      ▼
        insert Document, state = .unread
                      ▼
           appears in library sidebar
```

**The poll is the mechanism; the presenter only shortens the wait.** The sync folder is a
file-provider folder, and a provider materialises a directory entry before the bytes behind
it exist, delivers files in transfer order rather than write order, and can say nothing at
all for an item that was evicted and later re-downloaded. So the watcher asks the only
question that survives that — *what is in the folder now, and is it different from last
time?* — on a 15-second timer, and an `NSFilePresenter` callback does one thing: ask for
that scan now instead of in fifteen seconds. Nothing reads the callback's arguments and a
callback that never arrives costs latency and nothing else. Pull-to-refresh is a third
entry point into the same scan. Duplicate events are free; missed ones are not.

**Download-and-pin sits between the scan and ingest, and is not optional.** A
file-provider URL is a promise that bytes can be fetched, not a file. So: start the
download, wait until the item reports itself downloaded *and* has a size, read it under
coordination, copy it into the app's own container, compare the copied byte count against
the size the provider reported, and write the snapshot sidecar last so a directory without
one is recognisably half-copied and gets redone. Only then may the document become
openable. This is `02-spec.md` § "Everything is always local" made real; skipping it makes
the library a set of spinners the first time iCloud purges.

Sources: Cowork skill · Claude Code MCP · share extension · manual drop.
All four converge on the same folder write. There is one ingest path, not four.

Failure handling: a malformed `meta.json` must never block ingest — fall back to filename
as title and `origin.kind = "manual"`. Nothing in `meta.json` is required for a document to
be readable, and decoding it cannot throw. A document that can't be rendered shows in the
library with an error row rather than vanishing.

## F2 · Read

Tap row → reader opens at last read position → chrome auto-hides on first scroll.
State moves `.unread → .reviewing` on the first annotation, not on open.

## F3 · Ink

```
Pencil touches page
      ▼
PKCanvasView receives it (finger touches fall through to scroll)
      ▼
stroke committed → canvasViewDrawingDidChange
      ▼
debounce 500ms → persist PKDrawing to Page.drawingData
      ▼
background: PKStrokeRecognizer → Page.recognisedInk (for search + export)
```

Recognition runs off the main actor and never blocks drawing. If it fails — or is absent,
on a build or a device below iPadOS 27 — the ink is still captured and still exported as an
image. Recognition is an enhancement, never a dependency.

## F4 · Voice comment

```
Pencil long-press (0.4s) ──or── Pencil Pro squeeze
      ▼
capture anchor at touch point (nearest sentence, else line)
      ▼
haptic .light · popover appears showing the quoted excerpt
      ▼
SpeechAnalyzer starts · waveform animates · transcript streams in
      ▼
long-press: user releases · squeeze: user squeezes again
      │
      ├─ recorded < 0.3s ──▶ discard (mis-touch), no marker
      │
      └─ recorded ≥ 0.3s ──▶ post-process transcript against document term list
                          ▼
                     save Comment · haptic .success · marker appears in margin
```

**The two triggers end differently, and must.** A long press is held, so releasing
ends it. A squeeze is not: the system recognises a squeeze rather than reporting a
sensor, and it ends a sustained one on its own — a recording begun by holding a
squeeze died a few seconds in, with the squeeze still held. So a squeeze toggles,
and nothing in the app depends on one being held. The 0.3s mis-touch rule is
unchanged and still measures how little was said, not how it was triggered.

Scribble variant: tapping "✎ scribble instead" swaps the popover body for a Scribble
field. Identical anchor, identical storage, `source = .handwriting`.

## F5 · Review and send

```
Review button
      ▼
sheet: comments in document order, include toggles, closing instruction
      ▼
ReturnPathResolver reads meta.json origin
      │
      ├─ cowork + poke trigger   ──▶ "SAME THREAD"  (fire trigger)
      ├─ cowork + checkin        ──▶ "SAME THREAD"  (session picks it up)
      ├─ claude-code + cloud     ──▶ "SAME THREAD"  (claude --cloud … -p)
      ├─ claude-code + local     ──▶ "SAME THREAD"  (claude -p … --resume)
      └─ share / manual / none   ──▶ "NEW THREAD"   (share sheet fallback)
      ▼
destination row shows the resolved path — user sees it before committing
      ▼
Send
      ▼
build bundle: review.md · review.json · cropped ink PNGs · manifest.json
      ▼
write to outbox/ atomically (temp dir, then rename)
      ▼
Sent screen · state → .read
```

Atomic write matters: a watcher on the other side must never see a half-written bundle.
Write to a sibling `.tmp` directory and rename.

## F6 · Reply

```
agent writes outbox/<slug>.review/reply.md
      ▼
watcher fires → Sent screen shows the reply inline
      ▼
"Open as document" ──▶ ingests it as a new inbox item, origin inherited
```

That last step is what turns a single review into an ongoing loop — the reply is itself
annotatable, with the thread context carried forward.

## F7 · Offline

Every step above except the first sync and the outbox write works with no connection.

- Documents already downloaded open instantly.
- Ink, voice transcription and handwriting recognition are all on-device. A voice comment
  queues its recording for a better transcript when there is a network, and keeps the
  on-device one when there is not — the comment is saved either way, before the queue is
  touched (`notes/pencil-loop-cloud-dictation.md`).
- The bundle is written locally and syncs whenever the connection returns; the Sent
  screen says "will send when online" rather than failing.
- Search covers cached text and recognised ink, offline.

Nothing in the reading or annotating path may show a network spinner. If a feature can't
meet that, it doesn't ship in v1.
