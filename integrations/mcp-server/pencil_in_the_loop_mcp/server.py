"""The MCP surface: three tools over one folder.

Thin by design. Every decision that matters lives in ``core.py``; this
module only turns tool calls into those functions and shapes the replies.
"""

from __future__ import annotations

import base64
import os
from pathlib import Path
from typing import Any

from . import __version__
from .config import resolve_sync_root
from .core import (
    ValidationError,
    list_review_bundles,
    read_review,
    validate_bundle_id,
    write_file,
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


@server.tool(
    name="get_ink_image",
    description=(
        "Fetch one page of Apple Pencil ink from a review as an image, so you "
        "can see what was drawn. Position carries meaning — an arrow points at "
        "the text beneath it, a circle selects a passage, a strikethrough "
        "means delete — so an ink page is evidence, not decoration. Use this "
        "when get_review lists more ink pages than it inlined, or to look "
        "again at one page."
    ),
)
def get_ink_image(id: str, page: int) -> Any:
    """One ink page, as an image block.

    - Parameter page: the one-based number in the file name, so `ink/page-03.png`
      is page 3. That matches what `get_review` lists.
    """
    try:
        bundle = _bundle_directory(id)
    except ValidationError as exc:
        return {"ok": False, "error": f"invalid id: {exc}"}
    except FileNotFoundError as exc:
        return {"ok": False, "error": str(exc), "hint": "call list_reviews first"}

    path = bundle / "ink" / f"page-{int(page):02d}.png"
    if not path.is_file():
        return {
            "ok": False,
            "error": f"no ink on page {page} of {id}",
            "hint": "call get_review to see which pages have ink",
        }
    return _image_block(path)


@server.tool(
    name="reply_to_review",
    description=(
        "Reply to a review, in the reader. Writes reply.md into the review "
        "bundle; the iPad notices it and offers to open it as a document "
        "beside the original, so the user can read your answer where they "
        "wrote the question. Use it to say what you changed, or to ask about "
        "a comment you could not act on."
    ),
)
def reply_to_review(id: str, markdown: str) -> dict[str, Any]:
    """Write `reply.md` into a review bundle.

    The only tool here that writes to the outbox. `docs/05-file-contracts.md`
    has specified the reply channel from the start and the app has watched for
    it from the start; nothing had ever written one.
    """
    if not isinstance(markdown, str) or not markdown.strip():
        return {"ok": False, "error": "invalid input: the reply is empty"}
    try:
        bundle = _bundle_directory(id)
    except ValidationError as exc:
        return {"ok": False, "error": f"invalid id: {exc}"}
    except FileNotFoundError as exc:
        return {"ok": False, "error": str(exc), "hint": "call list_reviews first"}

    try:
        write_file(bundle / "reply.md", markdown if markdown.endswith("\n") else markdown + "\n")
    except OSError as exc:
        return {"ok": False, "error": f"could not write the reply: {exc}"}
    return {
        "ok": True,
        "id": bundle.name.removesuffix(".review"),
        "message": "On the iPad: the review sheet now offers to open your reply as a document.",
    }


def _bundle_directory(raw_id: Any) -> Path:
    """The review directory for an id, defended against traversal.

    - Raises: `ValidationError` for an id that is not a bundle name,
      `FileNotFoundError` when there is no such bundle.
    """
    name = validate_bundle_id(raw_id)
    outbox = (Path(_sync_root()) / "outbox").resolve()
    bundle = (outbox / f"{name}.review").resolve()
    if outbox not in bundle.parents:
        raise ValidationError("id must name a bundle inside the outbox")
    if not bundle.is_dir():
        raise FileNotFoundError(f"no review bundle with id {name}")
    return bundle


def _image_block(path: Path) -> Any:
    """A PNG as an MCP image block, or a plain dict when the SDK has no type."""
    data = base64.b64encode(path.read_bytes()).decode("ascii")
    try:
        from mcp.types import ImageContent

        return ImageContent(type="image", data=data, mimeType="image/png")
    except ImportError:  # pragma: no cover - depends on the SDK version
        return {"type": "image", "data": data, "mimeType": "image/png"}


def streamable_http_app(sync_root: Path | None = None) -> Any:
    """The MCP server as an ASGI app, for mounting inside the relay.

    The tools are unchanged and still read `PENCIL_SYNC_ROOT` through
    `resolve_sync_root()`, so hosting changes where the folder is and nothing
    else. There is deliberately no HTTP client inside this server: the relay's
    API and these tools are two faces on one storage layer, which is less code
    than a second implementation of every verb and cannot drift from it.

    Stateless, so that a redeploy does not strand a session mid-conversation.
    """
    if sync_root is not None:
        os.environ.setdefault("PENCIL_SYNC_ROOT", str(sync_root))

    kwargs: dict[str, Any] = {"streamable_http_path": "/", "stateless_http": True}
    try:
        from mcp.server.transport_security import TransportSecuritySettings

        kwargs["transport_security"] = _transport_security(TransportSecuritySettings)
    except ImportError:  # pragma: no cover - depends on the SDK version
        pass
    return server.streamable_http_app(**kwargs)


def _transport_security(settings_type: Any) -> Any:
    """DNS-rebinding protection, configured for wherever this is deployed.

    The SDK validates the Host header by default, which is right for a server
    on a laptop and wrong for one behind a platform router that sets Host to
    whatever domain it assigned. So: allow-list the real hostname when the
    platform tells us it — `PENCIL_ALLOWED_HOSTS`, or Railway's own variable —
    and otherwise turn the check off with the reason stated rather than leave
    every request failing with "Invalid Host header".

    Turning it off is defensible here specifically. DNS rebinding is an attack
    on a server that trusts the network position of its caller; this one trusts
    nothing but a bearer token, which is not a cookie and carries no ambient
    authority, so a browser tricked into calling the relay still cannot
    authenticate.
    """
    hosts = [
        host.strip()
        for host in os.environ.get("PENCIL_ALLOWED_HOSTS", "").split(",")
        if host.strip()
    ]
    platform_domain = os.environ.get("RAILWAY_PUBLIC_DOMAIN", "").strip()
    if platform_domain:
        hosts.append(platform_domain)

    if not hosts:
        return settings_type(enable_dns_rebinding_protection=False)

    hosts += ["localhost", "127.0.0.1"]
    return settings_type(
        enable_dns_rebinding_protection=True,
        allowed_hosts=hosts,
        allowed_origins=[f"https://{host}" for host in hosts],
    )


def main() -> None:
    """stdio entry point — what ``claude mcp add`` launches."""
    if os.environ.get("PENCIL_MCP_SELFTEST"):
        print(f"pencil-in-the-loop-mcp {__version__} ok; sync root {_sync_root()}")
        return
    server.run(transport="stdio")


if __name__ == "__main__":  # pragma: no cover
    main()
