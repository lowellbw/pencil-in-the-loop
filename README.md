# Pencil-in-the-loop

An offline-first iPad app for reading long-form documents — research papers, PDFs, and
markdown written by Claude — marking them up with Apple Pencil, dictating comments in
place, and sending the whole review back to the conversation the document came from.

**Read these in order.**

| # | File | What it settles |
|---|---|---|
| 0 | `docs/00-brief.md` | Why this exists, what's decided, what's deliberately out of scope |
| 1 | `docs/01-design-principles.md` | The UI direction. Read before writing any view code |
| 2 | `docs/02-spec.md` | Screen-by-screen functional spec |
| 3 | `docs/03-architecture.md` | Modules, frameworks, data model, the hard parts |
| 4 | `docs/04-flows.md` | Step-by-step flows for every path through the app |
| 5 | `docs/05-file-contracts.md` | Exact on-disk formats. The integration surface |
| 6 | `docs/06-integrations.md` | Share extension, Cowork, Claude Code MCP, return paths |
| 7 | `docs/07-build-plan.md` | Milestones, in dependency order. Start at M0 |
| 8 | `docs/08-open-questions.md` | Things needing a human decision — ask, don't guess |
| 9 | `docs/09-prior-art.md` | What already exists, and the exact gap this fills |
| 10 | `docs/10-try-this-first.md` | The no-code version to run for two weeks before M0 |
| 11 | `docs/11-backlog.md` | Ideas not in v1, and what would decide them |
| — | `ui/mockups.html` | Visual reference for every screen |

## The one-paragraph version

The app watches a user-chosen folder. Anything that lands in `inbox/` shows up in the
library and is readable offline. You annotate with the Pencil and press-and-hold to
speak comments anchored to specific passages. When you're done, the app writes a
review bundle to `outbox/` and pokes the originating session so the review arrives in
the same thread. Every integration — Cowork, Claude Code, Codex — reads and writes that
same folder. There is no server and no account.

## Non-negotiables

1. **Offline first.** Every feature except the initial sync and the send-back works on a
   plane. No network call is ever on the critical path of reading or annotating.
2. **The folder is the API.** No proprietary protocol. If a tool can write a file, it can
   send you a document.
3. **One mode.** Finger scrolls, Pencil draws. The user never switches tools to annotate.
4. **Anchors survive regeneration.** Comments attach to quoted text, never to line numbers.
5. **Native, not branded.** See `docs/01-design-principles.md`. If a screen looks like it
   was designed, it's wrong.

## Target

- iPadOS 26.0 minimum. `PKStrokeRecognizer` — the on-device handwriting engine, public in
  iPadOS 27, a Swift actor covering 29 languages — sits behind an availability guard and a
  compile flag, so the app builds against a 26 SDK and lights recognition up where it
  exists. Ink is captured, persisted and exported either way; recognition only makes it
  searchable. It is an enhancement, never a dependency.
- iPad Air M2 or later, iPad Pro M4 or later, iPad mini A17 Pro
- Swift 6, SwiftUI, strict concurrency
- No third-party dependencies
