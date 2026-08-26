---
name: send-to-reader
description: Send a document to the user's iPad reader so they can read it properly and mark it up with an Apple Pencil, and set up the path for their review to come back to this conversation. Use this whenever the user asks for something to read, review, look at later, or wants it "on the iPad"; whenever you have just produced a document longer than roughly 400 words — a plan, brief, report, research summary, postmortem, or spec; or whenever you have fetched or been given a PDF the user will want to read properly, such as a paper, a long article, or a report. Do not ask permission first — send it, then say in one line that it is on the iPad.
---

# send-to-reader

The user has an iPad app that watches a folder. Anything written into that folder's
`inbox/` appears in their reading library within seconds, readable offline, annotatable
with a Pencil and with voice comments anchored to passages. When they finish, the app
writes their review into the same folder's `outbox/`, and it comes back to this
conversation.

Your job is to put the document there, well-written for annotation, without being asked.

## When to run

Run this skill when any of these is true:

1. The user asks for something to read, review, look at later, or "on the iPad".
2. You have produced a document longer than roughly 400 words — a plan, a brief, a
   report, a research summary, a postmortem, a spec.
3. You have fetched or been given a PDF the user will want to read properly: a paper, a
   long article, a report.

**Do not ask permission.** Write it, then mention in one line that it is on the iPad. If
the user did not want it there, it cost them nothing — an unread row in a library.

Do not run this for short answers, code diffs, chat-length replies, or anything the user
is clearly reading right now in the conversation.

## Step 1 — Write the document to be annotated

This step comes first because it changes what you write, not just where you put it.

A document written to be annotated is a different document from one written to be
scrolled. The user will be holding it, marking margins with a pen, and speaking comments
at specific passages. Write accordingly:

- **Short paragraphs, one idea each, with a blank line between them.** Margin notes need
  somewhere to live. A dense page has nowhere to put a pen.
- **Number your sections, or give them clearly distinct titles.** A spoken comment has to
  be able to name its target — "in section 3" or "the rollback section". Sections called
  "Overview", "Details" and "More details" are useless for this.
- **No code block wider than about 76 characters.** Wider lines wrap on an A4 page and
  the wrap destroys the alignment the reader is using to follow the code.
- **Keep tables narrow, or use a list instead.** Three columns is usually the limit. A
  wide table becomes unreadable at page width, and there is no horizontal scroll on
  paper.
- **No nested bullets beyond one level.** Deep nesting reads badly on a page and gives a
  spoken comment no unambiguous handle to point at.
- Prefer prose to fragments. The user is reading carefully, not skimming a screen.

If the document already exists — you fetched a PDF, or the user handed you one — send it
as it is. Do not rewrite someone else's document. This guidance applies to documents you
author.

## Step 2 — Find the reader folder

The reader folder is a folder the user has connected in the Claude desktop app, and the
same folder the iPad app is pointed at. It contains `inbox/` and `outbox/`.

Its path is recorded in `~/.pencil-loop/config.json` under `syncRoot` — the same file
and key the Mac watcher reads, so one setup step configures both:

```json
{
  "version": 1,
  "syncRoot": "/absolute/path/to/the/connected/folder",
  "defaultReturnPath": "checkin"
}
```

Resolution order, highest first: an explicit `--folder` argument, the `PENCIL_SYNC_ROOT`
or `PENCIL_LOOP_READER_FOLDER` environment variable, then `syncRoot` in that config file
(`readerFolder`, `syncFolder` and `folder` are accepted as aliases). Other keys in the
file belong to other units — the script merges rather than overwrites.

Check it before writing anything:

```bash
python3 scripts/send_to_reader.py --check
```

That prints `{"ok": true, "folder": "…", "problems": []}` when the folder exists and has
both `inbox/` and `outbox/`.

**If it is not configured**, ask the user once — this is the only question this skill ever
asks:

> Which folder should I send documents to for reading on the iPad? It should be a folder
> you've connected in the Claude desktop app and pointed the iPad app at.

Then record it:

```bash
python3 scripts/send_to_reader.py --set-folder "/path/they/gave"
```

**If it is configured but wrong** — the folder is missing, or has no `inbox/` and
`outbox/` — say so plainly and stop. Do not create the folder, and do not guess at
another one. A document written to the wrong place is silently lost, and that is the
main way this skill fails:

> I couldn't send that to the iPad: `/path` has no `inbox/` folder, so it isn't the
> folder the reader app is watching. Which folder should I use?

## Step 3 — Put it with its kind

A library of forty loose documents is a library nobody opens. Groups are how the iPad's
sidebar gets sections: a group is nothing but a name written into `meta.json`, and
everything sharing that name is shown together under one heading.

The whole value of that is in the reuse, so find out what already exists before you decide
anything:

```bash
python3 scripts/send_to_reader.py --list-groups
```

That prints each group's name, how many documents are in it, when it was last used, and
the titles of its most recent few — enough to tell an "ML Papers" full of architecture
papers from an "ML Papers" full of hiring notes, which is a distinction the name alone will
not make.

**If this document's subject belongs to a group that is already there, pass that group's
name exactly as printed.** Copy it, character for character. Do not improve the
capitalisation, do not expand the abbreviation, do not make it plural. "ML Papers" and
"Machine Learning Papers" are two sections in the user's library and one subject in their
head, and the second one exists only because something decided the first was badly named.

**Create a new group only when nothing there matches**, and name it for the subject rather
than the occasion: "Attention Papers", not "Papers asked for on Tuesday". A group name is
read months later, next to twenty others.

**Do not ask which group to use.** The same reasoning as everywhere else in this skill: a
wrong guess costs the user one long-press to fix, and asking costs them an interruption on
every single send.

### When not to group at all

**A one-off document gets no group.** If the subject matches nothing that already exists,
and you have no reason to think a second document on it is coming, leave `--group` off.

This is the rule that keeps the feature working. A group holding one document is not a
group, it is a document with a longer name; a library where everything has one is a library
whose sections carry no information, and the user is back to scrolling a flat list.
Grouping earns its place by being the exception.

So: reuse a group freely — that is what they are for — but create one only when you can
name the second document that will go in it. Five papers on one subject in one sitting is
exactly that case, and it is the case this exists for. A single plan, brief or postmortem
usually is not.

Groups the user created or renamed on the iPad itself are not in that list — it reports
what has been sent — so treat it as what is known, not as everything that exists.

## Step 4 — Write the document

```bash
python3 scripts/send_to_reader.py \
  --title "Auth refactor plan" \
  --source /path/to/plan.md \
  --group "Attention Papers" \
  --session-id "<this Cowork session's id>" \
  --thread-title "<this conversation's title>" \
  --return-path checkin
```

Leave `--group` off for a document that belongs in no group, which is most of them.

Use `--stdin` instead of `--source` to pipe the markdown in. Add `--dry-run` to see the
folder name and `meta.json` that would be written, without writing them.

The script does the mechanical part and you should not do it by hand: slug generation,
collision suffixes, `meta.json` assembly, and the atomic write. It builds the bundle in a
hidden sibling `.tmp` directory inside `inbox/` and renames it into place, so the iPad's
watcher never sees a half-written document.

What lands on disk, per `docs/05-file-contracts.md`:

```
inbox/2026-08-18-auth-refactor-plan/
├─ source.md      the markdown you wrote
└─ meta.json
```

**You do not render a PDF.** The iPad app renders `source.md` to PDF on ingest, and emits
the source map that keeps annotations anchored to your text. Writing `document.pdf`
yourself is correct only when the source already *is* a PDF — one you fetched or were
given — in which case pass it to `--source` and the script copies it in as
`document.pdf`.

Folder names are `YYYY-MM-DD-<slug>`; slugs are lowercase, hyphenated, ASCII; a second
document with the same slug on the same day becomes `-2`, then `-3`.

`meta.json` records `origin.kind = "cowork"`, this session's id, the thread title, the
group when there is one, and the return path chosen in step 5. That is how the review
knows where to come back to. Pass the session id and thread title if you can get them — a
document without them is still perfectly readable, but the review will have to be
delivered by hand.

## Step 5 — Set up the return path

The review has to get back to this conversation. Two routes. Record whichever you used in
`meta.json` via `--return-path`, and use the same value for the whole document.

### `checkin` — scheduled check-in (the v1 default)

Create a scheduled task bound to **this session**, with a prompt like:

> Look in the reader outbox at `<syncRoot>/outbox`. If there is a review bundle
> newer than the last one you handled, read its `review.md` and the ink images it
> references, and act on the review in this conversation.

Then pass `--return-path checkin`. An hourly schedule is usually right; match it to how
soon the user said they would read it.

This is the default because it needs nothing installed. The cost is a delay of up to the
check-in interval.

### `poke` — poke-only scheduled task (better, needs the Mac watcher)

Create a scheduled task bound to this session with **no schedule of its own** — one that
exists only to be fired. Pass its id through:

```bash
--return-path poke --trigger-id trig_…
```

Firing it delivers the review into this session as an ordinary user turn, immediately,
with the whole conversation intact. Firing requires account-level access, so in practice
the Mac-side watcher (`integrations/mac-watcher/`, a sibling unit) watches `outbox/` and
fires it. **Only use `poke` if that watcher is installed** — a poke trigger nobody fires
is a review that never arrives.

### If neither is possible

Pass `--return-path none`. The user can always open the thread and say "read my review";
the app's Sent screen has a Copy button for exactly that. Say so in your one line, so
they know it is on them.

## Step 6 — Say one line

One line, at the end of your normal reply. Not a section, not a summary.

> Sent to the iPad — it's in your reading library as "Auth refactor plan". I'll pick up
> your review here.

If you used `--return-path none`, say instead: "…tell me when you've reviewed it and I'll
read it."

## Failure modes, in order of how much they cost

1. **Writing to a folder that isn't the reader folder.** Silent, total loss. This is why
   step 2 validates and stops rather than guessing.
2. **Writing a partial document.** Prevented by the script's atomic write. Do not
   assemble the bundle yourself with individual file writes.
3. **A poke trigger with no watcher to fire it.** The review sits in `outbox/` forever.
   Use `checkin` unless you know the watcher is installed.
4. **A document written for a screen.** It still arrives, it is just harder to annotate.
   Step 1 is the fix.
5. **A near-duplicate group.** "ML Papers" beside "Machine Learning Papers" splits one
   subject across two sections, and the user has to notice and merge them by hand. Step 3
   lists what already exists for exactly this reason: the list is cheap and inventing a
   name is not.
