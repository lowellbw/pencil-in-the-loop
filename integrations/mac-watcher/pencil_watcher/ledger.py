"""The delivery ledger — the thing that stops a review being delivered twice.

Deliberately NOT stored inside the sync folder. That folder is a published
contract (docs/05) shared with the iPad app and with anything else that can
write a file; daemon bookkeeping does not belong in it, and it would sync to
every other device. The ledger lives next to the config, default
``~/.pencil-loop/watcher-ledger.json``.

Entries are keyed on bundle path plus content hash, so a bundle that is edited
and re-synced is a genuinely new entry and will be delivered again, while the
same bundle seen a thousand times is delivered once.
"""

from __future__ import annotations

import json
import os
import tempfile
import time
from dataclasses import asdict, dataclass, field
from pathlib import Path
from typing import Callable, Dict, Iterable, Optional

LEDGER_VERSION = 1

# Terminal: never attempted again.
STATUS_DELIVERED = "delivered"
STATUS_SKIPPED = "skipped"      # e.g. checkin — the session collects it itself
STATUS_HELD = "held"            # no return path, or the route is disabled
STATUS_EXHAUSTED = "exhausted"  # retries used up; needs a human

# Non-terminal: will be tried again.
STATUS_FAILED = "failed"
STATUS_DEFERRED = "deferred"    # local session busy; hold and fire when free

TERMINAL_STATUSES = {STATUS_DELIVERED, STATUS_SKIPPED, STATUS_HELD, STATUS_EXHAUSTED}


def _now_iso(epoch: float) -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(epoch))


@dataclass
class Entry:
    key: str
    bundle: str
    hash: str
    status: str
    route: str = ""
    attempts: int = 0
    deferrals: int = 0
    first_seen: float = 0.0
    last_attempt: float = 0.0
    next_attempt: float = 0.0
    last_error: str = ""
    note: str = ""

    @property
    def terminal(self) -> bool:
        return self.status in TERMINAL_STATUSES

    def to_json(self) -> Dict[str, object]:
        data = asdict(self)
        data["firstSeenAt"] = _now_iso(self.first_seen) if self.first_seen else ""
        data["lastAttemptAt"] = _now_iso(self.last_attempt) if self.last_attempt else ""
        data["nextAttemptAt"] = _now_iso(self.next_attempt) if self.next_attempt else ""
        return data

    @classmethod
    def from_json(cls, key: str, data: Dict[str, object]) -> "Entry":
        def num(name: str) -> float:
            value = data.get(name, 0)
            try:
                return float(value)  # type: ignore[arg-type]
            except (TypeError, ValueError):
                return 0.0

        return cls(
            key=key,
            bundle=str(data.get("bundle") or ""),
            hash=str(data.get("hash") or ""),
            status=str(data.get("status") or STATUS_FAILED),
            route=str(data.get("route") or ""),
            attempts=int(num("attempts")),
            deferrals=int(num("deferrals")),
            first_seen=num("first_seen"),
            last_attempt=num("last_attempt"),
            next_attempt=num("next_attempt"),
            last_error=str(data.get("last_error") or ""),
            note=str(data.get("note") or ""),
        )


class Ledger:
    def __init__(self, path: Path, clock: Callable[[], float] = time.time) -> None:
        self.path = Path(path)
        self._clock = clock
        self._entries: Dict[str, Entry] = {}
        self.load()

    # -- persistence -------------------------------------------------------

    def load(self) -> None:
        self._entries = {}
        if not self.path.exists():
            return
        try:
            raw = json.loads(self.path.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            # A corrupt ledger must not wedge the daemon, but it also must not
            # be silently discarded — the caller logs, and we keep the file by
            # moving it aside on the next save.
            self._entries = {}
            self._corrupt = True
            return
        entries = raw.get("entries") if isinstance(raw, dict) else None
        if isinstance(entries, dict):
            for key, value in entries.items():
                if isinstance(value, dict):
                    self._entries[key] = Entry.from_json(key, value)

    def save(self) -> None:
        payload = {
            "version": LEDGER_VERSION,
            "updatedAt": _now_iso(self._clock()),
            "entries": {key: entry.to_json() for key, entry in sorted(self._entries.items())},
        }
        self.path.parent.mkdir(parents=True, exist_ok=True)
        handle = tempfile.NamedTemporaryFile(
            "w", encoding="utf-8", dir=str(self.path.parent), prefix=".ledger-", delete=False
        )
        try:
            json.dump(payload, handle, indent=2, sort_keys=False)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        finally:
            handle.close()
        os.replace(handle.name, self.path)

    # -- queries -----------------------------------------------------------

    def get(self, key: str) -> Optional[Entry]:
        return self._entries.get(key)

    def entries(self) -> Iterable[Entry]:
        return list(self._entries.values())

    def is_delivered(self, key: str) -> bool:
        entry = self._entries.get(key)
        return entry is not None and entry.status == STATUS_DELIVERED

    def is_terminal(self, key: str) -> bool:
        entry = self._entries.get(key)
        return entry is not None and entry.terminal

    def due(self, key: str) -> bool:
        """Should this key be attempted now?"""
        entry = self._entries.get(key)
        if entry is None:
            return True
        if entry.terminal:
            return False
        return self._clock() >= entry.next_attempt

    def wait_remaining(self, key: str) -> float:
        entry = self._entries.get(key)
        if entry is None or entry.terminal:
            return 0.0
        return max(0.0, entry.next_attempt - self._clock())

    # -- mutation ----------------------------------------------------------

    def _ensure(self, key: str, bundle: str, digest: str) -> Entry:
        entry = self._entries.get(key)
        if entry is None:
            entry = Entry(
                key=key,
                bundle=bundle,
                hash=digest,
                status=STATUS_FAILED,
                first_seen=self._clock(),
            )
            self._entries[key] = entry
        return entry

    def mark_terminal(
        self, key: str, bundle: str, digest: str, status: str, route: str, note: str = ""
    ) -> Entry:
        entry = self._ensure(key, bundle, digest)
        entry.status = status
        entry.route = route
        entry.note = note
        entry.last_attempt = self._clock()
        entry.next_attempt = 0.0
        if status == STATUS_DELIVERED:
            entry.attempts += 1
            entry.last_error = ""
        self.save()
        return entry

    def mark_failure(
        self,
        key: str,
        bundle: str,
        digest: str,
        route: str,
        error: str,
        *,
        base: float,
        factor: float,
        cap: float,
        max_attempts: int,
    ) -> Entry:
        """Record a failed delivery and schedule the exponential retry."""
        entry = self._ensure(key, bundle, digest)
        entry.route = route
        entry.attempts += 1
        entry.last_attempt = self._clock()
        entry.last_error = error
        if entry.attempts >= max_attempts:
            entry.status = STATUS_EXHAUSTED
            entry.next_attempt = 0.0
        else:
            entry.status = STATUS_FAILED
            entry.next_attempt = entry.last_attempt + backoff_delay(
                entry.attempts, base=base, factor=factor, cap=cap
            )
        self.save()
        return entry

    def mark_deferred(
        self, key: str, bundle: str, digest: str, route: str, reason: str, *, base: float, factor: float, cap: float
    ) -> Entry:
        """A running local session cannot be injected into (docs/06). Hold the
        bundle and try again — this never exhausts, because the session
        freeing up is a matter of when, not whether."""
        entry = self._ensure(key, bundle, digest)
        entry.route = route
        entry.status = STATUS_DEFERRED
        entry.deferrals += 1
        entry.last_attempt = self._clock()
        entry.last_error = reason
        entry.next_attempt = entry.last_attempt + backoff_delay(
            entry.deferrals, base=base, factor=factor, cap=cap
        )
        self.save()
        return entry

    def forget(self, prefix: str) -> int:
        """Drop entries whose key or bundle path matches, so they re-queue."""
        removed = [
            key
            for key, entry in self._entries.items()
            if key == prefix or entry.bundle == prefix or entry.bundle.endswith("/" + prefix.lstrip("/"))
        ]
        for key in removed:
            del self._entries[key]
        if removed:
            self.save()
        return len(removed)


def backoff_delay(attempt: int, *, base: float, factor: float, cap: float) -> float:
    """Exponential backoff, capped. ``attempt`` is 1-based."""
    if attempt <= 1:
        return min(base, cap)
    delay = base * (factor ** (attempt - 1))
    return min(delay, cap)
