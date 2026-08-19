"""Configuration loading.

The config file lives at ``~/.pencil-loop/config.json``.

ASSUMPTION: that path and the ``syncRoot`` key are the convention being
established by the Cowork skill unit (``integrations/cowork-skill/``). This unit
assumes it rather than defines it. If that unit lands on a different key name,
change ``_SYNC_ROOT_KEYS`` below and nothing else needs to move.

Everything the watcher itself needs lives under a ``watcher`` object in the same
file, so the two units never fight over the same keys.
"""

from __future__ import annotations

import json
import os
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Dict, List, Optional

DEFAULT_CONFIG_PATH = Path("~/.pencil-loop/config.json")

# Keys we accept for the sync folder, in priority order. Kept in step with
# SYNC_ROOT_KEYS in integrations/cowork-skill/scripts/send_to_reader.py, which
# is the unit that writes this file.
_SYNC_ROOT_KEYS = ("syncRoot", "readerFolder", "syncFolder", "folder")

# The cowork-skill unit also honours this environment variable, so we do too.
_SYNC_ROOT_ENV = "PENCIL_LOOP_READER_FOLDER"

# Command templates. Every one of these is UNVERIFIED — see README. They are
# config so that a user who discovers the real invocation can fix it without
# touching code.
DEFAULT_ROUTE_COMMANDS: Dict[str, List[str]] = {
    # docs/06 says firing the poke-only scheduled task needs account-level
    # access. It does not say what the CLI for that is, and we have not been
    # able to check. This shape is a placeholder, not a claim.
    "poke": ["claude", "trigger", "fire", "{triggerId}", "--text", "{text}"],
    # docs/06: "claude --cloud <session-id> -p \"<review>\""
    "cloud": ["claude", "--cloud", "{sessionId}", "-p", "{text}"],
    # docs/06: "claude -p \"<review>\" --resume <session-id>"
    "resume": ["claude", "-p", "{text}", "--resume", "{sessionId}"],
    # docs/06: "codex resume has equivalent semantics". Flags not specified.
    "codex": ["codex", "resume", "{sessionId}", "{text}"],
}

# Exit code 0 from this command is read as "a local Claude Code session is
# currently running, so it cannot be injected into". Heuristic, see README.
DEFAULT_BUSY_COMMAND: List[str] = ["pgrep", "-x", "claude"]


class ConfigError(Exception):
    """Raised when the config file is missing, malformed, or unusable."""


@dataclass
class RouteConfig:
    enabled: bool = True
    command: List[str] = field(default_factory=list)


@dataclass
class Config:
    sync_root: Path
    state_dir: Path
    ledger_path: Path
    log_path: Path
    poll_interval: float = 15.0
    settle_seconds: float = 5.0
    retry_base_seconds: float = 30.0
    retry_factor: float = 2.0
    retry_max_seconds: float = 1800.0
    max_attempts: int = 6
    defer_base_seconds: float = 30.0
    defer_max_seconds: float = 300.0
    command_timeout: float = 120.0
    max_inline_chars: int = 40000
    busy_command: Optional[List[str]] = field(default_factory=lambda: list(DEFAULT_BUSY_COMMAND))
    routes: Dict[str, RouteConfig] = field(default_factory=dict)
    source_path: Optional[Path] = None

    @property
    def outbox(self) -> Path:
        return self.sync_root / "outbox"

    @property
    def inbox(self) -> Path:
        return self.sync_root / "inbox"

    def route(self, name: str) -> RouteConfig:
        if name not in self.routes:
            self.routes[name] = RouteConfig(
                enabled=True,
                command=list(DEFAULT_ROUTE_COMMANDS.get(name, [])),
            )
        return self.routes[name]


def _expand(value: str) -> Path:
    return Path(os.path.expanduser(os.path.expandvars(value)))


def _find_sync_root(raw: Dict[str, Any]) -> Optional[str]:
    for key in _SYNC_ROOT_KEYS:
        value = raw.get(key)
        if isinstance(value, str) and value.strip():
            return value
    return None


def load_config(path: Optional[Path] = None, overrides: Optional[Dict[str, Any]] = None) -> Config:
    """Read the config file and build a :class:`Config`.

    ``overrides`` is a flat dict of already-parsed CLI values that win over the
    file (currently ``poll_interval``, ``settle_seconds``, ``sync_root``).
    """
    overrides = overrides or {}
    config_path = Path(path) if path else _expand(str(DEFAULT_CONFIG_PATH))

    raw: Dict[str, Any] = {}
    if config_path.exists():
        try:
            raw = json.loads(config_path.read_text(encoding="utf-8"))
        except (OSError, ValueError) as exc:
            raise ConfigError("could not read %s: %s" % (config_path, exc)) from exc
        if not isinstance(raw, dict):
            raise ConfigError("%s must contain a JSON object" % config_path)

    watcher_raw = raw.get("watcher") if isinstance(raw.get("watcher"), dict) else {}

    sync_root_value = (
        overrides.get("sync_root")
        or os.environ.get(_SYNC_ROOT_ENV)
        or _find_sync_root(watcher_raw)
        or _find_sync_root(raw)
    )
    if not sync_root_value:
        raise ConfigError(
            "no sync folder configured. Set \"syncRoot\" in %s, set %s, or pass "
            "--sync-root." % (config_path, _SYNC_ROOT_ENV)
        )
    sync_root = _expand(str(sync_root_value))

    state_dir = _expand(str(watcher_raw.get("stateDir") or config_path.parent))
    ledger_path = _expand(str(watcher_raw.get("ledgerPath") or state_dir / "watcher-ledger.json"))
    log_path = _expand(str(watcher_raw.get("logPath") or state_dir / "logs" / "watcher.log"))

    routes: Dict[str, RouteConfig] = {}
    routes_raw = watcher_raw.get("routes") if isinstance(watcher_raw.get("routes"), dict) else {}
    for name in ("poke", "checkin", "cloud", "resume", "codex", "none"):
        entry = routes_raw.get(name) if isinstance(routes_raw.get(name), dict) else {}
        command = entry.get("command")
        if not isinstance(command, list) or not all(isinstance(c, str) for c in command):
            command = list(DEFAULT_ROUTE_COMMANDS.get(name, []))
        routes[name] = RouteConfig(enabled=bool(entry.get("enabled", True)), command=command)

    busy_command: Optional[List[str]] = list(DEFAULT_BUSY_COMMAND)
    if "busyCommand" in watcher_raw:
        value = watcher_raw.get("busyCommand")
        if value is None:
            busy_command = None
        elif isinstance(value, list) and all(isinstance(c, str) for c in value):
            busy_command = list(value)

    def num(key: str, default: float) -> float:
        value = watcher_raw.get(key, default)
        try:
            return float(value)
        except (TypeError, ValueError):
            return default

    cfg = Config(
        sync_root=sync_root,
        state_dir=state_dir,
        ledger_path=ledger_path,
        log_path=log_path,
        poll_interval=float(overrides.get("poll_interval") or num("pollIntervalSeconds", 15.0)),
        settle_seconds=float(overrides.get("settle_seconds") or num("settleSeconds", 5.0)),
        retry_base_seconds=num("retryBaseSeconds", 30.0),
        retry_factor=num("retryFactor", 2.0),
        retry_max_seconds=num("retryMaxSeconds", 1800.0),
        max_attempts=int(num("maxAttempts", 6)),
        defer_base_seconds=num("deferBaseSeconds", 30.0),
        defer_max_seconds=num("deferMaxSeconds", 300.0),
        command_timeout=num("commandTimeoutSeconds", 120.0),
        max_inline_chars=int(num("maxInlineChars", 40000)),
        busy_command=busy_command,
        routes=routes,
        source_path=config_path if config_path.exists() else None,
    )
    return cfg
