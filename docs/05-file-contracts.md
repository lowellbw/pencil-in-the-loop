# 05 · File contracts

The integration surface. Everything here is plain files in a user-chosen folder. Keep
these formats stable — external tools depend on them.

```
<sync root>/
├─ inbox/
│  └─ 2026-08-18-auth-refactor-plan/
│     ├─ document.pdf          rendered or original; always present
│     ├─ source.md             original markdown, when there was one
│     ├─ sourcemap.json        rendered rect → source range, when generated
│     └─ meta.json
└─ outbox/
   └─ 2026-08-18-auth-refactor-plan.review/
      ├─ review.md             the primary payload — what the model reads
      ├─ review.json           structured equivalent for tools
      ├─ manifest.json         inventory, written last; the completeness signal
      ├─ reply.md              written by the agent, when it replies
      └─ ink/
         ├─ page-01.png
         └─ page-03.png
```

Folder names are `YYYY-MM-DD-<slug>`. Slugs are lowercase, hyphenated, ASCII.

## `meta.json`

```json
{
  "id": "F7A1…",
  "title": "Auth refactor plan",
  "createdAt": "2026-08-18T18:22:04Z",
  "origin": {
    "kind": "cowork",
    "sessionId": "8f3c1d…",
    "threadTitle": "Q3 platform planning",
    "returnPath": { "type": "poke", "triggerId": "trig_…" }
  },
  "sourceFormat": "markdown",
  "pageCount": 4
}
```

`origin.kind` ∈ `cowork` · `claude-code` · `codex` · `share` · `manual`.
`origin.returnPath.type` ∈ `poke` · `checkin` · `resume` · `cloud` · `none`.

**Writers and readers are held to different standards, deliberately.** A writer emits `id`,
`title` and `createdAt`; the machine-checkable version of that is
`contracts/schema/meta.schema.json`. A reader treats every field as optional and never
throws: an absent title falls back to the PDF metadata title, then the markdown H1, then
the filename; an unrecognised `origin.kind` reads as `manual`; an unrecognised
`returnPath.type` reads as `none`; a file that is not valid JSON at all leaves a document
titled from its filename with `origin.kind = "manual"`, which is still perfectly readable.
`04-flows.md` § F1 requires ingest never to block, and a metadata file is not allowed to be
the thing that blocks it.

`id` is whatever the writing tool uses, verbatim — a UUID string is preferred and nothing
requires one. The app keeps the raw string as the document's external id and mints its own
UUID alongside, so a sender is free to use its own identifier scheme without the app
rejecting it.

Unknown keys are ignored, never rejected — external tools add their own. Several already
do: the MCP server writes a top-level `tags` array and records extra detail under
`origin.returnPath` alongside the fields above. The canonical home for the session id is
`origin.sessionId`; a copy under `returnPath` is tolerated and ignored.

Two fields commonly get written by the wrong side:

| Field | Written by | Notes |
|---|---|---|
| `pageCount` | the ingesting app | A markdown sender cannot know it — pagination happens when the iPad renders the PDF. Optional in a sender's `meta.json`, advisory when present, and the rendered PDF is authoritative. |
| `returnPath.triggerId` | the sender | Allowed on **any** return-path type, not just `poke`. `checkin` also creates a scheduled task, and the Mac-side watcher wants its id to deduplicate. |

One more optional field, absent from the example above because most documents do not have
one:

| Field | Written by | Notes |
|---|---|---|
| `sourceURL` | the sender | Absolute URL the document came from on the web. The share extension writes it for a shared link: it does no network work, so it stages a placeholder `source.md` and records the address for the app to fetch and render later. Any sender may write it; nothing in ingest branches on it today, and a reader that does not know the key ignores it. |

`returnPath` is one route per document, not a list of candidates. `checkin` is the v1
default; `poke` is used only when the sender knows the Mac watcher is installed. If a
second route is ever needed, add an ordered array rather than overloading this field.

## `review.md` — the primary payload

Written for a model to read. Prose, not a data structure.

```markdown
# Review — Auth refactor plan

Reviewed 18 Aug 2026, 21:14 · 3 comments · 2 inked pages
Origin: Cowork · "Q3 platform planning" · session 8f3c1d

## What I want done

Rework phase 2 with the shadow read, then re-scope the estimate.

## Comments

### 1 — page 1

> The migration runs in a single deploy, with no dual-write window.

No dual-write window means we can't roll back after cutover — I want a shadow read
for at least a day.

*voice, transcribed on device*

### 2 — page 2

> await refresh(session)   // no backoff

Infinite retry loop? Needs exponential backoff and a cap.

*handwriting, recognised*

## Handwritten pages

Pages 1 and 3 have handwritten marks attached as images: `ink/page-01.png`,
`ink/page-03.png`. Position carries meaning — arrows and circles refer to the text
they point at, and a strikethrough means delete. Read them alongside the comments
above rather than instead of them.

## How to locate these passages

Each quoted excerpt is exact text from the document you produced. Match on the quote,
not on a line number — the document may have changed since.
```

That closing paragraph is not decoration. It tells the model how to resolve anchors, and
it measurably improves how reliably edits land in the right place.

## `review.json`

```json
{
  "documentId": "F7A1…",
  "reviewedAt": "2026-08-18T21:14:00Z",
  "closingInstruction": "Rework phase 2 with the shadow read…",
  "comments": [
    {
      "id": "C1",
      "index": 1,
      "text": "No dual-write window means we can't roll back…",
      "source": "voice",
      "anchor": {
        "quoted": "The migration runs in a single deploy, with no dual-write window.",
        "prefix": "…refresh token stored in the keychain. ",
        "suffix": " Rollout is gated behind auth_v2…",
        "pageIndex": 0,
        "normalisedRect": [0.12, 0.34, 0.76, 0.04],
        "sourceRange": [1204, 1268]
      }
    }
  ],
  "inkPages": [
    { "pageIndex": 0, "image": "ink/page-01.png", "recognisedText": "do we? check the mobile SDK" }
  ],
  "included": { "comments": true, "inkImages": true, "recognisedText": true, "fullDocument": false }
}
```

## Units and coordinate spaces

Everything here is frozen. These are the values that fail silently rather than loudly — a
comment lands at the wrong end of the page, or a quote is sliced mid-emoji, and nothing
crashes to tell you.

| Thing | Frozen as |
|---|---|
| `sourceRange` | Half-open `[start, end)` **UTF-8 byte offsets** into `source.md`. `end - start` is the length; an empty range has `start == end`. |
| `normalisedRect` | `[x, y, width, height]` as fractions of page width and height, **origin top-left, y increasing downwards**. |
| Page indices | Zero-based, everywhere in the data. |
| Comment ids | `C1`, `C2`, `C3` … in document order, assigned when the bundle is written. |
| Ink filenames | `ink/page-NN.png`, **one-based and zero-padded to two digits**: `pageIndex` 0 is `ink/page-01.png`. |

UTF-8 bytes because that is the only unit that means the same thing in Swift, Python, Go
and JavaScript, and `source.md` is read by tools written in all four. Not characters, not
UTF-16 code units, not lines. Swift callers index through `String.utf8` — `String.index`
counts grapheme clusters and will disagree the first time an accent or an emoji appears.

Top-left origin because that is UIKit's, and the ink, the markers and the source map all
come from view geometry. **PDF user space is bottom-up**, so anything crossing that
boundary — `PDFPage.bounds(for:)`, an annotation rect — must flip:
`y = 1 - (pdfY + height) / pageHeight`. Values are not clamped: a rect may legitimately run
past a page edge, because a stroke can.

Page indices are zero-based in every field and one-based in ink filenames, and that is not
an accident: the fields are read by code, the filenames are read by a person looking at a
folder and by a model quoting "page 3".

## `sourcemap.json`

Written alongside `document.pdf` whenever the document was rendered from `source.md`. It is
what lets a comment anchored on a rendered page resolve back to a character range in the
markdown the model actually wrote.

```json
{
  "version": 1,
  "documentId": "F7A1…",
  "source": "source.md",
  "offsetEncoding": "utf8",
  "entries": [
    { "pageIndex": 0, "rect": [0.09, 0.08, 0.66, 0.03], "range": [0, 21] },
    { "pageIndex": 0, "rect": [0.09, 0.14, 0.76, 0.09], "range": [23, 402] },
    { "pageIndex": 0, "rect": [0.12, 0.34, 0.76, 0.04], "range": [1204, 1268] },
    { "pageIndex": 1, "rect": [0.09, 0.11, 0.76, 0.06], "range": [1269, 1690] }
  ]
}
```

One entry per laid-out text run, and finer is better — a run beats a paragraph, because the
entry is what a touch point is matched against. Order is not significant. `offsetEncoding`
is `utf8` and nothing else; a reader that meets a value it does not know must refuse the
file rather than mis-slice the source. A document with no source map is still fully
readable and fully annotatable: comments fall back to the quoted excerpt, which is what
resolves them in practice anyway.

## `manifest.json`

An inventory of a review bundle, written last: what the bundle contains, each file's size
and SHA-256, when it was written and by what. The bundle is assembled in a sibling `.tmp`
directory and renamed into place, so a watcher should never see a partial bundle — the
manifest covers the case a rename cannot, such as a bundle copied or synced file by file.
It is the completeness signal the Mac-side watcher gates on. Exact shape:
`contracts/schema/manifest.schema.json`, with a worked example in
`contracts/fixtures/manifest.json`.

## Ink images

One PNG per inked page. Crop to the union of the ink bounding boxes plus 15% padding on
each side, so surrounding text is visible for context. Render the page content beneath the
strokes — an arrow with nothing to point at is useless. Cap the long edge at 2048px.

**Only inked pages.** A 50-page document with marks on two pages sends two images. This is
the difference between a cheap review and an absurd one.

## Optional output: `review.docx` — deferred to v1.1

Because Cowork's `docx` skill already parses native Word comments
(`w:commentRangeStart` / `w:commentRangeEnd`) and writes `w:ins` / `w:del` tracked
changes, emitting the review as a `.docx` with **real anchored comments** would make every
tool that reads Word comments a return path for free — Cowork, Word, Pages, Google Docs —
with no integration whatsoever. Each comment becomes a Word comment anchored to its quoted
range; the closing instruction becomes a comment on the title.

It is not in v1, and the reason is dull: a `.docx` is a ZIP container, iOS ships no system
zip API, and "no third-party dependencies" is a harder constraint than this feature is
valuable. Writing a deflate-free store-only ZIP by hand is a day's work plus a class of bug
nobody wants in the send path. Nothing else depends on it — `review.md` is the primary
payload and every return path reads that. Revisit in v1.1, with the ZIP writer as the first
question, not the last.

## Reply channel

An agent may write `outbox/<slug>.review/reply.md`. The app watches for it and surfaces it
on the Sent screen, and offers to open it as a new document. This is how a review becomes
a conversation without the user getting up.
