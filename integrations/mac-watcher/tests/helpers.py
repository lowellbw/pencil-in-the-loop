"""Shared test scaffolding. No test ever shells out."""

from __future__ import annotations

import json
import logging
import shutil
import tempfile
import unittest
from pathlib import Path
from typing import Any, Dict, List, Optional

from pencil_watcher.config import DEFAULT_ROUTE_COMMANDS, Config, RouteConfig
from pencil_watcher.logsetup import LOGGER_NAME


def silence_logging() -> None:
    logger = logging.getLogger(LOGGER_NAME)
    logger.handlers = [logging.NullHandler()]
    logger.propagate = False
    logger.setLevel(logging.CRITICAL)


class FakeClock:
    def __init__(self, start: float = 1_000_000.0) -> None:
        self.now = start

    def __call__(self) -> float:
        return self.now

    def advance(self, seconds: float) -> None:
        self.now += seconds


def make_config(root: Path, **kwargs: Any) -> Config:
    state = root / "state"
    state.mkdir(parents=True, exist_ok=True)
    routes = {
        name: RouteConfig(enabled=True, command=list(DEFAULT_ROUTE_COMMANDS.get(name, [])))
        for name in ("poke", "checkin", "cloud", "resume", "codex", "none")
    }
    config = Config(
        sync_root=root / "sync",
        state_dir=state,
        ledger_path=state / "watcher-ledger.json",
        log_path=None,  # type: ignore[arg-type]
        poll_interval=1.0,
        settle_seconds=5.0,
        retry_base_seconds=30.0,
        retry_factor=2.0,
        retry_max_seconds=1800.0,
        max_attempts=3,
        defer_base_seconds=10.0,
        defer_max_seconds=60.0,
        command_timeout=5.0,
        max_inline_chars=40000,
        busy_command=None,
        routes=routes,
    )
    for key, value in kwargs.items():
        setattr(config, key, value)
    (config.sync_root / "inbox").mkdir(parents=True, exist_ok=True)
    (config.sync_root / "outbox").mkdir(parents=True, exist_ok=True)
    return config


REVIEW_MD = """# Review — Auth refactor plan

Reviewed 18 Aug 2026, 21:14 · 1 comment · 1 inked page

## Comments

### 1 — page 1

> The migration runs in a single deploy.

Needs a shadow read.
"""


def write_bundle(
    config: Config,
    slug: str = "2026-08-18-auth-refactor-plan",
    *,
    manifest: Optional[Dict[str, Any]] = None,
    review_md: str = REVIEW_MD,
    ink: Optional[List[str]] = None,
) -> Path:
    """Write a complete, well-formed bundle into outbox."""
    path = config.sync_root / "outbox" / ("%s.review" % slug)
    path.mkdir(parents=True, exist_ok=True)
    (path / "review.md").write_text(review_md, encoding="utf-8")
    (path / "review.json").write_text(
        json.dumps({"documentId": "F7A1", "comments": []}), encoding="utf-8"
    )
    files = ["review.md", "review.json", "manifest.json"]
    for name in ink or []:
        target = path / name
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(b"\x89PNG\r\n\x1a\n" + b"0" * 64)
        files.append(name)
    payload = manifest if manifest is not None else {"version": 1, "files": files}
    (path / "manifest.json").write_text(json.dumps(payload), encoding="utf-8")
    return path


def write_meta(
    config: Config,
    slug: str = "2026-08-18-auth-refactor-plan",
    *,
    origin: Optional[Dict[str, Any]] = None,
    document_id: str = "F7A1",
) -> Path:
    doc = config.sync_root / "inbox" / slug
    doc.mkdir(parents=True, exist_ok=True)
    meta: Dict[str, Any] = {
        "id": document_id,
        "title": "Auth refactor plan",
        "createdAt": "2026-08-18T18:22:04Z",
        "sourceFormat": "markdown",
        "pageCount": 4,
    }
    if origin is not None:
        meta["origin"] = origin
    (doc / "meta.json").write_text(json.dumps(meta), encoding="utf-8")
    return doc


class TempDirTestCase(unittest.TestCase):
    def setUp(self) -> None:
        silence_logging()
        self.root = Path(tempfile.mkdtemp(prefix="pencil-watcher-test-"))
        self.addCleanup(shutil.rmtree, self.root, True)
