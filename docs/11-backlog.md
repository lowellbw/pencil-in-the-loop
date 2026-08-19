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

### B1 · Notes — blank paper, in the app

Start a note without a document. Lined or plain paper, Pencil, nothing else.

This is not a feature so much as a removal of an assumption: the app already has
the whole ink stack — per-page canvases, `.pencilOnly`, autosave, handwriting
recognition, page tints. A note is that stack with a generated blank page
instead of a rendered one.

- **Cost:** low. A blank-page generator in `Ingest` (the renderer already emits
  A4 at fixed geometry), a `DocState`/`OriginKind` for locally-authored, and a
  "New note" affordance in the library. The reader, ink layer and search work
  unchanged.
- **Paper styles:** plain, lined, grid. Rendered *into* the page, so ink can
  never drift relative to the rule lines, exactly as with document text.
- **Open question:** does a note get sent to Claude the same way a review does?
  A note with no origin has no thread to return to, so it would use the
  share-sheet path. That may be the honest answer, or it may argue for letting
  a note be *addressed* to a session at creation time.

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
Only meaningful once there is more than one device. The folder is the API, so
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
- **Real-time collaboration.** Out of scope in `docs/00`. It needs a server,
  which the whole architecture exists to avoid.
- **An account, or a sync service of our own.** Same reason. The folder is the
  API.
- **iPhone, Mac, web.** `docs/00`: iPad only. The premise is a screen you hold
  with a pen.
