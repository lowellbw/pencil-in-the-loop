# Integrations · M6

Three small units, none of them Swift, none of them talking to each other.

**All three are readers and writers of the same folder. The folder is the API — there is
no protocol between them.** A unit that can write `inbox/<slug>/` can send a document; a
unit that can read `outbox/<slug>.review/` can receive a review. Nothing else is shared:
no server, no account, no daemon in the middle, no message format beyond the files in
`docs/05-file-contracts.md`.

That is the whole design. Everything below is a consequence of it.

## The units

### `cowork-skill/` — `send-to-reader`

A Claude skill installed into the user's account. It is the primary path by a wide
margin, and its design goal is that the user never has to ask: whenever Claude produces a
document worth reading properly, or fetches a PDF, the skill writes it to `inbox/` and
mentions in one line that it is on the iPad.

It also carries the authoring guidance — short paragraphs, numbered sections, narrow code
blocks — because a document written to be annotated is a different document from one
written to be scrolled.

It sets up the return path at send time: a scheduled check-in on the session (the v1
default, needs nothing installed), or a poke-only scheduled task for the watcher to fire.

### `mcp-server/` — Claude Code

A local MCP server exposing `send_to_ipad`, `list_reviews` and `get_review`. Same folder,
same bundle formats, `origin.kind = "claude-code"` and the session id from the hook
payload. It is convenience, not transport — nothing breaks when it isn't running, because
the files are still just files.

### `mac-watcher/` — the return path

Watches `outbox/`. When a review bundle appears, it delivers it into the session the
document came from, using whatever `meta.json`'s `origin.returnPath` says: fire the poke
trigger, `claude --cloud <id> -p`, or `claude -p --resume <id>`.

Only the poke return path requires it. Everything else degrades to a scheduled check-in
or to the user saying "read my review", both of which work with nothing installed.

## How they relate

```
cowork-skill  ─┐                          ┌─▶  mac-watcher  ──▶  the originating session
mcp-server    ─┼─▶  inbox/ ──▶ iPad ──▶ outbox/ ─┤
share sheet   ─┘                          └─▶  the user, manually
```

Left of the folder is ingest, right of it is return. Neither side knows the other exists.
Adding a fourth writer — Codex, a shell script, a cron job that drops a paper in — needs
no change to any unit here.

## Conventions shared across the units

- Bundle names are `YYYY-MM-DD-<slug>`; slugs are lowercase, hyphenated, ASCII;
  collisions get `-2`, `-3`.
- **Every write is atomic.** Build in a hidden sibling `.tmp` directory and rename. A
  watcher on the other side must never see a half-written bundle. This applies in both
  directions.
- `meta.json` records where a document came from. `origin.kind` and
  `origin.returnPath.type` are how the iPad decides where a review goes; everything under
  `origin` is optional, and a document without any of it is still perfectly readable.
- Dot-prefixed entries are staging and must be ignored by every watcher.
- The sync folder's path is configured in `~/.pencil-loop/config.json` under `syncRoot`,
  overridable with `PENCIL_SYNC_ROOT`. `cowork-skill/` writes that file
  (`send_to_reader.py --set-folder <path>`) and `mac-watcher/` reads it, keeping its own
  settings under a `watcher` object in the same file so the two never collide.

  **Known divergence:** `mcp-server/` currently looks for `~/.config/pencil-in-the-loop/config.json`
  instead. Both read `PENCIL_SYNC_ROOT`, so exporting that variable configures all three
  today; the two config paths should be reconciled onto one.

## Status

`cowork-skill/` is built, with tests that run (`python3
cowork-skill/scripts/test_send_to_reader.py`). `mcp-server/` and `mac-watcher/` are being
built by sibling units; their details land shortly, and this index will be worth
re-reading then.
