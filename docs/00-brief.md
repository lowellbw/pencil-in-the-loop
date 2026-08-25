# 00 · Brief

## The problem

Claude writes plans, specs, research summaries and postmortems faster than they can be
read carefully at a keyboard. Reviewing them in a chat window encourages skimming and
one-line replies. Meanwhile the natural medium for careful reading — a screen you hold,
with a pen — has no path back to the conversation.

Separately: research papers and PDFs pile up unread because there's no good place to put
them that's also where you'd annotate them.

Both problems have the same shape. One app.

## Prior art, in one line

The annotate-and-return-it loop is **solved and crowded — for developers.** Plannotator
(6.5k stars) leads it and handles arbitrary documents, but installs via `curl | bash` and
returns feedback only to CLI coding agents. For general knowledge work the real incumbent
is **Google Docs + Gemini** (July 2026), which reads comment threads and drafts edits
addressing them — web only, keyboard only, outside the Claude ecosystem.

**Nobody in either category supports a pen, a tablet, voice, or offline, and nothing
returns feedback into a Cowork conversation.** That intersection is empty. The single
sharpest unclaimed feature is *select a passage → hold to speak → on-device transcript
anchored to that passage → exportable.* Full survey in `09-prior-art.md`.

## What it is

An offline reading library for long-form documents, with Pencil annotation, in-place
voice comments, and a one-tap return path to the originating conversation.

## What's decided

| Decision | Choice | Why |
|---|---|---|
| Render engine | **Everything becomes a PDF on ingest** | One annotation engine for md and PDF. Layout is frozen, so ink can never drift. PDFKit gives pagination, text selection and an annotation model for free. |
| Ink capture | PencilKit, `drawingPolicy = .pencilOnly` | Finger scrolls, Pencil draws. No tool switching, which is the difference between an app you use and one you don't. |
| Handwriting → text | `PKStrokeRecognizer` (iPadOS 27) | The Notes/Freeform engine, now public. Works on stroke vectors not pixels, so it beats OCR. On-device, offline, 29 languages. Public in iPadOS 27, but the build floor stays at 26.0 and the recogniser sits behind an availability guard: ink is captured and exported either way, recognition only makes it searchable. |
| Voice → text | `SpeechAnalyzer` + `SpeechTranscriber` | Fully on-device once language assets download. No network on the critical path. |
| Comment anchors | Quoted excerpt with context, never line numbers | Claude regenerates documents. Quoted strings still resolve; line numbers don't. Same principle as a diff-based edit tool. |
| Transport | A user-chosen folder, watched | Works with iCloud Drive, Dropbox, or a git repo synced by Working Copy. No account, no per-tool integration. |
| Second transport | A hosted relay, the default where a build ships pointed at one | Added because the folder needs a file provider configured at both ends, and that stopped the loop running at all. Same files, moved over HTTPS instead. The folder is fully supported and stays the no-network path; see `12-relay.md`. |
| Primary source | **Cowork, and it must be invisible** | Cowork already writes to connected folders on the desktop, so outbound needs no plumbing at all. A shipped skill sends anything substantial automatically — the user never asks. See `06-integrations.md`. |
| Return path | Poke the originating session | See `06-integrations.md`. Genuinely lands in the same thread for both Cowork and Claude Code. |

## What goes back to Claude

Three layers, sent together. Each carries something the others lose:

1. **Anchored comments** — voice and recognised handwriting, each tied to a quoted
   excerpt. Unambiguous, cheap, the part Claude acts on directly.
2. **Inked page images** — only pages with ink, cropped to the ink's bounding box plus
   context. An arrow pointing at a paragraph means something no text string preserves.
   Position *is* content.
3. **A closing instruction** — one free-text field. Turns a pile of notes into a request.

Do not ship layer 1 alone. Text plus image is strictly better than either.

## Hardware

**An iPad Air (M2 or later) does all of this.** It supports Apple Pencil Pro — squeeze,
barrel roll, hover — runs iPadOS 27, and handles on-device speech and handwriting
recognition comfortably. The 2026 M4 Air has 12GB of RAM, which is far more than this
app needs.

The one real compromise versus an iPad Pro is the **60Hz display**: the Air has no
ProMotion. For most apps that's cosmetic, but this is an inking app, and 120Hz is the
single biggest contributor to how "connected to the pen" drawing feels. It is still
perfectly usable at 60Hz — Notes and GoodNotes are used daily on Airs — but if a Pro is
already an option, this is the app that justifies it. Nothing in the spec depends on it.

Apple Pencil Pro squeeze is treated as a **bonus** trigger throughout, never a
requirement: not every supported iPad has a Pencil Pro paired, and users remap the
squeeze system-wide. Long-press is always the primary gesture.

## Explicitly out of scope for v1

- Editing document text. This is a review tool, not an editor. Starting a blank
  notebook or typing a new one (`11-backlog.md` § B1) is not editing and is in scope;
  changing the words of a document that already exists is not, including one written
  here. Re-rendering re-paginates, and every stroke already on the page would be left
  a line or two from where it was written.
- Real-time collaboration or multi-user anything.
- An account. There are no users to have one; the relay is reached with a shared token.
- Windows/Android/web. iPad only.
- Handwriting *as* the instruction channel — recognised text is a convenience and a
  search index, not the primary payload. Voice is.

**A server of our own was on this list and is no longer.** The folder transport depends
on a file provider being configured on the Mac *and* the iPad, and when that turned out
not to be true on the first machine it was tried on, the loop could not run end to end at
all. So a small hosted relay was built as a second, opt-in transport, and this list is
amended rather than quietly contradicted. It stores and serves the exact `inbox/` and
`outbox/` layout of `05-file-contracts.md` — it is a place to put the same files, not a
service with a data model of its own. The folder transport is unchanged and remains the
reference path, reading and annotating still never touch the network, and documents are
still downloaded in full and pinned on arrival: a relay makes fetch-on-open tempting and
that is precisely the thing that would gut the app. `11-backlog.md` records the
reconsideration; `12-relay.md` specifies the thing.

## The risk to watch

The technical risk is low. The behavioural risk is whether the iPad gets picked up. This
is why ingest breadth (`06-integrations.md`) matters more than it looks: if the app is a
good offline paper reader first, it gets opened regardless of whether an agent sent
anything. Build the library and the share extension early, not last.
