# 01 · Design principles

**Read this before writing any view code.** The brief for the UI is one line: *it should
look like Apple made it.* That is a constraint, not a compliment — it rules out most of
what a designer would reach for.

## The test

If someone opens a screen and can tell that it was designed, it's wrong. The target is
the feeling of Books, Notes, Preview, and Files: unremarkable chrome, generous space, and
all the visual interest coming from the user's own content.

## Rules

**1. System everything.**
SF Pro via `.font(.body)` etc — never a custom font, never a hardcoded point size.
SF Symbols only — never a custom icon. System colours (`.label`, `.secondaryLabel`,
`.separator`, `.systemGroupedBackground`) — never a hex value except the ink palette.
Materials (`.regularMaterial`, `.thinMaterial`) for anything floating.

**2. One accent colour.** System blue, or the user's system-wide accent. It appears on
interactive text, the send button, and nothing else. Ink colours are the only other
saturated colour in the app, and they belong to the user, not the brand.

**3. Standard containers.**
`NavigationSplitView` — sidebar is the library, detail is the reader. Not a custom
layout. Sheets use `.presentationDetents`, with a grabber. Lists are `List` with
`.insetGrouped`. Toolbars are `.toolbar`, not a hand-rolled bar.

**4. Content-first reading.** In the reader, chrome auto-hides on scroll and returns on
tap, exactly like Books. The page goes edge to edge. No persistent sidebar, no floating
palette, no visible tool picker until the user summons it.

A tap on the page is a *finger* tap, because a Pencil tap on the page is a dot. So the
Pencil gets the same tap in the surround beside the page, where there is no paper and
nothing to draw on — otherwise the toolbar, and with it the way back to the library, is
unreachable to somebody holding a pen and nothing else. The library's own "Library" button
sits in that toolbar for the same reason: the system's edge swipe cannot be the way back
when a Pencil dragged across the page is ink.

**5. No custom gestures for anything important.** Long-press to comment is the one
addition, and it's discoverable because a Pencil long-press does nothing else. Everything
else is a tap, a scroll, or a standard swipe. Pencil Pro squeeze is a shortcut for people
who already know it, never the only way to reach a feature.

**6. Nothing branded.** No logo in the UI, no splash screen, no onboarding carousel, no
empty-state illustration. The empty library says "No documents" in secondary label
colour and offers the folder picker.

**7. Restraint in feedback.** Haptics: `.light` on Pencil Pro squeeze, `.success` when a
comment saves, nothing else. No animation that isn't a system transition. No sounds.

**8. Accessibility is not optional.** Dynamic Type throughout the app chrome. VoiceOver
labels on every control. The document itself is a PDF and doesn't reflow — that's the
accepted trade for stable ink — but the comment list, library and review sheet all must.

**9. Dark mode by page tint, not by inversion.** Offer White, Cream, Sepia and Grey as
page tints. Never invert a PDF's colours; render the page and tint it. App chrome follows
the system appearance normally.

*This rule used to ask for Books' four — White, Sepia, Gray, Night — and Night is the one
that cannot be had under the rest of the rule.* The wash is a multiply-blended rectangle
over the rendered page (`ReaderTintWash`); multiply can only darken, so a wash dark enough
to make a night page takes the black text down with it and leaves black on charcoal. Every
other route — inverting the raster, a `difference` or `exclusion` blend, `colorInvert()` —
is inversion by another name, and inversion is what this rule exists to forbid: it turns
figures into negatives, recolours syntax-highlighted code into a scheme nobody chose, and
makes graphite ink invisible on the page it was drawn on. Cream took its place in the
picker. A real Night needs the app to composite the page itself rather than letting PDFKit
draw it — see `docs/11-backlog.md` § B11.

**10. Fast beats pretty.** A page must be on screen in under 100ms from tap. Ink must
never drop a frame. If a nicety costs latency, cut the nicety.

## Specific choices

| Element | Decision |
|---|---|
| Library | Sidebar list, grouped by "Reviewing / Unread / Read". Row = title, source, page count, offline dot. Swipe to archive. |
| Reader | Full-bleed `PDFView`, `.singlePageContinuous`, chrome auto-hiding. |
| Tool picker | `PKToolPicker` in its floating iPadOS 27 form, summoned by a toolbar button, dismissed by tapping away. Never pinned. |
| Comment marker | A small filled circle in the page margin, accent-tinted, ~16pt. Not a speech bubble, not a number badge unless there are several on a line. |
| Comment popover | Standard `.popover` anchored to the touch point. Quoted excerpt in `.caption` secondary, live transcript in `.body`. |
| Review sheet | `.sheet` at `.large`, an inset-grouped `List` of comments, toggles as a `Section`, closing instruction as a `TextField(axis: .vertical)`, and a single prominent button. |
| Destination row | Shows the origin thread and whether the review lands in the same conversation. Always visible before sending. |
| Ink colours | Five: graphite, red, blue, green, yellow highlighter. Apple's Notes palette, not ours. |
