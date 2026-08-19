# First task

This used to say "build M0 only", and that instruction is superseded. The repository was
not built milestone by milestone: `Core`, `Storage`, `Sync`, `Ingest`, `Annotate`, `Export`
and the M6 integrations were written in parallel, and none of it has ever been compiled.
What is left is the screens in `AppUI` and, before anything else, a first build.

**Start with `FirstBuild.md`.** It is the whole first hour: push and read CI before opening
Xcode, the two edits to make first (your team ID, your bundle identifier), the errors this
code is expected to produce and the one-line remedy for each, and the order to fix modules
in so one failure in `Core` stops generating a hundred below it.

---

## What to check first

Before you change anything, work out the answers to these. They are the same questions the
original first task asked, and they are worth more now than they were then — the code
exists, so the answers are checkable rather than speculative.

1. **Does the package build at all?** `swift build --package-path PencilLoopKit`. The app
   target is irrelevant until this passes. Nothing in this repository has ever met a
   compiler.
2. **Which of `FirstBuild.md` § 3's expected errors did you actually get, and which ones
   did it miss?** The ones it missed are the interesting half — add them to that table as
   you fix them.
3. **What in the spec is wrong, ambiguous, or would be done differently?** Say it now
   rather than diverging quietly. `CLAUDE.md`'s working agreement is that the doc gets
   fixed in the same commit as the code, and the docs are already carrying a round of
   corrections found exactly this way.
4. **Which question in `docs/08-open-questions.md` is now blocking?** Four are still open.
   Q7 is the one that matters: the poke return path is built against a command nobody has
   confirmed exists.

## Then, on a device

The Simulator cannot answer any of this, and most of it is not unit-testable either. In
rough order of how much it would change the design:

- The Pencil long-press against the dot it draws first (`docs/02-spec.md` § S2). Top of the
  list.
- Code type at ~8.75pt on a real page, held at arm's length
  (`docs/03-architecture.md` § 1). If it is too small, the fix is a decision, not a bug.
- 60fps while inking a page carrying 300+ strokes, and the same while scrolling fast.
- Voice: 400ms to first token, and how well term-list correction rescues jargon.
- A document sent from Cowork arriving with no action beyond opening the app.

Small commits. After each, say what to test by hand on device — and write the by-hand
script into `FirstBuild.md` § 6, which is still empty.
