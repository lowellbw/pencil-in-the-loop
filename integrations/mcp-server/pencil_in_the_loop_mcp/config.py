"""Locating the sync folder, and working out who is calling.

Nothing here touches the network and nothing here writes state other than
the single config file the user may create by hand.
"""

from __future__ import annotations

import json
import os
import re
from pathlib import Path
from typing import Any

# ---------------------------------------------------------------- sync root

ENV_SYNC_ROOT = "PENCIL_SYNC_ROOT"

#: Kinds permitted by ``origin.kind`` in docs/05-file-contracts.md.
ORIGIN_KINDS = ("cowork", "claude-code", "codex", "share", "manual")

#: Types permitted by ``origin.returnPath.type`` in docs/05.
RETURN_PATH_TYPES = ("poke", "checkin", "resume", "cloud", "none")


def config_dir() -> Path:
    """Directory holding ``config.json`` and the optional session file."""
    override = os.environ.get("PENCIL_CONFIG_DIR")
    if override:
        return Path(override).expanduser()
    xdg = os.environ.get("XDG_CONFIG_HOME")
    base = Path(xdg).expanduser() if xdg else Path.home() / ".config"
    return base / "pencil-in-the-loop"


def config_path() -> Path:
    return config_dir() / "config.json"


def _read_json(path: Path) -> dict[str, Any]:
    """Read a JSON object, returning ``{}`` for anything unreadable.

    Config problems must degrade, never crash the server at startup.
    """
    try:
        with path.open("r", encoding="utf-8") as handle:
            data = json.load(handle)
    except (OSError, ValueError):
        return {}
    return data if isinstance(data, dict) else {}


def default_sync_root() -> Path:
    """Best guess when nothing is configured.

    iCloud Drive is the assumption in docs/08 question 2, so prefer a
    ``Pencil-in-the-loop`` folder there when iCloud Drive exists at all.
    """
    icloud = (
        Path.home()
        / "Library"
        / "Mobile Documents"
        / "com~apple~CloudDocs"
    )
    if icloud.is_dir():
        return icloud / "Pencil-in-the-loop"
    return Path.home() / "Pencil-in-the-loop"


def resolve_sync_root(explicit: str | os.PathLike[str] | None = None) -> Path:
    """Resolve the sync folder.

    Order of precedence:

    1. an explicit path passed by the caller
    2. the ``PENCIL_SYNC_ROOT`` environment variable
    3. ``syncRoot`` in ``~/.config/pencil-in-the-loop/config.json``
    4. iCloud Drive's ``Pencil-in-the-loop``, else ``~/Pencil-in-the-loop``

    The folder is not created here. Nothing is created until a write.
    """
    if explicit:
        return Path(explicit).expanduser()
    env = os.environ.get(ENV_SYNC_ROOT)
    if env:
        return Path(env).expanduser()
    configured = _read_json(config_path()).get("syncRoot")
    if isinstance(configured, str) and configured.strip():
        return Path(configured).expanduser()
    return default_sync_root()


# ------------------------------------------------------------- who is calling

_SESSION_ID_RE = re.compile(r"^[A-Za-z0-9._:-]{6,128}$")

# Environment variables that may carry a session id. An MCP server is a
# child process of Claude Code and inherits its environment, and
# CLAUDE_CODE_SESSION_ID was observed carrying the session UUID on Claude
# Code 2.1.42. It is still probed defensively — the source we actually used
# is recorded in meta.json so the watcher can weigh it.
_CLAUDE_ENV_KEYS = ("CLAUDE_CODE_SESSION_ID", "CLAUDE_SESSION_ID")
_CODEX_ENV_KEYS = ("CODEX_SESSION_ID", "CODEX_THREAD_ID")

# The web/cloud session, when Claude Code is running remotely. This is a
# different identifier from the local session UUID, and it is the one
# `claude --cloud <session-id>` plausibly wants.
_CLOUD_ENV_KEY = "CLAUDE_CODE_REMOTE_SESSION_ID"


def session_file_path() -> Path:
    """Where a ``SessionStart`` hook is asked to drop the session id.

    See the README: the hook receives the hook payload on stdin and copies
    its ``session_id`` field here. This is the only mechanism we have
    verified can carry the id to a separate MCP server process.
    """
    return config_dir() / "session.json"


def _valid_session_id(value: Any) -> str | None:
    if isinstance(value, str) and _SESSION_ID_RE.match(value.strip()):
        return value.strip()
    return None


def _cloud_session_id() -> str | None:
    return _valid_session_id(os.environ.get(_CLOUD_ENV_KEY))


def detect_session(explicit: str | None = None) -> dict[str, Any]:
    """Work out the calling session id, and say where it came from.

    Returns a dict with ``sessionId`` (may be ``None``), ``source`` and,
    when known, ``cwd`` and ``transcriptPath``. ``source`` is written into
    ``meta.json`` so the Mac-side watcher can weigh how much to trust it.
    """
    cloud = _cloud_session_id()

    explicit_id = _valid_session_id(explicit)
    if explicit_id:
        return {
            "sessionId": explicit_id,
            "source": "tool-argument",
            "cloudSessionId": cloud,
            "cwd": os.environ.get("CLAUDE_PROJECT_DIR") or None,
        }

    for key in _CLAUDE_ENV_KEYS + _CODEX_ENV_KEYS:
        found = _valid_session_id(os.environ.get(key))
        if found:
            return {
                "sessionId": found,
                "source": f"env:{key}",
                "cloudSessionId": cloud,
                "cwd": os.environ.get("CLAUDE_PROJECT_DIR") or None,
            }

    payload = _read_json(session_file_path())
    found = _valid_session_id(payload.get("session_id") or payload.get("sessionId"))
    if found:
        result: dict[str, Any] = {
            "sessionId": found,
            "source": "session-file",
            "cloudSessionId": cloud,
        }
        cwd = payload.get("cwd")
        if isinstance(cwd, str) and cwd:
            result["cwd"] = cwd
        transcript = payload.get("transcript_path") or payload.get("transcriptPath")
        if isinstance(transcript, str) and transcript:
            result["transcriptPath"] = transcript
        return result

    return {
        "sessionId": None,
        "source": "unavailable",
        "cloudSessionId": cloud,
        "cwd": None,
    }


def detect_origin_kind(explicit: str | None = None) -> str:
    """Pick ``origin.kind``. Explicit wins; otherwise sniff the environment.

    docs/06 says the Codex variant needs nothing beyond a different origin
    kind, so this is the whole of the Codex support.
    """
    if explicit:
        candidate = explicit.strip().lower()
        if candidate not in ORIGIN_KINDS:
            raise ValueError(
                f"origin_kind must be one of {', '.join(ORIGIN_KINDS)}"
            )
        return candidate
    forced = os.environ.get("PENCIL_ORIGIN_KIND", "").strip().lower()
    if forced in ORIGIN_KINDS:
        return forced
    if any(os.environ.get(key) for key in _CODEX_ENV_KEYS) or os.environ.get(
        "CODEX_HOME"
    ):
        return "codex"
    return "claude-code"
