# Review — Auth refactor plan

Reviewed 18 Aug 2026, 21:14 · 3 comments · 2 inked pages
Origin: Cowork · "Q3 platform planning" · session 8f3c1d

## What I want done

Rework phase 2 with the shadow read, then re-scope the estimate.

## Comments

### 1 — page 1

> The migration runs in a single deploy, with no dual-write window.

No dual-write window means we can't roll back after cutover — I want a shadow read
for at least a day.

*voice, transcribed*

### 2 — page 2

> await refresh(session)   // no backoff

Infinite retry loop? Needs exponential backoff and a cap.

*handwriting, recognised*

## Handwritten pages

Pages 1 and 3 have handwritten marks attached as images: `ink/page-01.png`,
`ink/page-03.png`. Position carries meaning — arrows and circles refer to the text
they point at, and a strikethrough means delete. Read them alongside the comments
above rather than instead of them.

## How to locate these passages

Each quoted excerpt is exact text from the document you produced. Match on the quote,
not on a line number — the document may have changed since.
