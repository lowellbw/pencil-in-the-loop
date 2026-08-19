# 11 · Backlog

Ideas not in v1, and the reasoning that would decide them. Nothing here is
committed. An idea earns its way into a milestone by being written up properly —
what it is, why it belongs in *this* app rather than a different one, and what it
costs — not by being mentioned.

Order within each section is rough priority, not sequence.

---

## Writing, not just annotating

The strongest theme so far, and the one that changes what the app *is*. v1
assumes every mark sits on top of a document somebody else wrote. That covers
review, and it misses the case where reading produces thinking that needs
somewhere to go.

### B1 · Notes — blank paper, in the app — **shipped**

Start a note without a document. Plain, lined or grid paper, Pencil, nothing
else. Kept here rather than deleted, because the reasoning is what the
implementation is built on and the open question below has an answer now.

This was not a feature so much as a removal of an assumption: the app already
had the whole ink stack — per-page canvases, `.pencilOnly`, autosave,
handwriting recognition, page tints. A note is that stack with a generated
blank page instead of a rendered one.

- **Cost:** low, as estimated. `BlankPaperRenderer` in `Ingest`, `NoteCreator`
  beside `DocumentIngestor`, `OriginKind.note`, and a New menu in the library.
  The reader, ink layer, search and export needed no changes at all.
- **Paper styles:** plain, lined, grid. Rendered *into* the page, so ink can
  never drift relative to the rule lines, exactly as with document text. Ruled
  at 28pt and gridded at 5mm — a handwriting measure, not the 11pt text
  leading.
- **Also shipped, beyond the original write-up:** a typed route. Markdown
  written in the app goes through `MarkdownPDFRenderer`, so it arrives with a
  source map and real quoted anchors rather than the rect-only ones blank paper
  falls back to. And `PageGeometry.notebook` — `annotationFriendly`'s 140pt
  marginalia gutter exists so handwriting can go beside somebody else's text;
  on a blank page the handwriting *is* the text.
- **Deliberately not shipped:** editing a note after it is made. Re-rendering
  re-paginates, and `DocumentStore.apply` keeps the marks when the source is
  regenerated, so every stroke would be stranded a line or two from where it
  was written. `docs/00-brief.md` already says this is a review tool and not an
  editor; authoring a new document is not editing an existing one, and the line
  holds either way.
- **Open question, answered:** a note is sent exactly as a review is. It has no
  `returnPath`, so the bundle lands in the relay's `outbox/` and the agent
  collects it with `list_reviews()` — which `docs/12-relay.md` § 4 had already
  made the return path over HTTP. No share-sheet special case was needed, and
  `ReviewSheetModel.canSend` already accepted a bundle carrying only ink.
  Whether a note should be *addressed* to a session at creation is still open,
  and is now the only part of this entry that is.

### B2 · A note attached to a document

The sharper half of the idea. A document gets a companion page — blank, lined or
plain — bound to it, for writing out notes and prompts at length rather than
squeezing them into a margin.

Annotation and composition are different acts. Marginalia is reactive and
positional: an arrow means "this bit". A prompt is generative and needs room —
several sentences, a list, a diagram. v1 has nowhere to put the second one
except the closing instruction field, which is a keyboard affordance in a
Pencil app.

- **Where it lives:** appended after the document's last page, so scrolling
  simply continues into it. Not a separate mode, not a drawer.
- **Anchoring:** a note page has no source text, so a comment on it has no
  quoted anchor. Either it carries no anchor (and the review bundle sends it as
  an image plus recognised text), or a note *block* can be explicitly attached
  to a passage — which is the more interesting version and the more expensive
  one.
- **In the review bundle:** this is the part worth getting right. A companion
  note is closer to the closing instruction than to a comment — it is what the
  user wants *done*. Probably a distinct section in `review.md`, above the
  comments, with its recognised text as the payload and the inked page attached
  as an image.
- **Cost:** medium. Page generation is shared with B1. The real work is the
  data model (pages that belong to a document but have no source), the review
  bundle format (a new section, which is a file-contract change), and deciding
  the anchoring question above.
- **Why it belongs here rather than in Notes.app:** because it travels with the
  document and lands in the same conversation. That is the entire premise.

### B3 · Handwriting as a first-class input to the bundle

`docs/00` deliberately scopes handwriting as "a convenience and a search index,
not the primary payload — voice is." B2 pushes against that. If people write
prompts by hand at length, recognised text stops being an index and becomes the
message. Revisit only after B2 has been used for a while — this is a decision to
make from evidence, not in advance.

---

## Deferred from v1

### B4 · `review.docx` with native anchored comments
Specified in `docs/05`, deferred to v1.1. Needs a ZIP container and iOS has no
system zip API, so it wants a stored-entry ZIP writer (~150 lines) plus minimal
OOXML with `w:commentRangeStart`/`w:commentRangeEnd`. Deliberately held until a
compiler exists, since it is fiddly binary-format code. High value for reach:
it makes Word, Pages, Google Docs and Cowork's `docx` skill return paths for
free.

### B5 · Export the annotated PDF
`docs/08` question 6. Flattening ink into the PDF for a human colleague is
trivially adjacent — the ink cropper already renders strokes over page content.
Perhaps an hour's work. Not v1 only because nobody asked for it yet.

### B6 · Git-backed sync folder
`docs/08` question 2, answered "not in v1". Working Copy syncing a repo would
give every document and review a history and a diff. The watcher is already
behind a protocol so a git transport can be added without rework; the cost is a
commit step on the outbox write and a sensible answer to conflicts.

### B11 · A real Night page tint
`docs/01` rule 9 asked for Books' Night and v1 ships White, Cream, Sepia and Grey
instead, because a multiply wash cannot darken a page without darkening its text
and everything else is inversion, which the same rule forbids (see the note under
that rule).

Doing it properly means the app compositing the page rather than tinting what
PDFKit drew: render each page to a bitmap, map luminance rather than inverting
channels — text towards white, page towards near-black, hue preserved so figures
and syntax highlighting survive — and cache the result per page and zoom level.
That is a real feature with a real cost: a render pass per page, a cache to
invalidate, and ink that must be exempted from the mapping or graphite drawn in
daylight vanishes at night. Worth doing only if the people using this actually
read in the dark; a dim Sepia at low screen brightness is what most people
reach for.

---

## Smaller things

### B7 · Note-to-self on a passage without recording
A typed or scribbled note with no voice, for when neither talking nor a full
comment is right. Partly covered by the Scribble path already.

### B8 · Reading position sync across devices
Only meaningful once there is more than one device. The files are the API, so
this is a small JSON file, not a service.

### B9 · Bulk actions in the library
Archive several, purge several. Deliberately absent from v1 — `docs/01` rule 6
resists chrome, and a swipe covers the common case.

### B10 · Search inside the open document
Library search covers document text already, but there is no in-reader find.
PDFKit provides it nearly free.

---

## Rejected, with reasons

Kept so the same ideas don't get re-litigated.

- **Editing document text.** `docs/00` scopes this out explicitly. It is a
  review tool, not an editor. Editing would also break the frozen-layout premise
  that makes ink stable.
- **Real-time collaboration.** Out of scope in `docs/00`. It needs shared
  editing state and per-user identity, which is a far larger thing than moving
  finished files between two ends of a loop.
- **An account.** There is nobody to have one. The relay is reached with a
  shared token, and that is as far as identity goes until there is a second
  user.
- **iPhone, Mac, web.** `docs/00`: iPad only. The premise is a screen you hold
  with a pen.

---

## Reconsidered

One entry has left the list above by being re-litigated and winning. It stays on
the record, because "we decided this once" is only useful alongside what changed
the answer.

### B12 · A sync service of our own — rejected, then built

**What it said:** *"An account, or a sync service of our own. Same reason. The
folder is the API."*

**Reopened and accepted, August 2026.** The folder transport assumes a file
provider configured on the Mac *and* on the iPad. On the first Mac it was tried
on, iCloud Drive was simply switched off, so the shared folder did not exist and
the loop — send a document, annotate it, get the review back — had never once
run end to end. That is not a disagreement about architecture; it is the app not
working.

What made the answer different this time is that the objection turned out to be
narrower than the sentence carrying it. The thing worth protecting was never the
folder; it was that the files are the entire contract, that nothing needs an
account, and that the app keeps working when the network does not. A relay that
stores and serves the exact `inbox/` and `outbox/` layout of `docs/05` keeps all
three, and costs nothing to keep: `meta.json`, `review.json` and `manifest.json`
are the wire format, `GET /v1/export.tar` hands back a directory you can drop in
Dropbox to go the other way, and the folder transport is untouched and still the
reference path. The relay is opt-in and new, and nothing in the app assumes it.

What was *not* conceded, and is worth restating because a server makes both
tempting: documents are still downloaded in full and pinned on arrival rather
than fetched when opened, and reading and annotating still never touch the
network. `docs/00`'s out-of-scope list and non-negotiable 3 in `CLAUDE.md` were
amended in the same change; `docs/12-relay.md` specifies it.

**B8 above is affected.** Reading-position sync is still a small JSON file
rather than a service, but it is deliberately *not* on the relay in v1: syncing
read state puts a network write on the reading path for a failure mode nobody
notices.
