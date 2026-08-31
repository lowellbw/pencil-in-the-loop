# 02 · Functional spec

Screens in the order a user meets them. Visual reference: `ui/mockups.html`.

## S0 · First run

One screen, one job — and in the ordinary case nobody sees it. A build that ships pointed at
a relay (`Config/Local.xcconfig` → `RelayDefaults`) adopts it without asking: no address, no
token, no account, no onboarding carousel. First run is a status line that is gone before it
is read.

Two builds get a form instead. One made from a checkout with no `Config/Local.xcconfig`
knows the relay's address but not its token, so it asks for the token with the address
already filled in. One with neither asks for both. Settings offers the same form afterwards
(S6), and there is no dead end: the only way out of this screen is a relay, so it must always
be possible to try again.

**This screen used to settle a folder**, with the relay as the quiet second option. The
folder transport was removed in August 2026 and the two swapped places; there is now one way
to be set up, which is the point. Second run goes straight to the library.

## S1 · Library

`NavigationSplitView` sidebar. Sections: **Pinned**, then **Reviewing**, **Unread**,
**Read**. Each row:

- Title (from PDF metadata, markdown H1, or filename)
- Subtitle: origin + relative date + page count — e.g. "Cowork · 8 min ago · 4 pages"
- Trailing: offline state (downloaded / syncing) as a subtle dot, not a badge

Behaviours: search across document text *and* recognised handwriting; sort by date added
or title; group by status or by group; swipe left to archive; swipe right to pin or un-pin;
touch and hold a row to file it; pull to force a folder re-scan. Tapping a row opens the
reader in the detail column, and the sidebar collapses so the document has the screen.

**Pinned** holds whatever the user has put there, above everything else, and does not
appear at all when nothing is pinned. A pinned document is drawn there and *only* there —
never twice — but it keeps its reading state: pinning something Unread does not mark it
read, annotating a pinned document still moves it to Reviewing underneath, and un-pinning
returns it to whichever section it had reached. Pinning is therefore a place, not a state,
and it is stored as one (`Document.pinnedAt`). Pinning is not destructive and needs no
confirmation; the same swipe un-does it.

A **New Note** button in the toolbar makes a notebook rather than waiting for a document
(`11-backlog.md` § B1). **One tap, and nothing to answer first**: lined paper, eight pages,
no title, open on page one. It arrives as an ordinary document with
`origin.kind = "note"`, so everything downstream treats it as it treats any other. The
empty state offers the same one tap: with an empty library and no network it is the only
useful thing there is to do.

A pinned row is drawn on a **very light green wash**, and green is the motif for pinning
throughout — the same green tints the pin swipe, so the gesture and its result say the same
thing. A wash rather than a fill: enough to pick the shelf out of the grouped grey at a
glance, which is all it has to do, and light enough that the row still reads as a row with
its label contrast intact in both appearances. Deliberately not the accent colour: a `List`
draws selection in the accent, and a pinned row painted that way would be indistinguishable
from the document you have open. For the same reason the tint is dropped while a row is
selected, rather than two washes making a third colour that means nothing.

**The Pinned section is hand-ordered, and this reverses an earlier decision.** It used to
obey the sort menu, on the grounds that a Sort control which visibly did not apply to the
top of the list would be worse than any pin order it could impose. That was wrong about
what the section is for: Pinned is the shelf you arrange, and half a dozen documents you
chose by hand have an order in your head that neither date nor title recovers. Sort still
governs every other section, and the argument it was defending — that a control should not
appear to do nothing — is answered by the Pinned section being visibly a different kind of
thing, which the tint now makes plain. Drag a pinned row to move it.

The order is stored as the pin moments themselves, re-stamped on each drag
(`DocumentStoring.reorderPinned(_:)`), so it cost no new column and therefore no schema
migration. What it costs instead is that "when was this pinned" stops being true after the
first drag — a question nothing asks. A newly pinned document lands at the top, which is
where a new pin belongs.

**Group by** sits under Sort in the same toolbar menu, because two labelled pickers in the
menu that is already there beat a fourth control on a column this narrow. **Group** is the
default, and the choice is remembered: grouping is the reason to have filed anything, and a
library that has to be switched into it on every launch is one where the filing quietly
stops being worth doing. **Status** is the sectioning above, unchanged, one tap away, and
once tapped it sticks. A reader with nothing filed sees a single Ungrouped section, which
is the same flat list Status would have shown them. **Group** replaces the three state sections
with one section per group and an **Ungrouped** section last — last because it is the
residue rather than a group, so it never joins the ordering. Groups the reader has placed
come first, in that order; every other group follows alphabetically, so one made tomorrow
appears somewhere predictable rather than at a position nobody chose. Pinned
stays on top in both modes and a pinned document is still drawn there and only there, which
is the invariant the second sectioning had to be built around rather than beside.

Switching the picker re-draws rows already fetched. It is not part of `LibraryQuery` and
not part of the reload key: grouping changes where a row is drawn, never which rows are
read or in what order, and rows inside every section still obey the sort menu — the same
rule Pinned follows, for the same reason.

A document belongs to **at most one group**, and a group is nothing but its name. There is
no registry: naming a group creates it, and a group whose last document leaves stops
existing, so there is nothing to create and nothing to delete. Names are matched with case,
accents and punctuation ignored and shown as first written, so filing something under
"attention papers" joins "Attention Papers" rather than opening a second section beside it
(docs/05-file-contracts.md). Renaming onto a name already in use merges the two, which is
the only coherent answer when a group is identified by its name.

A document can also be filed by **dragging it onto a group's heading**, and un-filed by
dropping it on **Ungrouped** — the heading is the target because a `Section` is not a view
and has nothing to attach a drop to. Pinned rows are not draggable that way: in Pinned a
drag reorders the section, and one row cannot mean both at once, so a pinned document is
filed from its menu instead.

Each group is drawn in **its own colour** — a dot beside the heading, and a wash behind its
rows lighter than the pinned one. A dot rather than a coloured heading: section headings are
small caps in secondary grey and read as furniture, and a coloured one reads as a warning.
It is the shape Reminders and Calendar use for the same job. Ungrouped has no dot, because
it is not a group.

The colour comes from the name rather than being stored or chosen. A colour nobody picked
is one nobody has to maintain — no picker, no settings field, no migration — and a group a
sender created looks the same on every device that sees it. Renaming a group changes its
colour, which is the visible cost of that and is self-explanatory in a way a stored-but-
stale colour would not be. Green is never used, because green means pinned, and the accent
is never used, because a `List` draws selection in it.

Group **sections** are reordered from a sheet rather than by dragging their headings, and
not for want of trying: a `List` reorders rows within a `ForEach`, and a section is not a
row, so there is no in-place gesture to attach it to. "Reorder Groups…" is in the Sort menu
in Group mode and in every group heading's own menu. The order is stored against the group
*key*, so renaming a group keeps its place, and a group emptied and filled again comes back
where it was put rather than back in the alphabet.

Filing is also a **touch and hold** on the row — a Group submenu listing every group in the
library, "New Group…", and "Remove from Group". That menu offers every group rather than
the ones the current search left on screen, or it would hide the one being searched past. Not a third swipe action, because there is
no third edge and neither of the two can hold a list of names; not a new gesture, which
docs/01-design-principles.md § 5 rules out. Renaming is a touch and hold on the group's own
section header, which is where Files and Photos put it. A row shows no group of its own in
either mode: in Group mode the heading above it already says so, and in Status mode the
three-part subtitle is not worth diluting for it — the same restraint that draws no pin on
a pinned row.

A sender may propose a group in `meta.json`, which is how five papers on one subject arrive
in one section. That proposal files a document arriving for the first time and never
overrides a group the reader chose here, so a re-send cannot move something they filed by
hand.

Group membership is kept **outside the library store**, keyed by folder name
(`AppSettings.DocumentGroups`). An attribute on `Document` would have cost a
`LibrarySchemaV2` and a migration of a store holding somebody's annotations to buy one
nullable string, and nothing needs a group to be queryable — the sidebar re-sections rows
it has already fetched. The cost is that document state now lives in two places, and it is
paid deliberately.

**Show Archived** is a toggle in the same menu. Off by default and not remembered:
archiving something is how you get it out of the way, so a library that stayed opened on the
archive would undo the gesture. It is a look, not a mode. Archived documents are drawn last,
in one section, in both grouping modes — putting them back among the groups they came from
would be the opposite of what archiving asked for — and they carry no group tint and no
filing, because a document in there is not anywhere. Swipe one to **Restore**, which returns
it to Read rather than Unread: it has been in the library and been seen, and calling it
unread would claim it had just arrived.

A **New** menu in the toolbar makes a document rather than waiting for one
(`11-backlog.md` § B1): a blank notebook — plain, lined or grid paper, eight pages to
start — or a document typed as markdown and rendered by the same path as anything sent.
Both arrive as ordinary documents with `origin.kind = "note"`, so everything downstream
treats them as it treats any other. Creating one selects it, which opens the reader on
page one. The empty state offers a notebook too: with an empty library and no network it
is the only useful thing there is to do.

The three questions that used to stand in front of it — title, ruling, page count — are
all answered better from the page than before it, so that is where they are now
(§ S2): the note names itself from its first recognised sentence or is renamed from the
page menu, the ruling is changed while you are looking at it, and pages are added when you
run out.

A note's *text* still cannot be edited, and there is no longer a route that types one:
markdown written in the app was a text box that produced a document nobody could change
afterwards, which is a worse version of what an agent sends you. Rendered documents come
from the loop; the app's own paper is for handwriting. Re-rendering a document's text
would re-paginate it and strand every stroke on the page — see `00-brief.md`, which scopes
this as a review tool rather than an editor. Re-*ruling* a notebook does not: blank pages
have no reflow, so the pages come out identical and the ink stays exactly where it was.

Pull-to-refresh is not a courtesy control. File coordination does not reliably see every
change a provider makes in the background, so the sync layer polls and treats every
notification as "look again" rather than as news (`04-flows.md` § F1). Pull-to-refresh is
the same scan, on demand, and it is what the user reaches for when a document they know
was sent has not appeared yet.

The library must be fully usable with no network. Anything not yet downloaded shows as
dimmed and non-openable rather than failing on tap.

## S2 · Reader

Full-bleed continuous-scroll PDF. Chrome auto-hides on scroll, returns on tap.

**Toolbar (when visible):** Library, title, comment count, a Page menu, tool-picker toggle,
Review button.

**The Page menu** holds what the open page looks like and what it is called: Rename, the
page tint, and — for a notebook — the paper it is ruled with and Add Pages. The tint is
still one setting for the whole app; it is chosen here because this is the only screen
where the difference between Cream and Sepia is visible while it is being chosen. Re-ruling
regenerates `document.pdf` at the same page count and keeps every stroke, comment and the
reading position (`NoteCreator.setPaper`). Renaming changes the title in the library and in
`meta.json`, and never the folder name, which is the identity everything is filed under.

**A note names itself.** A notebook made in one tap is called "Note" until the handwriting
recogniser has read page one, at which point its first sentence becomes its title — once,
and only while nobody has named it. Recognition ships in iPadOS 27 and is an enhancement
everywhere (`04-flows.md` § F3), so a build or a page without it leaves the note called
"Note" and Rename is one tap away.

**Interactions:**

| Input | Result |
|---|---|
| Finger drag | Scroll. Always. |
| Pencil drag | Draw. Always. (`drawingPolicy = .pencilOnly`) |
| Pencil long-press (0.4s) on the page | Open the comment popover anchored at that point |
| Pencil Pro squeeze | Toggle: squeeze to start talking, squeeze again to stop. Anchored at the current hover point if hovering |
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

Deliberately short. The relay (address and access token), ink defaults, transcription
language, "Send inked pages as images" default, and a Storage row showing cache size with a
purge button. Nothing else.

Shorter by one row than it was: the page tint is chosen on the page it tints (§ S2). A
setting whose whole point is how something looks does not belong two taps away from the
thing it changes.

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
- Nothing may become unreadable because the relay is unreachable. Losing it costs you *new*
  documents, never existing ones — every document is pinned in the app's own container and
  opens on a plane.

Budget: a 60-page PDF is a few MB. A thousand documents is comfortably within a 128GB
iPad. There is no reason to be clever here — keep everything.

- **Everything works offline** except the initial file sync and the send-back. No feature
  shows a spinner waiting on a network.
- **Autosave always.** Ink and comments persist on every change; there is no save action
  and no unsaved state to lose.
- **Nothing is destructive without undo.** Deleting a comment is undoable for the session.
- **Cold launch to a readable page: under 1 second** for a cached document.
