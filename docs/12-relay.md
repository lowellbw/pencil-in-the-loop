# The relay

The second transport. **The wire format is the file format** — `meta.json`,
`review.json` and `manifest.json` are stored byte-verbatim and served back as they are, so
this document specifies only envelopes, cursors and status codes.
`docs/05-file-contracts.md` remains the contract, and nothing here forks it.

The relay's storage *is* a sync root: a volume holding the same `inbox/` and `outbox/`
layout, which is why `integrations/mcp-server/pencil_in_the_loop_mcp/core.py` runs against
it unchanged. `GET /v1/export.tar` produces a tarball you can untar into a Dropbox folder,
and the layout is the one `docs/05-file-contracts.md` specifies, unchanged. The bytes are
still yours without the app; getting them out is a `tar`.

**It is second in the order it was built, and now the only one there is.** A build that
ships pointed at a relay (`Config/Local.xcconfig` → `RelayDefaults`) adopts it without
asking, because the folder needed a file provider configured at both ends and that is the
friction this exists to remove.

**The folder transport was removed in August 2026.** It had been the reference path and then,
for months, the one nobody used. What it was for is worth stating, because it is what was
given up: it needed no network, no account and nobody's uptime. Getting a new document onto
the iPad now needs this relay to be up.

What did not change: every document is still downloaded in full and pinned into the app's own
container, so a device that has already synced loses nothing when the relay is down. The
library opens on a plane exactly as before. That property never came from the transport — it
comes from `PinnedDocumentWriter`, which both transports used and which one still does.

The folder transport required a file provider configured on both ends. That was one
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
| `GET` | `/v1/groups` | Which group each document should be filed under. |
| `PUT` | `/v1/groups` | Ask for filings. `{assignments: {folderName: group}}` |
| `POST` | `/v1/clips` | Declare a voice clip. `{clipId, language?, keyterms?}` |
| `PUT` | `/v1/clips/{clipId}/audio` | Upload the audio; returns the transcript. |
| `GET` | `/v1/documents/{folder}/files/{name}` | Bytes, with `ETag: "<sha256>"`. |
| `DELETE` | `/v1/documents/{folder}` | Take it back. Becomes a tombstone in the feed; the iPad archives its copy (§ 4d). |
| `POST` | `/v1/documents/{folder}/revision` | Rewrite it in place. `{content, mode, title?}`, `mode` ∈ `replace` · `append` (§ 4d). |
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


## 4a · Groups — filing documents the device already has

`group` in `meta.json` is read once, at ingest. A document already in the
library never sees it again, which is deliberate — a re-send must not move
something the reader filed by hand — but it means a sender has no way to file
the fifty documents it sent last week.

This map does. One file at the sync root, `groups.json`, beside `inbox/` and
`outbox/` rather than inside either: it is shared state, not a directional
queue.

```
PUT /v1/groups   {"assignments": {"2026-08-20-waymo-and-av": "AI taxation"}}
GET /v1/groups → {"assignments": {…}}
```

A **merge**, not a replace: two senders filing different documents must not undo
each other, and a caller that knows about three documents should not have to
send the other sixty to keep them where they are. An empty group name withdraws
a suggestion.

**The device still decides.** Every assignment is applied through
`DocumentGrouping.adoptGroupName`, which files a document that has no group and
never overrides one the reader chose by hand. So this suggests: if something
does not move, they filed it themselves and that stands. A relay too old to have
the route answers 404 and the device does nothing.

A malformed `groups.json` reads as nothing filed. A broken map must not stop
documents being sent.

## 4b · Clips — a better transcript for a voice comment

A voice comment is transcribed on the iPad and saved immediately, so there is
always text and dictation works with no signal. These two routes exist to make a
*better* transcript from the same audio, using a model that can be told what the
document is about (`notes/pencil-loop-cloud-dictation.md`).

Declare, then upload, like documents — and for a different reason: the keyterm
list runs to a hundred phrases and does not belong in a URL. Declaring twice is
harmless, and a failed upload leaves the declaration in place so a retry does not
have to send the document's vocabulary again.

```
POST /v1/clips            {"clipId": "<UUID>", "language": "en-GB",
                           "keyterms": ["Ofgem", "RIIO-3", …]}
PUT  /v1/clips/{id}/audio  <FLAC bytes>
  → {"ok": true, "text": "…", "raw": "…",
     "model": "gpt-4o-transcribe", "provider": "openai",
     "cleanupApplied": true, "inventedRatio": 0.0}
```

`raw` is the transcript as the speech model produced it and `text` is the best
available version — the same one after a correction pass, or identical to `raw`
when that pass was refused or unavailable. A consumer that does not care reads
`text` and is unaffected.

**The correction pass corrects; it does not rewrite.** It is told to fix misheard
proper nouns against the document's terms, resolve homophones, punctuate, drop
fillers and false starts while keeping hedges, and execute spoken commands like
"strike that" — and to change nothing else. Then the result is measured against
the transcript and **thrown away if too much of it has nothing behind it**.

That measurement is asymmetric, and the asymmetry was learned from a real clip.
Deleting words is what the pass is asked to do, so retractions and fillers cost
nothing; what is counted is output with no matching input, which is what
invention looks like. Measuring *change* instead scored a correct "strike that"
at exactly the 25% limit for doing what it was told. `inventedRatio` is that
number and `cleanupApplied` says whether it survived.

Only the term list is sent to the correction model, never the document's prose.
The note flags this as the larger of the two disclosures: audio is one comment,
a paragraph of context is the document itself.

Set `PENCIL_CLEANUP_MODEL` to change the model, or `PENCIL_CLEANUP=off` to skip
the pass entirely. With no key it is skipped and the raw transcript stands.

The clip waits in `.clips/` — dot-prefixed, so every scanner here already skips
it. **A clip is not a document and never appears in the change feed.** It is
deleted the moment it has been transcribed, whether or not the text was any good.

The provider is chosen by the environment: `PENCIL_STT_PROVIDER` when set,
otherwise whichever of `DEEPGRAM_API_KEY`, `ELEVENLABS_API_KEY` or
`OPENAI_API_KEY` is present, in that order. `PENCIL_STT_MODEL` overrides the
default model. **The key lives here and never reaches the iPad** — which is the
main reason the relay does this rather than the device.

Status codes carry the distinction the device acts on: `501 not_configured`
means no key is set and retrying will not help; `502 provider_failed` means try
again later. Both leave the iPad's draft standing, which is true of every failure
path in this feature.

The provider call is a blocking request handled in a worker thread. That is
deliberate: the iPad is draining a background queue and nobody is waiting on it,
so one request per comment buys a design with no job store and nothing to poll.

## 4c · Narration — a document you can listen to

```
POST /v1/documents/{folder}/narration   {"depth": "standard", "hosts": 2}
  → 202 {"state": "working"}
GET  /v1/documents/{folder}/narration
  → {"state": "ready", "minutes": 14.2, "turns": 38, "bytes": 6_812_400,
     "scriptModel": "gpt-4o", "voiceModel": "eleven_multilingual_v2",
     "provider": "elevenlabs", "missedSections": []}
```

It writes `narration.mp3` into the document's bundle, then tells the index
(`note_file_added`), and the change feed then advertises it with size and hash like every
other file. The device fetches it on its next scan.

**Both steps, and the second one is not optional.** `reconcile()` adopts bundles it has never
seen and deliberately skips a directory it already knows, so a file written *inside* an
indexed document is invisible to it; and the feed answers from `documents.seq`, so a device
that has already seen the document never asks again. Writing the bytes and re-stamping the
document are one call for that reason — either half alone delivers nothing. See `docs/05-file-contracts.md` § `narration.mp3` for why it is not a
*pinnable* file.

**Not verbatim, and not a summary.** A two-host adaptation that covers every section in the
document's own order, keeps the names, numbers and argument, and drops the apparatus —
footnote markers, reference lists, gridlines, captions that only mean anything next to a
figure. `depth` sets how much detail survives, never what gets skipped: `brief` aims at a
quarter of the document's reading time, `standard` at a half, `deep` at three quarters.
`hosts` is 1 or 2.

**Made in two stages.** A model writes the script from `source.md`; then each turn is spoken
by `POST /v1/text-to-speech/{voice_id}`, with `previous_text` and `next_text` from the
neighbouring turns so the joins carry prosody rather than resetting it. The MP3 frames are
appended byte-wise. That is deliberate and not laziness: this relay boots with nothing
installed but Starlette, and pulling in ffmpeg to join same-format frames is a dependency for
a problem every player already tolerates. If a join is ever audible, ffmpeg via the Railway
build is the escalation — a config change, not a redesign.

**ElevenLabs' own podcast API is not what this uses, on purpose.** GenFM
(`POST /v1/studio/podcasts`) does exactly this, and its docs say the Studio API is available
*only upon request* through sales. Building the feature on something that may 403 is worse
than writing the script ourselves — and writing it ourselves is what makes `depth` ours, and
what lets one pipeline serve one host or two.

**The failure this would have quietly** is a narration that sounds fluent and silently drops
the document's third section. It is not hypothetical: measured on a real 4,700-word paper,
the first draft dropped fourteen of forty headings at `standard` and came in at half the
requested length. So the script is checked against the source's headings, and if any are
missing the model is asked again — handed its own draft, the list of what it left out, and
the word count it undershot. The revision is kept **only if it covers more**, and it repeats
while each pass keeps improving, up to a backstop of three. A repair that gains nothing ends
it, and one that fails outright leaves the previous draft standing.

Stopping at a single pass was leaving coverage on the table: on that same paper, one repair
took fourteen missing headings down to nine — still improving when it was cut off. All of it
happens before a single character is spoken, because speech is the expensive stage and a
script call is cheap next to speaking thirty turns.

`missedSections` is what survives that. It is reported rather than enforced beyond the one
repair: a heading a host legitimately paraphrased is not a bug, a narration missing two
sections is worth far more than no narration, and a caller that gets a non-empty list can
decide.

**Config**, following the STT precedent exactly. `OPENAI_API_KEY` writes the script and
`PENCIL_NARRATION_SCRIPT_MODEL` overrides that model. Speech goes to whichever of
`ELEVENLABS_API_KEY` or `OPENAI_API_KEY` is present, in that order, or to
`PENCIL_TTS_PROVIDER` when it names one; `PENCIL_TTS_MODEL`, `PENCIL_TTS_HOST_VOICE` and
`PENCIL_TTS_GUEST_VOICE` override the rest. **The keys live here and never reach the iPad**,
which is the same reason the relay does the transcribing.

**The state machine** is a `.narration.json` sidecar — dot-prefixed, so every scanner here
already skips it, and it never appears in the feed:

| `state` | Means |
|---|---|
| `none` | no sidecar and no file; nothing has been asked for |
| `working` | a generation is running; a second `POST` returns 202 and starts nothing. It also carries `stage`, `done` and `total`, rewritten on every turn — that heartbeat is what makes it expire safely (below) |
| `ready` | the audio is written whole, *then* this was written — so a reader that sees `ready` is looking at a complete file |
| `unconfigured` | no key is set; retrying will not help |
| `failed` | `error` says why; retrying might help |

A missing sidecar beside an existing `narration.mp3` reads as `ready`, so a file restored by
hand is not invisible.

**A `working` state expires after ten minutes of silence — not after ten minutes.** The
distinction is the whole mechanism. A generation runs in a worker thread, so a deploy, a
crash or an eviction takes it with no chance to write anything, and `working` with no expiry
strands the document forever: the reader is told it is being made, and the guard against a
second generation refuses to start the one that would fix it.

The first version of this used a wall-clock hour, and that was wrong. A 35,000-character
paper is tens of sequential provider calls and legitimately runs for the best part of an
hour; one was reaped at the limit and nobody could say whether it had still been alive.
Elapsed time cannot tell a slow generation from a dead one. Silence can: a live generation
rewrites `progressAt` on every turn, and a dead one stops instantly. Ten minutes is several
times the slowest single turn, so a live one never trips it.

The same heartbeat is what the iPad shows. It says "Recording — 12 of 34" rather than naming
a duration, because counting turns is a true thing to say and "a few minutes" was a guess
that a long document made wrong by a factor of ten.

Generation is a blocking call in a worker thread, like the clip route and for the same
reason: nobody is waiting on it. The iPad asks and returns immediately, and the audio arrives
on a later scan exactly as a document does — which is what keeps the reader off the network's
clock (CLAUDE.md non-negotiable 1).

**Cost is worth knowing before narrating a library.** ElevenLabs bills one credit per
character on `eleven_multilingual_v2`. A `standard` narration of a 5,000-word paper is
roughly fifteen minutes, about 15,000 characters, about an eighth of a $22 Creator month.
That is why the MCP tool's description names the price of `deep`.

## 4d · Revising and withdrawing — a sender's second thoughts

A sender gets two things wrong often enough to need a verb for each: the document (a
mistake, or something it wanted to add) and the decision to send it at all. Both act on a
bundle that already landed, by folder name — the id `send_to_ipad` returned — and the MCP
tools `revise_on_ipad` and `remove_from_ipad` are these two routes with the same storage
layer underneath (`core.revise_inbox_bundle`, `core.remove_inbox_bundle`).

```
POST /v1/documents/{folder}/revision   {"content": "…", "mode": "append", "title": "…"}
  → 200 {"folderName": "…", "title": "…", "mode": "append", "seq": 418,
         "revisedAt": "2026-08-19T09:00:00Z", "removed": ["narration.mp3"]}
DELETE /v1/documents/{folder}
  → 200 {"folderName": "…", "seq": 419}
```

**A revision rewrites `source.md` in place.** `replace` takes the whole document again;
`append` takes only the new section and adds it after a blank line. The title changes only
when one is passed. Everything derived from the previous text goes with it — `document.pdf`
and `sourcemap.json`, because the iPad prefers a PDF it is given over one it renders and a
stale one would hide the new text; `narration.mp3` and its sidecar, because a narration is
a cache of the source it was read from (`docs/05` § `narration.mp3`). They go *first*, so a
failure half way leaves a bundle that still reads from its old markdown, never one whose PDF
disagrees with it. `meta.json` gains `revisedAt`. Only a markdown document can be revised:
a PDF sent by address has no text to change, and the answer is `400 invalid_input` — remove
it and send it again.

**Then the index is told**, the third way a document's files change and the one neither of
the other two covers. `reconcile()` adopts whole bundles and skips a directory it already
knows; `note_file_added` records one file the server wrote. A revision rewrites files the
index already describes *and removes some*, so `note_bundle_rewritten` rebuilds the file
rows from the directory, re-reads the title, and re-stamps the document — a device that had
caught up sees it again with the new sizes and hashes, for the reason § 4c gives. Hosted
inside the relay, the MCP tools reach the same index (`server.py` § `_index`); against a
plain folder there is no feed and nothing to tell.

**What the iPad does with a revision** it already did: `isPinnedAndCurrent` says no, the
document is downloaded, verified and pinned again, and `DocumentStore.upsert` re-renders the
pages under the reader's marks — ink, comments, reading position and filing all stay, which
is what the folder transport's "same folder, newer contents" case always meant. It says
"*title* was updated by the sender" in the library's status line (`SyncEvent.revised`), so a
document that changes under someone's ink is never a document that changed silently.

What that costs, and the tool description says so: ink is kept **per page**. `append`
leaves the earlier pages exactly as they were, so every mark stays on the text it was drawn
on. `replace` can re-paginate, and a change in the middle of a document can leave a mark on
a different passage. Comments are safe either way — they anchor on quoted text, never on a
position (CLAUDE.md non-negotiable 5). So: `append` for an addendum; `replace` when the
document is wrong and the reader has not annotated it much.

**A withdrawal is a tombstone, and on the iPad a tombstone archives.** The relay deletes the
bundle and the feed carries `deletedAt`; the iPad moves its copy to Archived and deletes
nothing — not the pinned bytes, not the ink, not the comments. The reader can restore it,
and only the reader can purge it (`docs/02-spec.md` § S6: the user decides what leaves the
device, the system never does). A sender's mistake must not be able to cost a morning's
annotations. A document that had not reached the iPad yet never will; one the reader had
already archived, or never received, is left exactly as it is. The outbox is never touched:
a review already sent back is the reader's work and stays listable.

**The idempotency key outlives the document.** `document_id` is UNIQUE and a tombstone keeps
the row, so a re-send carrying a withdrawn document's id answers `409 document_removed`
rather than "already here" — swallowing the re-send silently is the one failure this API is
built to avoid. Send it again without a `documentId` to make a new document.

**Re-stamped is not revised.** The relay re-stamps a document's sequence number whenever it
changes what the feed says about it, and adding a narration (§ 4c) is one such change with
the four pinnable files untouched. The iPad used to re-download, re-copy and re-ingest the
document to find that out. The pinned sidecar now records the hash of every file it
verified, and a feed entry whose declared hashes match is current whatever its number
(`RemoteDocumentPinner.isPinnedAndCurrent`) — which is also what lets the iPad say
"revised" and mean it. A copy pinned before hashes were recorded answers by number alone,
as it always did, and is announced as an arrival rather than as a revision it might not be.

---

## 5 · Idempotency

`meta.json`'s `id` is the key for documents. It is already a minted UUID and already the
correlation key in `review.json` and `manifest.json`, so nothing new was invented. **Send
the same id to retry; send no id to mean a second document.** Idempotency is about
retrying one call, not deduplicating intent. A retry never *changes* a document: to change
one, revise it (§ 4d).

`folderName` is derived and *server-allocated*, using the same `-2`/`-3` collision ladder
as the folder transport used, because two callers can want one name and only the server can
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
| `PENCIL_STT_PROVIDER` | Optional: `openai`, `elevenlabs` or `deepgram`. Otherwise the first of `DEEPGRAM_API_KEY`, `ELEVENLABS_API_KEY`, `OPENAI_API_KEY` that is set (§ 4b). An ElevenLabs key needs the *speech to text* permission, which one made with the default scopes does not have; an OpenAI key needs credit behind it. Either failure is a `502` to the iPad and one line in this service's log. |
| `PENCIL_STT_MODEL`, `PENCIL_CLEANUP_MODEL`, `PENCIL_CLEANUP` | Optional. The transcription model, the correction model, and `off` to skip the correction pass (§ 4b). The correction pass uses `OPENAI_API_KEY` whichever provider transcribes. |
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
