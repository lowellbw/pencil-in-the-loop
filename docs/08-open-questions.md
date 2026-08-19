# 08 · Open questions

Ask before guessing. Each of these changes the build.

Some have since been answered by building the thing. Those are marked **settled**, with
what settled them; the rest are still live and still worth asking about.

**1 · Which iPad?**
An iPad Air (M2 or later) does everything in this spec — Apple Pencil Pro, iPadOS 27,
on-device speech and handwriting recognition. The one real difference from a Pro is the
60Hz display: no ProMotion. It's perfectly usable, but for an inking app 120Hz is the
biggest single contributor to how connected the pen feels. Worth knowing before buying.
*Does not change the build either way.*

**2 · Which folder, and which sync provider? — settled.**
Any folder the user picks, with iCloud Drive as the working assumption, and **no git
transport in v1**. Nothing in the app knows what is behind the folder; there is no commit
step and no provider-specific code. Working Copy still works if you want history — it
presents a repo as a folder like anything else — but the app will not stage or commit for
you. Settled by the sync layer, which assumes only file-provider behaviour: poll, pin,
verify.

**3 · Should the reply loop be in v1? — settled: it's in.**
`reply.md`, the Sent-screen reply view and "open as document" are built (`04-flows.md`
§ F6). It is what turns one review into a conversation, and it turned out to be small
because the reply takes the ordinary ingest path rather than a second one.

**4 · Ship the `send-to-reader` skill as fully automatic?**
The spec says the skill fires without asking — any document over ~400 words goes to the
iPad. That's the right default for making the flow invisible, but it will occasionally
send things you didn't want. Confirm you'd rather over-send than have to ask each time.

**5 · Handwriting recognition — surface it or hide it?**
Recognised handwriting is used for search and included in the review bundle. Should the
user ever *see* the recognised text and be able to correct it before sending, or does that
turn a fast gesture into a chore? The stated default stands and is what is built: hidden,
shown only in the review sheet where it can be edited. Change it only after using it —
this is a question about how often recognition is wrong enough to matter, and nobody knows
that yet.

**6 · Any interest in the marked-up page as a shareable artefact?**
Exporting the annotated PDF for a human colleague is trivially adjacent and not currently
specified. Worth 20 minutes if it's useful.

**7 · Re-verify before M6 — still open, and now the most urgent one here.**
Two things from the research may have changed: whether Claude Code's desktop plan-review
comments now actually reach the model (bugs #48945 and #49715), and the exact current
semantics of poke-only scheduled tasks bound to a Cowork session.

The second has got worse, not better. Building the watcher established that **no command
which fires a scheduled task is known to exist**; `integrations/mac-watcher/` runs on a
placeholder so the rest of the route could be built. The scheduled check-in is the v1
default and needs none of it, so nothing is blocked — but route 1 cannot be trusted, and
should not be a sender default, until someone names a real command and fires a real
trigger. Answering this is what settles it; nothing else will.
