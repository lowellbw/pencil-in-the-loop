# 06 · Integrations

**The folder is the API.** There is no protocol, no server and no account. Anything that
can write a file can send a document; anything that can read one can receive a review.
That single decision is why one app serves Cowork, Claude Code and Codex without three
integrations.

---

## Cowork is the primary path — make it invisible

This is the most-used route by a wide margin, and the design goal is that **the user never
has to ask.** Working in Cowork on the Mac should mean documents simply turn up on the
iPad.

### Outbound: Cowork → iPad

Cowork already reaches the user's connected folders on the desktop. So:

**Setup, done once:** the sync folder is a folder the user has connected in the Claude
desktop app, and the same folder the iPad app is pointed at. Nothing else. No MCP server,
no daemon, no plumbing.

**Ship a skill with the app** — `send-to-reader` — installed into the user's account.
Its job is to make delivery automatic rather than requested:

```
Trigger this skill whenever ANY of the following is true:

  - The user asks for something to read, review, look at later, or "on the iPad"
  - You have produced a document longer than roughly 400 words — a plan, brief,
    report, research summary, postmortem, spec
  - You have fetched or been given a PDF the user will want to read properly
    (a paper, a report, a long article)

Do not ask permission first. Write it to the reader folder and mention in one line
that it's on the iPad. If the user didn't want it there, it costs them nothing.
```

The skill writes `inbox/<slug>/` per `05-file-contracts.md`, recording the Cowork session
id in `meta.json` so the review knows where to return.

**Authoring guidance is part of the skill, and it matters more than it looks.** A document
written to be annotated is a different document. The skill instructs Claude to use:

- Short paragraphs, one idea each, with blank lines between — margin notes need somewhere
  to live
- Numbered or clearly-titled sections, so a spoken comment can name its target
- No code block wider than about 76 characters, so nothing wraps on an A4 page. This
  number and the page geometry in `03-architecture.md` § 1 are one decision in two
  places — 76 characters do not fit the text column at full size, so ingest shrinks the
  code type to make them. Change either and change both.
- Tables kept narrow, or replaced with lists
- No nested bullets beyond one level

### Inbound: iPad → the same Cowork thread

Three routes. **The sender picks exactly one, at send time, and records it in
`meta.json`** — `origin.returnPath` is a single value, not a list of candidates, so a
document does not get a poke *and* a check-in. `ReturnPathResolver` on the iPad reads what
is there and the review sheet always shows which route it resolved to, before the user
commits.

**Ordering matters and is easy to get backwards.** The return path has to exist before the
bundle that references it is written: a poke trigger's id goes into `meta.json`, so create
the scheduled task first, take its id, then write the document directory atomically. Do it
the other way round and the id is either missing or invented.

**1 · Poke the session (best, needs the Mac watcher).** `send-to-reader` creates a
*poke-only scheduled task* bound to that Cowork session — one with no schedule of its own,
which exists solely to be fired. Firing it delivers text into the session as an ordinary
user turn, so the review lands in the same conversation with all its context. Firing
requires account-level access, so in practice a small Mac-side helper watches `outbox/` and
does it.

*This is the one link in the chain that has not been verified.* No command that fires a
scheduled task from the Mac has been confirmed to exist; `integrations/mac-watcher/` ships
a placeholder so the rest of the route can be built and tested. Until someone names a real
command, `poke` should not be chosen by a sender, and a poke trigger nobody can fire is a
review that sits in `outbox/` forever. Route 2 needs none of this, which is why it is the
default — nothing is blocked, but nothing about route 1 should be trusted yet either. See
`08-open-questions.md` § 7.

**2 · Scheduled check-in (no helper).** `send-to-reader` schedules a check-in on the
session — "look in the reader outbox and read anything new." Slightly delayed, entirely
built from things that already exist, nothing to install. **This is the v1 default**, and
the one to use unless the watcher is known to be installed. It gets a `triggerId` too, so
the watcher can tell one check-in from another.

**3 · Manual (always works).** The user opens the thread and says "read my review." The
review sheet's Sent screen offers "Copy review" for exactly this.

---

## Claude Code

A local MCP server, roughly 100 lines, exposing `send_to_ipad(content, title, tags)`,
`list_reviews()` and `get_review(id)`. It writes and reads the same folder — it is
convenience, not transport, so nothing breaks when the Mac is asleep.

Session id comes from the hook payload's `session_id` field. Record it in `meta.json`.

Return paths, best first:

- **Cloud session:** `claude --cloud <session-id> -p "<review>"` queues into a live web
  session. Works while you're away from the Mac.
- **Idle local session:** `claude -p "<review>" --resume <session-id>` restores the full
  conversation history, model and permissions.
- **Running local session:** no external injection is possible; it must be idle. The
  watcher holds the bundle and fires when the session frees up.

## Codex

`codex resume` has equivalent semantics. Same folder, same bundle. No extra work beyond
recording a different origin kind.

## The universal fallback — use it, it already works

**The Claude iOS app's Remote Control accepts photo attachments directly into a live
session.** When no return path resolves, the Sent screen offers "Share…", which exports
the marked-up pages as images and hands them to the share sheet. Attach them in the Claude
app, dictate a line of instruction, and the model reads the ink visually. No integration,
no server, works today. This should never be presented as a failure state.

## Share extension — the other half of ingest

Equally important and much simpler. A share extension titled **Review** accepts PDFs and
URLs from Safari, Mail, Files, arXiv, anywhere, with `origin.kind = "share"`.

It cannot write into `inbox/` itself. A security-scoped bookmark is scoped to the process
that minted it: the extension never ran the folder picker, and resolving the app's bookmark
from inside it does not open the scope. So the extension writes where it certainly can —
the shared App Group container, under `staging/` — laid out exactly like an inbox
directory:

```
<App Group>/staging/
└─ 2026-08-18-attention-is-all-you-need/
   ├─ document.pdf
   └─ meta.json                     (origin.kind = "share")
```

The app moves those directories into the real `inbox/` the next time it is in the
foreground, holding its own scope, and they then take the one ingest path like anything
else. The user sees the document arrive a moment after switching apps, which is when they
were going to look at it anyway. That directory layout is the whole contract between the
two processes; nothing else crosses.

Build this in M4 at the latest. It is what makes the app worth opening on a day when no
agent sent anything, and that is what determines whether the app gets used at all.
