# 09 · Prior art

Researched August 2026. Read this before claiming novelty anywhere, and re-check the
starred items — they move fast.

## The headline

Two separate answers, and the distinction matters.

**Is the annotation surface code-specific? Mostly no.** Plannotator — the category leader —
accepts markdown, text, YAML, JSON, HTML, folders and URLs, with **no repo required**. A
policy brief works fine. `reviewable-html-workbench` is explicitly built for "reports,
design documents, comparison tables." Claude Plan annotates any `.md`. The surfaces
generalise.

**Is the ecosystem code-specific? Completely.** Every one of them installs via
`curl | bash`, npm, a VS Code extension, or a CLI coding-agent plugin marketplace, and
every return path is wired to a CLI coding agent. There is **no documented path from any
of them into a browser or desktop chat** — Claude.ai, Cowork, ChatGPT, Gemini. A
non-developer cannot use a single one of them, and even a developer can't route feedback
back into a Cowork conversation.

**And nobody, in either category, supports a pen.** Confirmed twice over.

## The real incumbent for general knowledge work

Not in the developer category at all: **Google Docs + Gemini**, shipped 28 July 2026.
Gemini reads comment threads, synthesises them, drafts replies, and produces suggested
edits — "rewrite the introduction to address Roberta's feedback." Anchored to text ranges,
batch (comment across ten pages, then ask once), approval-gated, generally available, and
in a tool people already use.

That is the honest benchmark for Cowork-shaped work. Its limits are the opening:

- **Web only, keyboard only.** No tablet surface, no stylus, no voice.
- **Invoked from the side panel, not by @-mentioning in a thread** — so you can't target a
  specific comment precisely.
- **Requires a paid Workspace or AI tier**, and your document has to live in Google Docs.
- **Outside the Claude ecosystem entirely.** The brief Cowork wrote has to be exported,
  reviewed elsewhere, and manually brought back.

Word + Copilot is second — it manages comment threads and produces word-level tracked
changes, the best audit trail of anything here — but it's Windows-only, Office Insiders
Frontier, and its ability to bulk-address existing reviewer comments is unconfirmed.

## The finding to actually exploit

**Cowork has no annotation surface — but it already reads anchored comments.** Its bundled
`docx` skill parses native Word comments via `w:commentRangeStart`/`w:commentRangeEnd` and
writes `w:ins`/`w:del` tracked changes.

That means a fully working loop exists today with zero new software: Cowork exports a
`.docx`, you comment in Word or Pages, hand it back, and Cowork returns a redline that
addresses each anchored comment in the same conversation.

It also means **`.docx` with real anchored comments should be one of the review bundle's
output formats** (see `05-file-contracts.md`). Any tool that reads Word comments — Cowork,
Word, Pages, Google Docs — then becomes a return path for free, with no integration at all.

## Direct competitors — the review loop (desktop)

| Tool | What it does | Why it isn't this |
|---|---|---|
| **Plannotator** ★ (6.5k stars, v0.21.2, MIT) | The category leader, and **genuinely document-agnostic** — markdown, txt, YAML, JSON, HTML, folders, URLs, no repo required. Browser + VS Code + CLI. Inline comments, strikethrough, replacements, version diffs. Hooks Claude Code's plan-mode hook so "Request changes" returns into the **same running session**. | Installed via `curl \| bash`; the return path is wired to CLI coding agents only, with no documented route into a browser or desktop chat. No mobile, tablet, touch, pen or stylus anywhere. |
| **Google Antigravity — Artifact Review** | First-party. Highlight a section of a generated artifact, leave an anchored comment, agent revises in-session. | Desktop IDE. No stylus. Tied to Antigravity. |
| **Claude Code desktop — plan review sidebar** ★ | Already ships "Select any text to leave a comment for Claude…". | Two open bugs (#48945, #49715, filed Apr 2026) report the comments **never reach the model** — client-side only. **Re-verify before building; this may be fixed.** |
| **Claude Plan** (VS Code ext) | Anchored directives in markdown preview → pasted into Claude Code's input. | ~105 installs. Superseded by Plannotator. |
| **vscode-agent-annotator** | VS Code comment threads → local MCP → Claude Code Channels API. Cleanest transport found. | 4 stars, no releases. |
| **open-plan-annotator**, **reviewable-html-workbench** | Browser/HTML review surfaces that loop back to the agent. | Small, desktop-only. |

**Implication:** do not position this as "review AI plans" — that's taken, and by a good
tool. Position it as *an offline reading library for long-form work, where marking up a
document by hand and sending it back to the conversation is one of the exits.* The
defensible ground is the combination nobody occupies: **tablet + pen + voice + offline +
non-code documents + a return path into Cowork.**

## Closest existing iPad apps

| App | Has | Missing |
|---|---|---|
| **MarginNote 4** | Pencil ink layers, handwriting→text/Markdown (4.2, Oct 2025), anchored excerpt cards, offline, JS add-on SDK + URL scheme | Markdown export is lossy and users still request full export. No JSON, no MCP. No anchored voice. The add-on SDK is where all the work would be. |
| **Zotero iOS** | Ink annotations as first-class API objects with position JSON, free, offline, huge tooling ecosystem | Bulk annotation extraction is **desktop-only**. Ink never becomes text. Papers only. |
| **Highlights** | Best structured export in class — Markdown, TextBundle, CSV, BibTeX, on-device OCR, direct-to-Obsidian | **Cannot take freehand Pencil ink at all.** Fails the core requirement outright. |
| **PDF Expert** | True PDF *sound annotation* — hold a spot, record, speaker icon embedded at that XY | No transcription of it, ever. Audio only. Freehand ink is excluded from its annotation-summary export. |
| **Notability / GoodNotes** | Timeline-synced audio with transcripts. GoodNotes documents **on-device STT when offline** | Transcript anchors to a *timestamp*, not a passage. GoodNotes has no Shortcuts or URL scheme at all — a long-standing open request. |

**The specific gap, stated precisely:** nobody ships *select a passage → hold to speak →
on-device transcript attached to that anchor → exportable*. PDF Expert has the anchor
without the transcript. Notability has the transcript without the anchor. That single
feature is the sharpest thing in this spec.

## Agent-on-tablet apps

All terminal-driving or diff-approving; none annotate.

- **Superconductor** (iPad-optimised, v1.2.3 May 2026) — closest in spirit, orchestrates
  coding agents from a tablet with a mobile review UI. No ink.
- **Happy** (4.9★, 983 ratings, open source), **Omnara** (git diff viewing), **Mobile IDE
  for Claude Code** (50k+ downloads, queues prompts offline), **Termly**, **Tactic
  Remote** — remote control and chat. **Termly's marketing page claims "Apple Pencil
  integration"; it is not in the App Store listing and is uncorroborated. Treat as false.**
- **Conductor** iOS: "SOON", not shipped. **Terragon**: dead.
- The **Claude iOS app** has no Pencil support, no annotation layer, no markup. Uploads
  are read-only ingestion.

## What actually works today — the 7/10 baseline

This is the honest benchmark to beat, and it's better than expected:

**Obsidian vault on iCloud + `obsidian-mcp-server` on the Mac + Claude Code Remote
Control from the Claude iOS app.** The agent writes a note, it syncs to iPad Obsidian,
you screenshot and mark it up in Apple's Markup, then attach the image in the Claude
app's Code tab and dictate "apply my handwritten notes." **Remote Control passes attached
photos directly into the live session as part of your message**, so the model reads your
ink visually and patches the file via MCP. Roughly 30–45 minutes of setup.

What it gets right: a true same-session round trip, ink read accurately by vision,
dictation for free, surgical edits back into the source.

What it costs: no anchoring of comments to positions, a manual screenshot-and-attach step
every cycle, the Mac must stay awake, no offline, and no "I'm done, go" trigger.

**Run this for two weeks before writing a line of Swift.** It answers the only question
that matters — whether the iPad gets picked up — and everything it can't do maps exactly
onto this spec's differentiators.

## Two useful discoveries to exploit

1. **Remote Control accepts photo attachments straight into a live local session.** That
   is a working return path that exists *today*, needs no MCP server, and should be the
   app's universal fallback when no better path is available: export the marked-up page,
   hand it to the Claude app's share sheet.
2. **InkedMark** (Obsidian plugin) stores strokes in plain markdown with a trailing
   comment and transcribes via your own API key. Small and young, but the file format is
   a good reference for keeping ink in a text-friendly container.
