# 02 · Functional spec

Screens in the order a user meets them. Visual reference: `ui/mockups.html`.

## S0 · First run

One screen, one job: pick the sync folder. A short line of explanation, a "Choose
Folder…" button opening `fileImporter`, and nothing else. Store a security-scoped
bookmark. Create `inbox/` and `outbox/` inside it if absent.

No account, no login, no onboarding carousel. Second run goes straight to the library.

## S1 · Library

`NavigationSplitView` sidebar. Sections: **Reviewing**, **Unread**, **Read**. Each row:

- Title (from PDF metadata, markdown H1, or filename)
- Subtitle: origin + relative date + page count — e.g. "Cowork · 8 min ago · 4 pages"
- Trailing: offline state (downloaded / syncing) as a subtle dot, not a badge

Behaviours: search across document text *and* recognised handwriting; sort by date added
or title; swipe to archive; pull to force a folder re-scan. Tapping a row opens the reader
in the detail column, and the sidebar collapses so the document has the screen.

A **New** menu in the toolbar makes a document rather than waiting for one
(`11-backlog.md` § B1): a blank notebook — plain, lined or grid paper, eight pages to
start — or a document typed as markdown and rendered by the same path as anything sent.
Both arrive as ordinary documents with `origin.kind = "note"`, so everything downstream
treats them as it treats any other. Creating one selects it, which opens the reader on
page one. The empty state offers a notebook too: with an empty library and no network it
is the only useful thing there is to do.

Neither can be edited afterwards. Re-rendering would re-paginate and strand every stroke
already on the page — see `00-brief.md`, which scopes this as a review tool rather than an
editor.

Pull-to-refresh is not a courtesy control. File coordination does not reliably see every
change a provider makes in the background, so the sync layer polls and treats every
notification as "look again" rather than as news (`04-flows.md` § F1). Pull-to-refresh is
the same scan, on demand, and it is what the user reaches for when a document they know
was sent has not appeared yet.

The library must be fully usable with no network. Anything not yet downloaded shows as
dimmed and non-openable rather than failing on tap.

## S2 · Reader

Full-bleed continuous-scroll PDF. Chrome auto-hides on scroll, returns on tap.

**Toolbar (when visible):** back, title, comment count, tool-picker toggle, Review button.

**Interactions:**

| Input | Result |
|---|---|
| Finger drag | Scroll. Always. |
| Pencil drag | Draw. Always. (`drawingPolicy = .pencilOnly`) |
| Pencil long-press (0.4s) on the page | Open the comment popover anchored at that point |
| Pencil Pro squeeze | Same as long-press, at the current hover point if hovering |
| Finger long-press on text | Standard iOS text selection → "Comment" in the menu |
| Tap a comment marker | Open that comment for review or deletion |
| Two-finger tap | Undo (system standard) |

**Comment markers** sit in the page margin at the vertical position of their anchor.

**The long-press is a stroke until it isn't.** A Pencil held still for 0.4s is, as far as
`PKCanvasView` is concerned, a perfectly good stroke — a dot — and it has already been
drawn by the time the press is recognised. The obvious fix, delaying touch delivery to the
canvas until the gesture resolves, is not available: it puts work on the touch path, which
`03-architecture.md` forbids outright. Ink latency is the one budget with no slack in it.

So the approach is the other way round: let the dot be drawn, and take it back. A
pencil-only `UILongPressGestureRecognizer` sits alongside the canvas, does not delay or
cancel its touches, and on recognition cancels the in-flight stroke — the canvas keeps
receiving touches at full speed, and a comment gesture removes the dot it started as. The
0.4s threshold and the 0.3s minimum hold live in `Core` so the recogniser and the recording
state machine cannot drift apart.

Two things about this only a device will tell you: whether the dot is visible for long
enough to register as a glitch, and whether 0.4s is the right threshold with a real hand
resting on a real screen. **This is the top item on the device-iteration list.** Expect to
change the number, and possibly to fade the cancelled stroke out rather than removing it.

## S3 · Comment popover

Appears anchored to the touch point. Contents, top to bottom:

1. The captured anchor as a quoted excerpt, one or two lines, truncated with an ellipsis.
2. A live waveform while recording.
3. The transcript, appearing as you speak.
4. A hint row: "**Hold** to talk" and "✎ scribble instead".

**Recording model:** press and hold. Releasing saves. This is deliberate — it removes a
stop button, matches the physical gesture, and makes short comments effortless. A lift of
under 0.3s is treated as a mis-touch and discards.

**Scribble alternative:** tapping the hint switches the popover to a handwriting field
(system Scribble) for silent environments. Same anchor, same storage.

**Anchor capture:** the nearest text selection to the touch point, expanded to a sensible
unit — a sentence if one is identifiable, otherwise the line. Store the selected string
plus 32 characters of context either side, the page index, and a normalised rect.

## S4 · Review sheet

Opened by the Review button. A `.large` sheet.

- Header: "*n* comments, *m* inked pages" and a subtitle with the document title and time
  spent.
- A list of comments in document order. Each row: marker, quoted excerpt (dimmed, one
  line), the comment text, and a small source line — "voice · on-device" or "handwriting ·
  recognised". Swipe to delete. Tap to edit the text.
- **Include** toggles: Comments, Inked pages, Recognised text, Full document. First three
  on by default.
- **Closing instruction**: a multi-line text field. Placeholder: "Anything to add?"
  Dictation available via the standard keyboard mic.
- **Destination row**: origin name, thread title, session id, and a badge reading either
  SAME THREAD or NEW THREAD. This must be visible before sending — it is the only place
  the user learns whether context is preserved.
- **Send** button, prominent, full width.

## S5 · Sent

A confirmation with the resolved return path named explicitly, a small progress timeline
(bundle written → picked up → agent working), and, when it arrives, the agent's reply
inline with an option to open it as a new document.

If no return path resolved, this screen instead offers: "Copy review", "Share…" (which
routes to the Claude app share sheet — see `06-integrations.md`), and "Save to folder".
Never a dead end.

## S6 · Settings

Deliberately short. Sync folder (change), page tint, ink defaults, transcription language,
"Send inked pages as images" default, and a Storage row showing cache size with a purge
button. Nothing else.

## Cross-cutting requirements

### Everything is always local — this is a hard requirement, not a cache

Documents are **downloaded in full on arrival and pinned**. They are not fetched on
demand, not thumbnails-until-tapped, and never evicted by the system.

- On ingest, materialise the complete file locally
  (`NSFileCoordinator` + `startDownloadingUbiquitousItem`, then verify) before the row
  becomes tappable.
- Mark every document directory `isExcludedFromBackup = false` and, critically, **do not
  rely on a provider's on-demand eviction** — copy into the app's own container. A
  document that lives only in a file provider is one iCloud purge away from being a
  spinner on a plane, which defeats the entire point.
- The library shows a per-document local state, and Settings shows total storage with a
  purge control. The user decides what leaves the device; the system never does.
- Nothing may become unreadable because the sync folder is unreachable. Losing the folder
  costs you *new* documents, never existing ones.

Budget: a 60-page PDF is a few MB. A thousand documents is comfortably within a 128GB
iPad. There is no reason to be clever here — keep everything.

- **Everything works offline** except the initial file sync and the send-back. No feature
  shows a spinner waiting on a network.
- **Autosave always.** Ink and comments persist on every change; there is no save action
  and no unsaved state to lose.
- **Nothing is destructive without undo.** Deleting a comment is undoable for the session.
- **Cold launch to a readable page: under 1 second** for a cached document.
