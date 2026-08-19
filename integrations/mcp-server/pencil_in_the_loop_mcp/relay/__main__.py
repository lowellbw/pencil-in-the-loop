"""Run the relay.

    pencil-loop-relay

Configuration is entirely environment variables, because that is what a
platform gives you and because a config file on an ephemeral container is a
file nobody can edit:

    PENCIL_SYNC_ROOT     where inbox/ and outbox/ live. On Railway this is the
                         mounted volume — /data. Default: /data.
    PENCIL_DEVICE_TOKEN  the bearer token the iPad sends. Required.
    PENCIL_MCP_TOKEN     the bearer token, or capability-URL segment, the MCP
                         clients use. Optional; the MCP endpoint is only
                         mounted when it is set.
    PORT                 given by the platform. Default: 8080.

**One worker, deliberately.** A volume attaches to a single instance, so there
is nothing to scale out to, and single-writer is what makes SQLite plus the
rename-based commits in `core.py` safe together. Do not "fix" this by raising
the worker count.
"""

from __future__ import annotations

import os
import secrets
import sys
from pathlib import Path

from .app import create_app
from .db import Index


def build_app():
    """The ASGI app, assembled from the environment.

    Importable as `pencil_in_the_loop_mcp.relay.__main__:build_app` so a process
    manager can serve it directly.
    """
    sync_root = Path(os.environ.get("PENCIL_SYNC_ROOT", "/data")).expanduser()
    sync_root.mkdir(parents=True, exist_ok=True)

    device_token = os.environ.get("PENCIL_DEVICE_TOKEN", "").strip()
    if not device_token:
        raise SystemExit(
            "PENCIL_DEVICE_TOKEN is not set. Generate one with:\n"
            "    python3 -c 'import secrets; print(secrets.token_urlsafe(32))'\n"
            "and set it on the service and on the iPad."
        )

    index = Index(sync_root / "index.sqlite3")

    # An index that has never seen this volume rebuilds itself from whatever is
    # already in inbox/ and outbox/. That is the recovery path when the SQLite
    # file is lost, and the migration path when a folder-transport sync root is
    # copied onto the volume: untar, restart, and every document is served.
    if index.cursor == 0:
        indexed = index.reindex(sync_root)
        if indexed:
            print(f"indexed {indexed} document(s) already on the volume", flush=True)

    mcp_token = os.environ.get("PENCIL_MCP_TOKEN", "").strip() or None
    mcp_app = _mcp_app(sync_root) if mcp_token else None

    return create_app(
        sync_root=sync_root,
        index=index,
        device_token=device_token,
        mcp_app=mcp_app,
        mcp_token=mcp_token,
    )


def _mcp_app(sync_root: Path):
    """The MCP server as an ASGI app, or None when the SDK is not installed.

    Optional rather than required so the API can be deployed and exercised
    before the MCP half exists, and so a missing SDK is a missing feature
    rather than a service that will not boot.
    """
    try:
        from ..server import streamable_http_app
    except ImportError as error:  # pragma: no cover - depends on the install
        print(f"MCP endpoint not mounted: {error}", flush=True)
        return None
    return streamable_http_app(sync_root)


def main() -> None:
    try:
        import uvicorn
    except ImportError:  # pragma: no cover - depends on the install
        raise SystemExit(
            "uvicorn is not installed. Install the relay extra:\n"
            "    pip install 'pencil-in-the-loop-mcp[relay]'"
        )

    port = int(os.environ.get("PORT", "8080"))
    uvicorn.run(
        build_app(),
        host="0.0.0.0",
        port=port,
        workers=1,
        # The MCP capability URL carries a secret in its path, so paths must not
        # be written to the log. This is the one line that keeps that true.
        access_log=False,
    )


def print_token() -> None:
    """`pencil-loop-relay --new-token` — one fewer reason to reuse a password."""
    print(secrets.token_urlsafe(32))


if __name__ == "__main__":
    if "--new-token" in sys.argv:
        print_token()
    else:
        main()
