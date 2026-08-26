# The relay

The second transport. **The wire format is the file format** — `meta.json`,
`review.json` and `manifest.json` are stored byte-verbatim and served back as they are, so
this document specifies only envelopes, cursors and status codes.
`docs/05-file-contracts.md` remains the contract, and nothing here forks it.

The relay's storage *is* a sync root: a volume holding the same `inbox/` and `outbox/`
layout, which is why `integrations/mcp-server/pencil_in_the_loop_mcp/core.py` runs against
it unchanged. `GET /v1/export.tar` produces a tarball you can untar into a Dropbox folder,
and the folder transport picks up exactly where the relay left off. Migration in either
direction is a `tar`.

**It is second in the order it was built, and first in the order it is offered.** A build
that ships pointed at a relay (`Config/Local.xcconfig` → `RelayDefaults`) adopts it without
asking, because the folder needs a file provider configured at both ends and that is the
friction this exists to remove.

That does not demote what the folder is for. It needs no network, no account and no uptime
from anyone, it is fully supported, and it is one tap away in Settings; a build with no
relay configured still starts there. If the relay is down, a device that has already synced
loses nothing either way: every document it holds is pinned in its own container and opens
on a plane exactly as before.

---

## 1 · Why it exists

The folder transport requires a file provider configured on both ends. That is one
setting, and it is the setting that turned out to stop the loop working at all: iCloud
Drive switched off on a Mac means the shared folder does not exist, the iPad's library
stays empty for ever, and nothing anywhere says why.

The relay removes the file provider from the picture. A document sent from Claude Desktop
reaches the iPad with no Mac awake, no folder picked and nothing synced.

What it costs is written down in `docs/11-backlog.md` § B12, along with what was
deliberately *not* conceded.

---

## 2 · Shape

```
Claude Desktop ─┐
Claude Code    ─┼─▶ MCP (in-process) ─▶ /data ◀─ REST ─▶ iPad
share sheet    ─┘                     inbox/ outbox/
```

One service, one volume. The MCP server runs in the same process and its tools call the
storage layer directly — there is no HTTP client inside it, because the API and the tools
are two faces on one store and a second implementation of every verb would drift from the
first.

Beside the sync root is `index.sqlite3`, and **it is disposable**. Every fact in it is
derivable by walking the two directories; `reindex()` does exactly that and mints a fresh
`epoch`, which tells devices to reset their cursor and re-list. Nothing a person wrote
lives in it.

**One worker, deliberately.** A volume attaches to a single instance, so there is nothing
to scale out to, and single-writer is what makes SQLite and the rename-based commits in
`core.py` safe together.

---

## 3 · Auth

Two secrets, so revoking one does not revoke the other:

| | |
|---|---|
| `PENCIL_DEVICE_TOKEN` | the iPad. Sent as `Authorization: Bearer …` on every `/v1/` request. |
| `PENCIL_MCP_TOKEN` | the MCP clients. Sent as a header, **or** carried in the URL path. |

The MCP endpoint is mounted twice. `/mcp/` takes the token as a header, which is what
Claude Code sends with `--header`. `/mcp/<token>/` *is* the credential — a capability URL
— because Claude Desktop's custom-connector UI accepts a URL and OAuth, not a static
header field.

**A token in a path is weaker than one in a header.** It lands in the connector config and
in any access log that records paths, which is why the relay runs with uvicorn's access
log off. It is rotated by changing the environment variable. This is a deliberate trade
for one person's tool; building an OAuth provider to avoid it would be the wrong shape of
solution to a problem nobody has yet.

**There are no accounts, and the tenancy boundary does not exist yet.** One identity, one
token. If a second person ever uses a relay, tokens become per-user and bundle ids become
unguessable *in the same change* that adds them — `get_review(id)` reading another
tenant's review is the classic confused deputy, and it is far cheaper to prevent than to
find.

---

## 4 · Endpoints

Everything under `/v1` requires the device token. `/healthz` requires nothing.

| Method | Path | |
|---|---|---|
| `GET` | `/healthz` | Liveness, epoch, cursor, free bytes. No auth. |
| `POST` | `/v1/documents` | Send a document. `{content, title?, tags?, group?, documentId?, expectedFiles?}` |
| `PUT` | `/v1/documents/{folder}/files/{name}` | Upload one declared file. |
| `GET` | `/v1/documents/{folder}/files/{name}` | Bytes, with `ETag: "<sha256>"`. |
| `DELETE` | `/v1/documents/{folder}` | Remove it. Becomes a tombstone in the feed. |
| `GET` | `/v1/changes?since=<seq>` | **The only feed a device needs.** |
| `POST` | `/v1/documents/{folder}/review` | Declare a review bundle. |
| `PUT` | `/v1/reviews/{folder}/files/{path}` | Upload `ink/page-NN.png`. |
| `GET` | `/v1/reviews`, `/v1/reviews/{folder}` | List and read, in `core.py`'s shapes. |
| `GET` | `/v1/reviews/{folder}/files/{path}` | Ink bytes. |
| `PUT` | `/v1/reviews/{folder}/reply` | Write `reply.md`. |
| `GET` | `/v1/export.tar` | The whole sync root. |

### Declare, then upload

Both documents and reviews announce their files first and upload them one at a time. The
staging directory outlives the request that created it, and is dot-prefixed throughout —
which every watcher in `integrations/` already skips — so a bundle half-uploaded across
three requests is invisible until the rename that lands it.

That buys three things: resumability on a bad connection (`missingFiles` says what to
re-send), a 100MB PDF that never exists in memory, and no multipart parser on either side.
The iPad has no third-party dependencies and would otherwise be hand-rolling boundaries.

### The feed, and what it will not tell you

```json
{
  "epoch": "b1c2d3…",
  "cursor": 412,
  "hasMore": false,
  "documents": [
    { "folderName": "2026-08-18-auth-refactor-plan",
      "documentId": "F7A1…", "title": "Auth refactor plan",
      "createdAt": "2026-08-18T18:22:04Z", "seq": 410, "deletedAt": null,
      "files": [ {"name": "source.md", "bytes": 8123, "sha256": "…"} ] } ],
  "replies": [ { "folderName": "2026-08-18-auth-refactor-plan", "seq": 412 } ]
}
```

`GET /v1/changes` replaces both the inbox scan and the reply scan. `ETag: W/"<epoch>:<cursor>"`
means an idle poll costs a couple of hundred bytes.

**An incomplete document never appears in it.** A device that learned about a document
whose bytes had not all arrived would pin a partial copy, and CLAUDE.md non-negotiable 2
would be a lie. The sequence number is re-stamped at completion, so a document enters the
feed at the moment it became *readable*, not the moment it was announced — a device
polling in between correctly sees nothing.

**Every file carries a size and a hash**, because the device verifies each download
against what the feed advertised.

An unfamiliar `epoch` means the index was rebuilt: reset the cursor to zero and re-list.

---

## 5 · Idempotency

`meta.json`'s `id` is the key for documents. It is already a minted UUID and already the
correlation key in `review.json` and `manifest.json`, so nothing new was invented. **Send
the same id to retry; send no id to mean a second document.** Idempotency is about
retrying one call, not deduplicating intent.

`folderName` is derived and *server-allocated*, using the same `-2`/`-3` collision ladder
as the folder transport, because two callers can want one name and only the server can
arbitrate. Never guess it; use what the response returns.

For reviews the key is the hash of `manifest.json`, and there are three cases:

- **A retry** — the same manifest for a review that already landed. Same revision, no new
  sequence number, nothing rewritten. This is what makes the iPad's `flushQueue()` safe to
  run on every poll: a review delivered twice is a duplicate message in a conversation.
- **A resumed upload** — the same manifest for a bundle that never finished. Same
  revision, staging replaced so the upload starts cleanly.
- **A new bundle** — a different manifest. Revision *n+1*, with the previous one kept
  under `outbox/.revisions/`. Two iPads both pressing Send lose nothing.

`manifest.json` is verified in full — every declared path, size and hash — before anything
is committed. That is what makes it a completeness signal rather than a file nobody reads,
and it is a stronger guarantee than the folder path could give: `docs/05` notes there that
the rename "does not survive the sync hop".

---

## 6 · Status codes

The device maps these onto states it already models. Errors are always
`{"error": "<snake_case>", "message": "<sentence>"}`, and the **code** is the contract.

| | | |
|---|---|---|
| `401` | bad or missing token | Settings says reconnect. Pinned documents open exactly as fast as yesterday. |
| `404` | unknown folder or file | Costs new documents only, never existing ones. |
| `411` `413` | no or oversized `Content-Length` | Refused before a byte is read. |
| `422` | `manifest_mismatch` | Re-queue and retry. The bundle stays invisible. |
| `503` | redeploy | The outbox queue holds; the sheet says "will send when online". |
| `507` | volume nearly full | The one that loses data if ignored. Surface it loudly. |

---

## 7 · What the relay does not do

- **It does not sync ink.** Comments are append-only and merge trivially; a `PKDrawing` is
  a binary blob where last-write-wins silently destroys work. The folder transport never
  carried ink either — only the exported PNGs in a review bundle ever left a device — so
  this preserves the existing behaviour rather than accepting a new limit. If it is ever
  wanted, `Page.drawingData` is per page, so conflicts are per page.
- **It does not sync read/unread state.** That would put a network write on the reading
  path for a failure nobody notices. See `docs/11-backlog.md` B8.
- **It does not store `origin.returnPath.triggerId`.** A trigger id fires a turn into
  someone's conversation, so it is closer to a credential than to metadata — and it is
  meaningless here anyway, because over the relay the return path *is* the MCP connection:
  the agent calls `list_reviews()` on its next turn. It is stripped on ingest and recorded
  as `{"type": "none", "detail": "relay; the agent pulls with list_reviews"}`. There is
  deliberately no new `"relay"` value, because the enum is frozen and unknown types
  already read as `none`.
- **It is not backed up.** A platform volume is one copy. Every document also exists in
  full on every device that has synced it, which is non-negotiable 2 doing double duty,
  and `GET /v1/export.tar` is the rest of the answer.

---

## 8 · Running it

Configuration is entirely environment variables, because that is what a platform gives you
and a config file on an ephemeral container is a file nobody can edit.

| | |
|---|---|
| `PENCIL_SYNC_ROOT` | Where `inbox/` and `outbox/` live. The mounted volume. Default `/data`. |
| `PENCIL_DEVICE_TOKEN` | Required. Without it the service refuses to start. |
| `PENCIL_MCP_TOKEN` | Optional. The MCP endpoint is only mounted when it is set. |
| `PENCIL_ALLOWED_HOSTS` | Optional, comma-separated. Falls back to the platform's own domain variable. |
| `PORT` | Given by the platform. Default 8080. |

```sh
pip install '.[relay]'
PENCIL_SYNC_ROOT=/data \
PENCIL_DEVICE_TOKEN=$(python3 -c 'import secrets;print(secrets.token_urlsafe(32))') \
pencil-loop-relay
```

On first boot against a volume it has never seen, the index rebuilds itself from whatever
is already in `inbox/` and `outbox/`. That is the recovery path when the SQLite file is
lost, and the migration path when a folder-transport sync root is untarred onto the
volume: copy, restart, and every document is served.

### Connecting the clients

```sh
# Claude Code — the token as a header
claude mcp add --transport http pencil-loop https://<host>/mcp/ \
  --header "Authorization: Bearer $PENCIL_MCP_TOKEN"
```

Claude Desktop takes the capability URL — `https://<host>/mcp/<PENCIL_MCP_TOKEN>/` — as a
custom connector.

The local stdio install in `integrations/mcp-server/README.md` is unchanged and still
works against a plain folder. All three can coexist; they are the same package with
different entry points.
