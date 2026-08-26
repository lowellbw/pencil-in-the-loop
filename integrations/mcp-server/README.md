# Claude Code MCP server

A local MCP server that puts documents on the iPad and reads Pencil reviews back.
It writes and reads the same sync folder as everything else in this project — it is
convenience, not transport. Nothing here talks to the iPad, or to a network, or to a
database. The folder is the whole interface.

Because of that, every tool works when the iPad is off, asleep, or has never run.
`send_to_ipad` writes a folder; `list_reviews` finds nothing and says so.

Contracts it implements: `docs/05-file-contracts.md`. Requirements: the "Claude Code"
and "Codex" sections of `docs/06-integrations.md`.

## Install

One line, once:

```
claude mcp add pencil-in-the-loop \
  --env PENCIL_SYNC_ROOT=~/Library/Mobile\ Documents/com~apple~CloudDocs/Pencil-in-the-loop \
  -- uvx --from /path/to/pencil-in-the-loop/integrations/mcp-server \
     pencil-in-the-loop-mcp
```

`uvx` builds an isolated environment on first run and needs nothing installed
globally. If `uv` is not on the Mac yet: `brew install uv`.

Or as a `.mcp.json` entry, checked into a project:

```json
{
  "mcpServers": {
    "pencil-in-the-loop": {
      "command": "uvx",
      "args": [
        "--from",
        "/path/to/integrations/mcp-server",
        "pencil-in-the-loop-mcp"
      ],
      "env": { "PENCIL_SYNC_ROOT": "~/Pencil-in-the-loop" }
    }
  }
}
```

Codex reads the same server; point its MCP config at the same command and set
`PENCIL_ORIGIN_KIND=codex`, or pass `origin_kind` on the call.

## Tools

### `send_to_ipad(content, title?, tags?, group?, origin_kind?, session_id?, thread_title?)`

Writes `inbox/YYYY-MM-DD-<slug>/` containing `source.md` and `meta.json`.
Returns the bundle id, its path, and which return path was recorded.

`title` defaults to the first H1 in `content`. `origin_kind` and `session_id` are
auto-detected; pass them only to override.

`group` files the document under a name that sections the iPad's library. Call
`list_groups` first and pass back a name that already fits: the tool description says so
too, because a model on the MCP path never reads the skill file.

The tool description carries the authoring guidance from `docs/06`, so the calling
model follows it without being told again: short paragraphs one idea each, numbered
or clearly titled sections, no code block wider than ~76 characters, narrow tables or
lists instead, no nested bullets beyond one level. A document written to be annotated
is a different document, and margin notes need somewhere to live.

### `list_groups()`

What is already filed where: for each group its name, how many documents are in it, when it
was last used, and up to three recent titles. Folded from `inbox/*/meta.json`, which is the
whole history of what has been sent — the iPad copies a document into its own container and
never deletes the directory it came from — so a scan is not a partial view of it.

Names are folded on `group_key`: case, accents and punctuation ignored, folding rather than
transliterating so a non-Latin name keeps its own key. The display name is the one the
group's oldest document used, so a group does not flip spelling because of one careless
send. An unreadable `meta.json` is skipped rather than hiding every other group.

No arguments, deliberately. It is meant to be called before every send, so an argument
would be a decision to get wrong on every call; the reply is bounded instead.

Groups the reader created or renamed on the iPad itself are not visible here, and the reply
says so — this is what has been sent, not everything that exists.

### `list_reviews()`

Enumerates `outbox/*.review/`, newest first: document title, review time, comment
count, and whether a `reply.md` has been written back. Temp directories, non-`.review`
folders and stray files are ignored. A bundle missing its `review.json` still appears,
with the title recovered from `review.md` or the folder name.

### `get_review(id)`

Returns one bundle in full: `review.md` as `reviewMarkdown` (the primary payload),
the parsed `review.json` as `review`, the manifest, the list of ink image paths, and
`reply.md` when present. `id` is the bundle name with or without `.review`.

Strictly read-only. It opens files and nothing else — no bundle is ever modified,
moved or deleted, and ids that try to escape the outbox are rejected before any
filesystem access.

## Where the sync folder lives

Resolved in this order, first hit wins:

1. `PENCIL_SYNC_ROOT` in the environment
2. `syncRoot` in `~/.config/pencil-in-the-loop/config.json`
3. `~/Library/Mobile Documents/com~apple~CloudDocs/Pencil-in-the-loop` if iCloud
   Drive exists, otherwise `~/Pencil-in-the-loop`

That config file is the server's only state. Nothing is created until a write, so
pointing at a folder that does not exist yet is fine.

## How the session id is obtained

`meta.json` records `origin.sessionId` so the Mac-side watcher knows where to send
the review. The server looks in four places, and always records which one answered as
`origin.returnPath.sessionIdSource` — so a watcher can weigh how much to trust it.

1. **The `session_id` tool argument.** Most reliable when the calling model passes it.
2. **`CLAUDE_CODE_SESSION_ID` in the environment.** An MCP server is a child process
   of Claude Code and inherits its environment. This variable was observed carrying
   the session UUID on Claude Code 2.1.42, which is what makes the zero-configuration
   case work. `CLAUDE_SESSION_ID`, `CODEX_SESSION_ID` and `CODEX_THREAD_ID` are also
   probed.
3. **`~/.config/pencil-in-the-loop/session.json`**, written by a `SessionStart` hook.
   `docs/06` specifies the id as coming from the hook payload's `session_id` field,
   and a hook is the only place that payload exists — an MCP server never sees it. So
   the hook copies it to a file the server can read:

   ```json
   {
     "hooks": {
       "SessionStart": [
         {
           "hooks": [
             {
               "type": "command",
               "command": "mkdir -p ~/.config/pencil-in-the-loop && cat > ~/.config/pencil-in-the-loop/session.json"
             }
           ]
         }
       ]
     }
   }
   ```

   Claude Code delivers the hook payload on stdin, so `cat` is the whole hook.
4. **Nothing.** `origin.sessionId` is omitted and `returnPath.type` is `none`. The
   document is still perfectly readable — `docs/05` makes everything under `origin`
   optional — and the iPad falls back to the share sheet, which `docs/06` is explicit
   is not a failure state.

**Honest assessment:** step 2 is verified only on the version noted above, in a
remote Claude Code environment; it has not been checked on a local Mac install, and
environment variable names are not a stable API. Step 3 is the durable mechanism and
is worth setting up. Step 1 is worth passing whenever the model knows its own id.

## Return paths — recorded, not fired

Firing the return path is the Mac-side watcher's job. This server only records enough
in `meta.json` for the watcher to resolve it. Under `origin.returnPath`:

- `type` — the preferred path, one of the values `docs/05` allows
- `sessionId`, and `cloudSessionId` when the session is a cloud one
- `candidates` — every route in preference order, each with the literal argv the
  watcher would run, with `<review>` as the placeholder for the review text
- `verified: false` on every candidate

**What is verified and what is assumed.** `docs/08` question 7 flags these semantics
as unchecked, and nothing here changes that:

| Route | Status |
|---|---|
| `claude --cloud <id> -p "<review>"` | **Assumed.** Not run against a live session. |
| `claude -p "<review>" --resume <id>` | **Assumed.** Not run against a live session. |
| Running local session | **Assumed impossible to inject into.** `docs/06` says it must be idle; the watcher should hold the bundle and retry. |
| `codex resume <id>` | **Assumed.** `docs/06` says equivalent semantics; not checked. |
| Share sheet fallback | **Works today**, needs no integration at all. |

Which session id `--cloud` wants is itself an open question. When Claude Code is
running remotely there are two ids — the local session UUID and a separate web
session id — and both are recorded, so the watcher can try either without guessing.

Write the watcher defensively: try candidates in order, treat a non-zero exit as
"this route is not available right now" rather than as failure, and fall through to
the share sheet.

## Atomic writes

A bundle is built inside a hidden sibling directory, `inbox/.<name>.<rand>.tmp`,
fsynced, and moved into place with a single `rename`. A watcher polling `inbox/`
sees the folder appear complete or not at all, never half-written. If anything fails
part-way the temp directory is removed and the inbox is exactly as it was.

Input is validated in full *before* the filesystem is touched: content must be
non-empty UTF-8 under 5 MB with no null bytes, tags must be a list of short strings,
`origin_kind` must be one of the five kinds `docs/05` allows. Malformed input gets an
error message and leaves no trace.

Name collisions follow `docs/05`: `<name>`, then `<name>-2`, `<name>-3`.

## Known contract gaps

- **`tags` has nowhere to live.** `docs/06` gives `send_to_ipad` a `tags` parameter
  but the `meta.json` example in `docs/05` has no field for them. They are written as
  a top-level `"tags"` array, which `contracts/schema/meta.schema.json` does declare.
  Nothing on the iPad reads them — unlike `group`, which is declared in the schema,
  described in `docs/05` prose, and sections the library.
- **`pageCount` is omitted.** The server ships markdown; the iPad renders the PDF, so
  page count is not knowable at write time.
- **Slug rules are implemented twice.** `integrations/cowork-skill` implements the
  same rules independently. They must produce identical names for identical titles
  and have not yet been diffed against each other. The group-matching rule is
  implemented *three* times — here, in the skill, and in Swift — and did get that
  diff: `GroupKeyAgreementTests` in `scripts/test_send_to_reader.py` and
  `testTheMatchingRuleAgreesWithTheOneTheSendersUse` in `CoreTests/DocumentGroupsTests`
  assert the same table of cases.
- **`manifest.json` is undocumented.** It appears in the `docs/05` tree with no
  schema, so `list_reviews` reads it opportunistically and never depends on it.

## Tests

```
cd integrations/mcp-server
python3 -m unittest discover -s tests -t .
```

Standard library only, and they do not need the MCP SDK — everything in `core.py`
is dependency-free, and the tests that exercise the tool wrappers skip cleanly when
`mcp` is not installed. They cover slug generation and collisions, that no partial
bundle is ever visible in `inbox/`, that a failed write leaves nothing behind, the
`meta.json` shape, `list_reviews` against a fixture outbox including a malformed
bundle, `get_review` on a missing id, and that reading never changes a single byte
in `outbox/`.

`meta.json` is checked against the example in `docs/05`. There is also a test that
validates it against `contracts/schema/meta.schema.json` and skips while that file
does not exist.
