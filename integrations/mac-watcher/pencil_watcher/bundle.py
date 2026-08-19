"""Finding review bundles in ``outbox/``, deciding when they are whole, and
working out where the review should be delivered.

Two separate problems live here and it is worth naming them:

1. **Completeness.** docs/04 F5 says the iPad writes the bundle to a sibling
   ``.tmp`` directory and renames, so the directory appears atomically. A
   syncing file provider does not honour that: iCloud Drive materialises the
   directory entry first and dribbles the files in afterwards. So a bundle is
   only processed once ``manifest.json`` is present and parseable, everything
   it names exists, and a fingerprint of the whole directory has stopped
   changing for ``settle_seconds``.

2. **Return path.** The bundle itself does not carry the origin — that lives in
   the originating document's ``meta.json`` in ``inbox/``. Resolution is by
   folder name first, then by ``documentId``.
"""

from __future__ import annotations

import hashlib
import json
import os
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Callable, Dict, List, Optional, Tuple

REVIEW_SUFFIX = ".review"
MANIFEST_NAME = "manifest.json"
REVIEW_MD = "review.md"
REVIEW_JSON = "review.json"
REPLY_MD = "reply.md"
INK_DIR = "ink"

# Files we require even when the manifest does not list anything.
MINIMUM_FILES = (MANIFEST_NAME, REVIEW_MD)


@dataclass(frozen=True)
class ReturnPath:
    """``meta.json``'s ``origin`` block, flattened.

    ``type`` is one of poke · checkin · resume · cloud · none (docs/05).
    ``kind`` is one of cowork · claude-code · codex · share · manual.
    """

    type: str = "none"
    kind: str = ""
    session_id: str = ""
    trigger_id: str = ""
    thread_title: str = ""
    source: str = "none"  # where we found it, for the log line

    @property
    def described(self) -> str:
        bits = ["type=%s" % (self.type or "none")]
        if self.kind:
            bits.append("kind=%s" % self.kind)
        if self.trigger_id:
            bits.append("trigger=%s" % self.trigger_id)
        if self.session_id:
            bits.append("session=%s" % self.session_id)
        bits.append("from=%s" % self.source)
        return " ".join(bits)


@dataclass
class Bundle:
    path: Path
    sync_root: Path
    content_hash: str = ""
    files: List[str] = field(default_factory=list)

    @property
    def name(self) -> str:
        return self.path.name

    @property
    def slug(self) -> str:
        """``2026-08-18-auth-refactor-plan.review`` -> the inbox folder name."""
        name = self.path.name
        if name.endswith(REVIEW_SUFFIX):
            return name[: -len(REVIEW_SUFFIX)]
        return name

    @property
    def rel_path(self) -> str:
        try:
            return str(self.path.relative_to(self.sync_root))
        except ValueError:
            return str(self.path)

    @property
    def key(self) -> str:
        """Ledger key: bundle path plus content hash."""
        return "%s#%s" % (self.rel_path, self.content_hash)

    @property
    def review_md(self) -> Path:
        return self.path / REVIEW_MD

    @property
    def reply_md(self) -> Path:
        return self.path / REPLY_MD

    @property
    def ink_dir(self) -> Path:
        return self.path / INK_DIR

    def has_ink(self) -> bool:
        ink = self.ink_dir
        try:
            return ink.is_dir() and any(ink.iterdir())
        except OSError:
            return False

    def read_review_text(self) -> str:
        try:
            return self.review_md.read_text(encoding="utf-8", errors="replace")
        except OSError:
            return ""

    def title(self) -> str:
        """Best-effort human title, for the delivered header."""
        text = self.read_review_text()
        for line in text.splitlines():
            line = line.strip()
            if line.startswith("# "):
                heading = line[2:].strip()
                # "Review — Auth refactor plan" -> "Auth refactor plan"
                for dash in ("—", "–", "-"):
                    marker = " %s " % dash
                    if marker in heading:
                        return heading.split(marker, 1)[1].strip()
                return heading
        return self.slug


# --------------------------------------------------------------------------
# completeness
# --------------------------------------------------------------------------


def read_json(path: Path) -> Optional[Dict[str, Any]]:
    """Parse a JSON object, or return None. A partially written file parses as
    None, which is exactly the signal we want."""
    try:
        raw = path.read_text(encoding="utf-8")
    except OSError:
        return None
    if not raw.strip():
        return None
    try:
        value = json.loads(raw)
    except ValueError:
        return None
    return value if isinstance(value, dict) else None


def manifest_required_files(manifest: Dict[str, Any]) -> List[str]:
    """Relative paths the manifest says the bundle contains.

    ASSUMPTION: docs/05 lists ``manifest.json`` in the bundle but does not give
    its schema. We accept a ``files`` array of either strings or objects with a
    ``path``/``name`` key, and fall back to requiring review.md when there is
    no such array. Any future schema that keeps a file list works unchanged.
    """
    out: List[str] = []
    entries = manifest.get("files")
    if isinstance(entries, list):
        for entry in entries:
            if isinstance(entry, str):
                out.append(entry)
            elif isinstance(entry, dict):
                value = entry.get("path") or entry.get("name") or entry.get("file")
                if isinstance(value, str):
                    out.append(value)
    return out


def incompleteness_reason(bundle_path: Path) -> Optional[str]:
    """None when the bundle looks whole; otherwise why it does not."""
    manifest_path = bundle_path / MANIFEST_NAME
    if not manifest_path.exists():
        return "no manifest.json yet"

    manifest = read_json(manifest_path)
    if manifest is None:
        return "manifest.json not parseable yet"

    if manifest.get("complete") is False:
        return "manifest says complete=false"

    for name in MINIMUM_FILES:
        if not (bundle_path / name).exists():
            return "missing %s" % name

    missing = [
        rel
        for rel in manifest_required_files(manifest)
        if not (bundle_path / rel).exists()
    ]
    if missing:
        return "manifest lists %d file(s) not present yet: %s" % (
            len(missing),
            ", ".join(sorted(missing)[:4]),
        )

    return None


def fingerprint(bundle_path: Path) -> Tuple[Tuple[str, int, int], ...]:
    """Cheap (path, size, mtime_ns) tuple over the bundle, for settle checks."""
    entries: List[Tuple[str, int, int]] = []
    for root, dirs, filenames in os.walk(bundle_path):
        dirs.sort()
        for filename in sorted(filenames):
            full = Path(root) / filename
            try:
                stat = full.stat()
            except OSError:
                continue
            rel = str(full.relative_to(bundle_path))
            entries.append((rel, stat.st_size, stat.st_mtime_ns))
    return tuple(entries)


def content_hash(bundle_path: Path) -> Tuple[str, List[str]]:
    """sha256 over every file's relative path and bytes. Order-stable."""
    digest = hashlib.sha256()
    names: List[str] = []
    for root, dirs, filenames in os.walk(bundle_path):
        dirs.sort()
        for filename in sorted(filenames):
            full = Path(root) / filename
            rel = str(full.relative_to(bundle_path))
            names.append(rel)
            digest.update(rel.encode("utf-8"))
            digest.update(b"\0")
            try:
                with full.open("rb") as handle:
                    while True:
                        chunk = handle.read(1024 * 256)
                        if not chunk:
                            break
                        digest.update(chunk)
            except OSError:
                digest.update(b"<unreadable>")
            digest.update(b"\0")
    return digest.hexdigest(), names


class SettleTracker:
    """Holds the "seen unchanged since" state between polls.

    A bundle is ready when it is complete AND its fingerprint has been
    identical for at least ``settle_seconds``, AND it is still complete on that
    second look. Both checks matter: the manifest can arrive before the ink
    PNGs, and the PNGs can still be growing after the manifest lands.
    """

    def __init__(self, settle_seconds: float, clock: Callable[[], float] = time.monotonic) -> None:
        self.settle_seconds = settle_seconds
        self._clock = clock
        self._state: Dict[str, Tuple[Tuple[Tuple[str, int, int], ...], float]] = {}

    def forget(self, bundle_path: Path) -> None:
        self._state.pop(str(bundle_path), None)

    def check(self, bundle_path: Path) -> Tuple[bool, str]:
        """Return (ready, reason). ``reason`` is for the log when not ready."""
        key = str(bundle_path)
        reason = incompleteness_reason(bundle_path)
        if reason is not None:
            self._state.pop(key, None)
            return False, reason

        now = self._clock()
        current = fingerprint(bundle_path)
        previous = self._state.get(key)

        if previous is None or previous[0] != current:
            self._state[key] = (current, now)
            return False, "changed, waiting %.0fs to settle" % self.settle_seconds

        if now - previous[1] < self.settle_seconds:
            return False, "settling (%.0fs of %.0fs)" % (now - previous[1], self.settle_seconds)

        # Re-check completeness after the delay, as required.
        reason = incompleteness_reason(bundle_path)
        if reason is not None:
            self._state.pop(key, None)
            return False, "incomplete on re-check: %s" % reason

        self._state.pop(key, None)
        return True, "settled"


def discover(outbox: Path) -> List[Path]:
    """Every ``*.review`` directory in outbox, oldest first. Skips ``.tmp``."""
    if not outbox.is_dir():
        return []
    found: List[Path] = []
    try:
        entries = sorted(outbox.iterdir())
    except OSError:
        return []
    for entry in entries:
        if not entry.is_dir():
            continue
        name = entry.name
        if name.startswith(".") or name.endswith(".tmp") or name.endswith(".tmp.review"):
            continue
        if not name.endswith(REVIEW_SUFFIX):
            continue
        found.append(entry)
    return found


def load_bundle(bundle_path: Path, sync_root: Path) -> Bundle:
    digest, names = content_hash(bundle_path)
    return Bundle(path=bundle_path, sync_root=sync_root, content_hash=digest, files=names)


# --------------------------------------------------------------------------
# return path resolution
# --------------------------------------------------------------------------


def _return_path_from_origin(origin: Dict[str, Any], source: str) -> ReturnPath:
    return_path = origin.get("returnPath")
    if not isinstance(return_path, dict):
        return_path = {}
    rp_type = return_path.get("type")
    if not isinstance(rp_type, str) or not rp_type.strip():
        rp_type = "none"
    return ReturnPath(
        type=rp_type.strip(),
        kind=str(origin.get("kind") or ""),
        session_id=str(return_path.get("sessionId") or origin.get("sessionId") or ""),
        trigger_id=str(return_path.get("triggerId") or ""),
        thread_title=str(origin.get("threadTitle") or ""),
        source=source,
    )


def resolve_return_path(bundle: Bundle, inbox: Path) -> ReturnPath:
    """Find the origin for a bundle, in the order most-specific first.

    1. ``manifest.json``'s own ``origin`` block, if the iPad app copied it in.
    2. ``inbox/<slug>/meta.json`` — the name-derived match, the normal case.
    3. Any ``inbox/*/meta.json`` whose ``id`` equals ``review.json``'s
       ``documentId`` — covers a renamed or re-dated inbox folder.

    Nothing found means ``type="none"``, which is a real answer, not an error:
    docs/06 gives the iPad its own share-sheet fallback for that case.
    """
    manifest = read_json(bundle.path / MANIFEST_NAME)
    if manifest and isinstance(manifest.get("origin"), dict):
        return _return_path_from_origin(manifest["origin"], "manifest.json")

    meta = read_json(inbox / bundle.slug / "meta.json")
    if meta and isinstance(meta.get("origin"), dict):
        return _return_path_from_origin(meta["origin"], "inbox/%s/meta.json" % bundle.slug)

    review = read_json(bundle.path / REVIEW_JSON)
    document_id = str(review.get("documentId")) if review and review.get("documentId") else ""
    if document_id and inbox.is_dir():
        try:
            candidates = sorted(inbox.iterdir())
        except OSError:
            candidates = []
        for entry in candidates:
            if not entry.is_dir():
                continue
            candidate = read_json(entry / "meta.json")
            if not candidate:
                continue
            if str(candidate.get("id") or "") != document_id:
                continue
            if isinstance(candidate.get("origin"), dict):
                return _return_path_from_origin(
                    candidate["origin"], "inbox/%s/meta.json (by documentId)" % entry.name
                )

    return ReturnPath(type="none", source="no meta.json found")
