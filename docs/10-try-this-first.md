# 10 · Try this first

Before M0. Two weeks, 30–45 minutes of setup, no code. It answers the only question this
spec can't: whether you actually pick up the iPad.

## The setup

1. **Obsidian on the Mac** — install the Local REST API plugin, copy the key. Put the
   vault in iCloud Drive so it syncs to Obsidian on iPad.
2. **Add `obsidian-mcp-server`** to Claude Code's MCP config via `npx`. It exposes
   read/write/patch tools against the vault.
3. **Start Remote Control** on the Mac: `claude remote-control`, scan the QR from the
   Claude iOS app. Keep the session alive in tmux.

## The loop

- Ask Claude to write to `Inbox/draft.md`. It appears in Obsidian on the iPad in seconds.
- On the iPad, screenshot the note and mark it up in Apple's built-in Markup — or use the
  InkedMark plugin to ink directly in the note.
- In the Claude app's Code tab, attach the marked-up image to your Remote Control session
  and dictate: "apply my handwritten notes to `Inbox/draft.md`."
- **Remote Control passes attached photos straight into the live session**, so the model
  reads your ink visually and patches the file via MCP. It re-syncs to the iPad.

## What you learn

This scores about **7/10** against the app in this spec. It gives you a true same-session
round trip, ink read accurately by vision, and dictation for free.

What it can't do maps exactly onto what this app is for: no anchoring of comments to
positions, a manual screenshot-and-attach every cycle, the Mac must stay awake, no
offline, and no "I'm done, go" trigger.

**If you reach for the iPad unprompted during those two weeks, build it. If you don't,
you've saved four weekends and learned the same thing.**
