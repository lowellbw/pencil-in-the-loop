"""The MCP surface: three tools over one folder.

Thin by design. Every decision that matters lives in ``core.py``; this
module only turns tool calls into those functions and shapes the replies.
"""

from __future__ import annotations

import os
from typing import Any

from . import __version__
from .config import resolve_sync_root
from .core import (
    ValidationError,
    list_review_bundles,
    read_review,
    write_inbox_bundle,
)

try:  # mcp >= 2
    from mcp.server.mcpserver import MCPServer as _Server
except ImportError:  # pragma: no cover - mcp 1.x fallback
    from mcp.server.fastmcp import FastMCP as _Server


AUTHORING_GUIDANCE = """
Write the document to be annotated by hand on an iPad, in the margins:

- Short paragraphs, one idea each, blank line between them.
- Numbered or clearly titled sections, so a spoken comment can name its
  target.
- No code block wider than about 76 characters, so nothing wraps on A4.
- Tables kept narrow, or replaced with lists.
- No nested bullets beyond one level.
""".strip()


server = _Server(
    name="pencil-in-the-loop",
    version=__version__,
    instructions=(
        "Send long documents to the user's iPad reader and read back the "
        "Pencil reviews they return. Everything is plain files in one "
        "synced folder, so these tools work whether or not the iPad is "
        "awake, online, or has ever run.\n\n" + AUTHORING_GUIDANCE
    ),
)


def _sync_root():
    return resolve_sync_root()


@server.tool(
    name="send_to_ipad",
    description=(
        "Send a markdown document to the user's iPad for reading and Apple "
        "Pencil review. Writes inbox/YYYY-MM-DD-<slug>/ into the sync "
        "folder atomically; the iPad picks it up on its own schedule, so "
        "this succeeds even when the iPad is off or asleep.\n\n"
        "Use this when the user asks for something to read, review, look at "
        "later or 'on the iPad', or when you have produced a document over "
        "roughly 400 words — a plan, brief, report, research summary, "
        "postmortem or spec.\n\n"
        "Authoring guidance — follow it, a document written to be annotated "
        "is a different document:\n" + AUTHORING_GUIDANCE
    ),
)
def send_to_ipad(
    content: str,
    title: str | None = None,
    tags: list[str] | None = None,
    origin_kind: str | None = None,
    session_id: str | None = None,
    thread_title: str | None = None,
) -> dict[str, Any]:
    """Write one inbox bundle.

    Args:
        content: The document, as markdown. Required.
        title: Human title. Defaults to the first H1 in ``content``.
        tags: Optional short labels, e.g. ``["spec", "auth"]``.
        origin_kind: ``claude-code`` or ``codex``. Auto-detected if omitted.
        session_id: This session's id, so the review can return to this
            conversation. Pass it if you know it; otherwise the server
            falls back to the environment and the session file.
        thread_title: Optional conversation title, shown in the review.
    """
    try:
        result = write_inbox_bundle(
            _sync_root(),
            content=content,
            title=title,
            tags=tags,
            origin_kind=origin_kind,
            session_id=session_id,
            thread_title=thread_title,
        )
    except ValidationError as exc:
        return {"ok": False, "error": f"invalid input: {exc}"}
    except OSError as exc:
        return {"ok": False, "error": f"could not write to the sync folder: {exc}"}

    return_type = result["origin"].get("returnPath", {}).get("type", "none")
    result.update(
        {
            "ok": True,
            "returnPath": return_type,
            "message": (
                f"On the iPad: {result['title']}. "
                + (
                    "The review will come back to this session."
                    if return_type != "none"
                    else "No session id was available, so the review will "
                    "come back by hand — the iPad offers a share sheet."
                )
            ),
        }
    )
    return result


@server.tool(
    name="list_reviews",
    description=(
        "List the Pencil reviews waiting in the sync folder's outbox — "
        "document title, when it was reviewed, how many comments it "
        "carries, and whether a reply has already been written back to it. "
        "Returns an empty list when the iPad has sent nothing; that is "
        "normal, not an error."
    ),
)
def list_reviews() -> dict[str, Any]:
    """Enumerate ``outbox/*.review/`` bundles, newest first."""
    try:
        reviews = list_review_bundles(_sync_root())
    except OSError as exc:
        return {"ok": False, "error": f"could not read the outbox: {exc}"}
    return {"ok": True, "count": len(reviews), "reviews": reviews}


@server.tool(
    name="get_review",
    description=(
        "Read one review bundle in full: review.md (the prose payload "
        "written for you to act on), plus the structured review.json, the "
        "list of ink image files, and any reply.md. Read-only — it never "
        "modifies or removes the bundle.\n\n"
        "Each comment quotes exact text from the document. Locate passages "
        "by matching the quote, never by line number: the document may have "
        "changed since it was sent. Ink images carry position as meaning — "
        "an arrow points at the text beneath it, a strikethrough means "
        "delete — so read them alongside the comments, not instead of them."
    ),
)
def get_review(id: str) -> dict[str, Any]:
    """Fetch one review by bundle id, e.g. ``2026-08-18-auth-refactor-plan``."""
    try:
        review = read_review(_sync_root(), id)
    except ValidationError as exc:
        return {"ok": False, "error": f"invalid id: {exc}"}
    except FileNotFoundError as exc:
        return {"ok": False, "error": str(exc), "hint": "call list_reviews first"}
    except OSError as exc:
        return {"ok": False, "error": f"could not read the bundle: {exc}"}
    review["ok"] = True
    return review


def main() -> None:
    """stdio entry point — what ``claude mcp add`` launches."""
    if os.environ.get("PENCIL_MCP_SELFTEST"):
        print(f"pencil-in-the-loop-mcp {__version__} ok; sync root {_sync_root()}")
        return
    server.run(transport="stdio")


if __name__ == "__main__":  # pragma: no cover
    main()
