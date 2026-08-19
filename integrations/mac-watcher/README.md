# Mac-side outbox watcher

A small daemon that runs on the user's Mac, watches `<sync root>/outbox/` for finished
review bundles, works out where each review should go by reading the originating
document's `meta.json`, and delivers it back into the conversation it came from.

It is the piece `docs/06-integrations.md` describes as "a small Mac-side helper" — the
one that exists because firing a poke-only scheduled task bound to a Cowork session needs
account-level access that the iPad does not have.

Python 3.9+, standard library only. No pip install, no dependencies.

---

## ⚠️ Nothing here has been verified against a real Mac

This code was written and tested in a Linux container. **Not one delivery route has been
run against a real `claude` binary, a real Cowork session, or a real scheduled task.**
`docs/08-open-questions.md` question 7 already flags two of them as needing
re-verification before M6, and that re-verification has not happened.

| Route | Status | What is actually unknown |
|---|---|---|
| `poke` | **Unverified, and the command shape is a guess** | `docs/06` says firing the trigger needs account-level access but never says what invokes it. The default command `claude trigger fire {triggerId} --text {text}` is a placeholder chosen so the plumbing has something to render. Expect to change it. |
| `checkin` | Verified by construction | Does nothing on purpose, so there is nothing to get wrong. The session collects the review on its own schedule; the watcher must not also deliver it. |
| `cloud` | Unverified | `claude --cloud <session-id> -p "<review>"` is quoted from `docs/06`. Whether the flag exists, whether it accepts a session id positionally, and whether it queues rather than erroring on a live session are all untested. |
| `resume` | Unverified | `claude -p "<review>" --resume <session-id>` is quoted from `docs/06`. Untested. |
| `resume` busy-detection | **Heuristic, almost certainly wrong as shipped** | There is no documented way to ask whether a local session is running. The default probe is `pgrep -x claude`, which will miss a session running as `node .../cli.js`. See "Busy detection" below. |
| `codex` | Unverified | `docs/06` says only that `codex resume` has "equivalent semantics". The flags are invented. |
| `none` | Verified by construction | Logs and leaves the bundle alone, which is the whole behaviour. |

Everything the daemon does *around* the routes — discovery, completeness, the settle
delay, deduplication, retry, backoff, the ledger, `--dry-run` — is covered by 90 unit
tests that run and pass in this container. It is only the six commands at the very edge
that are unproven.

### Test these first, in this order

1. **`--dry-run` against a real bundle.** `pencil-watcher --dry-run --once` prints the
   exact argv it would execute and writes nothing. Confirm the route it picks matches
   what `meta.json` says, and confirm the command looks like something you could paste
   into a terminal.
2. **Paste that command into a terminal yourself.** If it fails there, it will fail here.
   Fix `watcher.routes.<name>.command` in the config until the pasted command works.
   That is why the commands are config and not code.
3. **`cloud`, then `resume`.** They are the two quoted verbatim from `docs/06`, so they
   are the most likely to be right and the cheapest to check.
4. **`poke` last**, because it is the one whose invocation is not written down anywhere.
   If poke turns out not to be fireable from a shell at all, disable the route
   (`"poke": {"enabled": false}`) and fall back to route 2, the scheduled check-in —
   which `docs/06` already calls the v1 default and which needs no daemon.
5. **Busy detection.** Start a local `claude` session, run `pgrep -x claude`, and see
   whether it finds anything. It probably will not.

---

## What it does, in order

1. Every `pollIntervalSeconds`, list `outbox/*.review/`.
2. Skip anything that is not whole yet — see "Completeness" below.
3. Hash the bundle. If `<bundle path>#<hash>` is already in the ledger as delivered,
   skipped, held or exhausted, do nothing.
4. Resolve the return path from the originating document's `meta.json`.
5. Pick the route adapter for that return path and hand it the review text.
6. Record the outcome in the ledger. Failures retry with exponential backoff; a running
   local session defers and is retried until the session frees up.

### Why polling, not FSEvents

Polling is the correct mechanism here, not a compromise made for simplicity.

The sync folder is a file-provider folder — iCloud Drive by default (`docs/08` q2). A
file provider materialises a directory entry before the bytes behind it exist, delivers
files in whatever order the transfer completes, and may not emit anything at all for an
item that was evicted and later re-downloaded. FSEvents reports what the local filesystem
did, which for a provider-backed folder is not the same thing as what arrived. You get
the directory-created event and then nothing useful, or a burst of coalesced writes that
tell you no more than "something changed in there".

A poll plus a settle delay asks the only question that matters — *is this bundle whole
and has it stopped changing?* — and gets the same answer regardless of how the files got
there. It has no bindings to install, no watch-descriptor limits, and no way to miss an
event while the daemon was asleep. The iPad app polls for exactly this reason. So does
this.

The cost is latency bounded by `pollIntervalSeconds` (default 15s) on a path where the
user has already put the iPad down.

### Completeness — never acting on half a bundle

`docs/04` F5 has the iPad write the bundle to a sibling `.tmp` directory and rename, so
the directory appears atomically on the iPad's own filesystem. That guarantee does not
survive the sync hop. A bundle is only processed when all of the following hold:

- `manifest.json` exists and parses as a JSON object — a partially written file does not
  parse, which is precisely the signal wanted;
- `manifest.json` does not say `"complete": false`;
- `review.md` exists;
- every file the manifest lists exists;
- a `(path, size, mtime)` fingerprint of the whole directory is unchanged across
  `settleSeconds`;
- **and the completeness check passes again after that delay** — because the manifest can
  land before the ink PNGs, and a PNG can still be growing after the manifest lands.

> **Assumption:** `docs/05` lists `manifest.json` in the bundle but does not specify its
> schema. This code reads an optional `files` array (of strings, or of objects with a
> `path`/`name`/`file` key) and an optional `complete` boolean, and falls back to
> requiring `review.md` when neither is present. Any manifest schema that keeps a file
> list works unchanged. If the iPad unit settles on something different, the only
> function to change is `manifest_required_files` in `pencil_watcher/bundle.py`.

### Deduplication

The ledger is a JSON file at `~/.pencil-loop/watcher-ledger.json`, keyed on **bundle path
plus content hash**.

It is deliberately *not* inside the sync folder. That folder is a published contract
(`docs/05`) shared with the iPad app and with anything else that can write a file; daemon
bookkeeping does not belong in it, and it would sync to every other device and start
races. Written atomically via temp file plus `os.replace`.

Because the key includes the content hash, a bundle that is edited and re-synced is a new
entry and gets delivered again, while the same bundle seen a thousand times is delivered
once.

### Failure

A failed delivery **leaves the bundle untouched** — the watcher never writes into the
sync folder, ever — logs the reason, and schedules a retry at
`retryBase * retryFactor^(attempt-1)`, capped at `retryMaxSeconds`. After `maxAttempts`
the bundle is marked `exhausted`: it stops being retried, it is logged at ERROR with what
to do about it, and it shows up in `--list` with a non-zero exit code so a shell check can
notice.

`--forget <bundle>` drops the ledger entry and the bundle is picked up again on the next
poll.

### Route 5 — the running local session

`docs/06`: *"Running local session: no external injection is possible; it must be idle.
The watcher holds the bundle and fires when the session frees up."*

That is implemented as a `deferred` ledger state. A deferral backs off the same way a
failure does but caps at `deferMaxSeconds` (default 5 min) and **never exhausts**, because
a busy session becoming free is a matter of when, not whether. The bundle is held, not
dropped and not delivered.

---

## Install

```
cd integrations/mac-watcher
./install.sh
```

That writes `~/Library/LaunchAgents/co.pencil-loop.watcher.plist` from the template in
`launchd/`, substituting your `python3` path and this directory, then bootstraps it.
It runs at login and restarts if it dies. Re-running `install.sh` replaces the agent
rather than duplicating it.

Nothing is copied anywhere: the agent imports the package straight out of this directory,
so `git pull` plus `launchctl kickstart -k gui/$UID/co.pencil-loop.watcher` is the whole
update procedure.

**Check it:**

```
launchctl print gui/$UID/co.pencil-loop.watcher | head -20
tail -f ~/.pencil-loop/logs/watcher.log
```

**Uninstall:**

```
./uninstall.sh            # removes the agent, keeps config/ledger/logs
./uninstall.sh --purge    # also deletes the ledger and logs
```

`--purge` deletes the ledger, which means every bundle still sitting in `outbox/` is new
again and will be delivered a second time. Only purge if that is what you want.

### launchd notes

- The agent does not fork or daemonise. launchd requires a process that stays in the
  foreground; a self-backgrounding process gets restarted forever.
- launchd agents get a minimal `PATH`. The plist sets one that covers Homebrew,
  `/usr/local/bin`, `~/.local/bin` and `~/.claude/local`. If `which claude` on your Mac
  shows something else, add it to the `PATH` value in the plist.
- Full Disk Access: if the sync folder is under iCloud Drive, macOS may need
  `python3` (or your terminal, for foreground runs) granted access in
  System Settings → Privacy & Security. A permission failure shows up as an empty
  `outbox` listing, not an error.

---

## Config

`~/.pencil-loop/config.json`. See `config.example.json` for a complete one.

> **Assumption:** the path `~/.pencil-loop/config.json` and the top-level `syncRoot` key
> are the convention being established by the Cowork skill unit
> (`integrations/cowork-skill/`). This unit assumes that convention rather than defining
> it, and reads its own settings from a `watcher` object inside the same file so the two
> never collide. `_SYNC_ROOT_KEYS` in `pencil_watcher/config.py` is kept in step with
> `SYNC_ROOT_KEYS` in `integrations/cowork-skill/scripts/send_to_reader.py`, which is the
> unit that writes this file: `syncRoot`, `readerFolder`, `syncFolder` and `folder` are
> all accepted, as is the `PENCIL_LOOP_READER_FOLDER` environment variable.

| Key | Default | Meaning |
|---|---|---|
| `syncRoot` | *(required)* | The folder containing `inbox/` and `outbox/`. `~` and `$VARS` expand. |
| `watcher.pollIntervalSeconds` | 15 | How often to scan `outbox/`. |
| `watcher.settleSeconds` | 5 | How long a bundle must stop changing before it counts as arrived. |
| `watcher.retryBaseSeconds` | 30 | First retry delay after a failure. |
| `watcher.retryFactor` | 2 | Backoff multiplier. |
| `watcher.retryMaxSeconds` | 1800 | Backoff ceiling. |
| `watcher.maxAttempts` | 6 | Attempts before a bundle is marked exhausted. |
| `watcher.deferBaseSeconds` | 30 | First re-check delay when a local session is busy. |
| `watcher.deferMaxSeconds` | 300 | Ceiling for busy re-checks. Deferrals never exhaust. |
| `watcher.commandTimeoutSeconds` | 120 | Kill a delivery command that hangs. |
| `watcher.maxInlineChars` | 40000 | Above this the review is not inlined; the delivered text points at `review.md` instead. |
| `watcher.busyCommand` | `["pgrep","-x","claude"]` | Exit 0 means "a local session is running". `null` disables the check. |
| `watcher.stateDir` | config's directory | Where the ledger and logs live. |
| `watcher.routes.<name>.enabled` | `true` | Turn any route off. |
| `watcher.routes.<name>.command` | see table below | The argv to run. Placeholders below. |

### Command templates

Placeholders are substituted **per argument, literally**. The review text is one argv
element and is never passed through a shell, so a review containing quotes, backticks or
newlines cannot become shell syntax.

`{text}` · `{sessionId}` · `{triggerId}` · `{bundlePath}` · `{reviewPath}` ·
`{replyPath}` · `{slug}`

| Route | Default command |
|---|---|
| `poke` | `claude trigger fire {triggerId} --text {text}` — **a guess, see the warning above** |
| `cloud` | `claude --cloud {sessionId} -p {text}` |
| `resume` | `claude -p {text} --resume {sessionId}` |
| `codex` | `codex resume {sessionId} {text}` |
| `checkin`, `none` | no command; these routes deliberately run nothing |

### Busy detection

`pgrep -x claude` is a placeholder. It matches a process whose executable is exactly
`claude`; a Claude Code session running under Node will not match. Better candidates once
someone can look at a real Mac:

```json
"busyCommand": ["pgrep", "-f", "claude .*--resume"]
"busyCommand": ["/bin/sh", "-c", "pgrep -fl 'cli.js' | grep -q claude"]
```

Any command works — exit 0 means busy. Set it to `null` to always attempt delivery, which
is the right setting if `claude --resume` turns out to fail cleanly on a busy session
(in which case the ordinary retry path already covers it).

---

## Route table

Priority order is `docs/06`'s, resolved from `meta.json`'s `origin`:

| `returnPath.type` | `origin.kind` | Adapter | Behaviour |
|---|---|---|---|
| `poke` | `cowork` | `PokeRoute` | Fires the poke-only scheduled task recorded as `triggerId`, delivering the review as an ordinary user turn in the same thread. Fails without running anything if no `triggerId` was recorded. |
| `checkin` | `cowork` | `CheckinRoute` | **No-op.** The session has its own scheduled check-in and collects the review itself; delivering as well would double-deliver. Recorded as `skipped`. |
| `cloud` | `claude-code` | `CloudRoute` | `claude --cloud <id> -p <text>`. |
| `resume` | `claude-code` | `ResumeRoute` | Probes for a running local session first. Idle → deliver. Running → defer and hold. |
| `resume` / `cloud` | `codex` | `CodexRoute` | Same shape through the `codex` binary. `origin.kind` wins over the type. |
| `none`, absent, or unrecognised | any | `NoneRoute` | Logs it and leaves the bundle alone. The iPad's share-sheet fallback covers this case and the watcher must not invent a route. |

Return path resolution, most specific first:

1. `manifest.json`'s own `origin` block, if the iPad copies it into the bundle;
2. `inbox/<slug>/meta.json`, derived from the bundle's folder name — the normal case;
3. any `inbox/*/meta.json` whose `id` matches `review.json`'s `documentId`, which covers a
   renamed or re-dated inbox folder.

### The adapter interface

Each route is one class in `pencil_watcher/routes.py`:

```
name             str                        matches returnPath.type
enabled(config)  -> bool                    per-route config switch
plan(ctx)        -> list[str] | None        the argv it would run; None = runs nothing
precondition(ctx, runner) -> Outcome | None non-None stops before running anything
describe(ctx)    -> str                     one line for logs and --dry-run
deliver(ctx, runner) -> Outcome             performs it
```

`Outcome.status` is one of `delivered · skipped · held · deferred · failed` and maps 1:1
onto ledger statuses. `DeliveryContext` carries `bundle`, `return_path`, `text`, `config`.

No adapter touches `subprocess` directly; they all go through the `CommandRunner`
interface, which is what makes `--dry-run` total rather than best-effort and lets the
tests run without a `claude` binary anywhere.

---

## The delivered text

The watcher builds one block of text per bundle: a header, the contents of `review.md`
(or a pointer to it if it exceeds `maxInlineChars`), a note about the ink images if there
are any, the bundle path, the anchor instruction from `docs/05`, and the reply-channel
instruction.

**The reply channel.** `docs/04` F6 and `docs/05` describe an agent writing
`outbox/<slug>.review/reply.md`, which the iPad app watches for. Writing that file is the
receiving agent's job, not the watcher's — the watcher only asks for it, by naming the
exact absolute path in the delivered text.

All of that wording lives in `pencil_watcher/prompts.py` as named constants —
`REPLY_CHANNEL_INSTRUCTION`, `DELIVERY_HEADER`, `ANCHOR_INSTRUCTION`, `BUNDLE_POINTER`,
`TOO_LARGE_NOTICE`, `INK_NOTICE`. Wave 3 tunes them there, in one place.

---

## Running it by hand

```
cd integrations/mac-watcher

python3 -m pencil_watcher --dry-run --once      # show what it would do, do nothing
python3 -m pencil_watcher --foreground          # debug: verbose, attached to the terminal
python3 -m pencil_watcher --once                # one pass, then exit
python3 -m pencil_watcher --list                # print the ledger; exit 1 if anything is exhausted
python3 -m pencil_watcher --forget outbox/2026-08-18-plan.review
```

| Flag | Effect |
|---|---|
| `--dry-run` | Prints the exact argv for every route it would take. Starts no process and writes no ledger entry, so it is repeatable and never consumes a delivery. |
| `--foreground` | Debug mode: stays attached to the terminal with DEBUG-level logging, including a line per poll for bundles that are not ready and why. The daemon never forks in either mode — launchd needs it in the foreground — so this differs only in verbosity and in being run by you rather than by launchd. |
| `--once` | A single pass. Does a priming scan, waits out the settle delay, then the real scan — the settle state is in memory, so without the priming pass a one-shot run could never consider anything settled. |
| `--sync-root`, `--interval`, `--settle` | Override config for one run. |
| `--list`, `--forget` | Inspect and edit the ledger. |

Logging goes to stdout **and** to `~/.pencil-loop/logs/watcher.log` (rotating, 2 MB × 5),
one timestamped line per event. Newlines inside a message are escaped so one event really
is one line.

---

## Tests

```
cd integrations/mac-watcher
python3 -m unittest discover -s . -t .
```

90 tests, no dependencies, nothing shells out — every route test uses
`FakeCommandRunner`. They cover: ledger deduplication (including across a restart, and
that an edited bundle is a new key); the settle delay against a bundle written
progressively in the order a file provider would deliver it; route resolution for every
`returnPath.type` plus the `codex` kind override and unknown types; retry, exponential
backoff, exhaustion and requeue; deferral of a busy local session and delivery once it
frees up; and that `--dry-run` produces no side effects at all — no process, no ledger,
no change to the bundle's mtimes.

---

## Files

```
pencil_watcher/
  cli.py        argument parsing, wiring
  config.py     ~/.pencil-loop/config.json
  bundle.py     discovery, completeness, settle, hashing, return-path resolution
  ledger.py     dedupe, retry state, backoff
  routes.py     the six adapters and the selector
  runner.py     CommandRunner: subprocess, dry-run, and the test fake
  prompts.py    every piece of delivered wording, as named constants
  watcher.py    the poll loop
  logsetup.py   stdout + rotating file, one line per event
tests/          90 unittest tests
launchd/        the plist template
install.sh      writes and bootstraps the launchd agent
uninstall.sh    removes it
```
