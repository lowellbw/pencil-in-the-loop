"""The file-contract layer: slugs, atomic bundle writes, review reading.

Standard library only, deliberately: these functions are the part that must
keep working, and they are what the tests exercise. Nothing in this module
imports the MCP SDK, so the contract can be tested without it.

Everything written here follows docs/05-file-contracts.md.
"""

from __future__ import annotations

import json
import os
import re
import shutil
import unicodedata
import uuid
from contextlib import contextmanager
from dataclasses import dataclass
from datetime import date, datetime, timezone
from pathlib import Path
from typing import Any, Iterable, Iterator

from .config import RETURN_PATH_TYPES, detect_origin_kind, detect_session

# Guard rails. Malformed input is rejected before anything touches disk.
MAX_CONTENT_BYTES = 5 * 1024 * 1024
MAX_TITLE_CHARS = 200
MAX_TAGS = 32
MAX_TAG_CHARS = 64
MAX_SLUG_CHARS = 60
MAX_COLLISION_SUFFIX = 999

_SAFE_ID_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,200}$")
_CONTROL_RE = re.compile(r"[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]")
_HEADING_RE = re.compile(r"^#\s+(.+?)\s*$", re.MULTILINE)


class ValidationError(ValueError):
    """Input that must never be allowed to reach the sync folder."""


# --------------------------------------------------------------------- slugs


def slugify(text: str) -> str:
    """Lowercase, hyphenated, ASCII — the slug rules from docs/05.

    Accented Latin folds to its base letter; anything that leaves no ASCII
    alphanumerics behind becomes ``untitled`` rather than an empty name.

    NOTE: ``integrations/cowork-skill`` implements these same rules
    separately. The two must be reconciled — see the README.
    """
    if not isinstance(text, str):
        raise ValidationError("title must be a string")
    folded = unicodedata.normalize("NFKD", text)
    ascii_only = folded.encode("ascii", "ignore").decode("ascii").lower()
    hyphenated = re.sub(r"[^a-z0-9]+", "-", ascii_only).strip("-")
    if len(hyphenated) > MAX_SLUG_CHARS:
        cut = hyphenated[:MAX_SLUG_CHARS]
        if "-" in cut:
            cut = cut.rsplit("-", 1)[0]
        hyphenated = cut.strip("-")
    return hyphenated or "untitled"


def bundle_name(title: str, when: date | None = None) -> str:
    """``YYYY-MM-DD-<slug>``, using the local date."""
    day = when or datetime.now().date()
    return f"{day.isoformat()}-{slugify(title)}"


def candidate_names(base: str) -> Iterable[str]:
    """``base``, then ``base-2``, ``base-3``… as docs/05 requires."""
    yield base
    for n in range(2, MAX_COLLISION_SUFFIX + 1):
        yield f"{base}-{n}"


# ---------------------------------------------------------------- validation


def _reject_control_chars(value: str, field: str) -> None:
    if _CONTROL_RE.search(value):
        raise ValidationError(f"{field} contains control characters")


def validate_content(content: Any) -> str:
    if not isinstance(content, str):
        raise ValidationError("content must be a string")
    text = content.replace("\r\n", "\n").replace("\r", "\n")
    if not text.strip():
        raise ValidationError("content is empty")
    if "\x00" in text:
        raise ValidationError("content contains a null byte")
    try:
        encoded = text.encode("utf-8")
    except UnicodeEncodeError as exc:  # lone surrogates
        raise ValidationError(f"content is not encodable as UTF-8: {exc}") from exc
    if len(encoded) > MAX_CONTENT_BYTES:
        raise ValidationError(
            f"content is {len(encoded)} bytes, over the "
            f"{MAX_CONTENT_BYTES} byte limit"
        )
    return text


def derive_title(content: str) -> str:
    """Fall back to the first H1, then the first non-empty line."""
    match = _HEADING_RE.search(content)
    if match:
        return match.group(1).strip()[:MAX_TITLE_CHARS]
    for line in content.splitlines():
        stripped = line.strip().lstrip("#").strip()
        if stripped:
            return stripped[:MAX_TITLE_CHARS]
    return "Untitled"


def validate_title(title: Any, content: str) -> str:
    if title is None or (isinstance(title, str) and not title.strip()):
        return derive_title(content)
    if not isinstance(title, str):
        raise ValidationError("title must be a string")
    cleaned = " ".join(title.split())
    _reject_control_chars(cleaned, "title")
    if len(cleaned) > MAX_TITLE_CHARS:
        raise ValidationError(f"title is longer than {MAX_TITLE_CHARS} characters")
    return cleaned


def validate_tags(tags: Any) -> list[str]:
    if tags is None:
        return []
    if isinstance(tags, str):
        raise ValidationError("tags must be a list of strings, not a string")
    if not isinstance(tags, (list, tuple)):
        raise ValidationError("tags must be a list of strings")
    if len(tags) > MAX_TAGS:
        raise ValidationError(f"no more than {MAX_TAGS} tags")
    cleaned: list[str] = []
    for tag in tags:
        if not isinstance(tag, str):
            raise ValidationError("every tag must be a string")
        value = " ".join(tag.split())
        if not value:
            continue
        _reject_control_chars(value, "tag")
        if len(value) > MAX_TAG_CHARS:
            raise ValidationError(f"tag {value[:20]!r} is too long")
        if value not in cleaned:
            cleaned.append(value)
    return cleaned


def validate_bundle_id(raw: Any) -> str:
    """Accept ``<name>`` or ``<name>.review``; reject anything path-like."""
    if not isinstance(raw, str):
        raise ValidationError("id must be a string")
    value = raw.strip().strip("/")
    if value.endswith(".review"):
        value = value[: -len(".review")]
    if not value or value in (".", ".."):
        raise ValidationError("id is empty")
    if "/" in value or "\\" in value or "\x00" in value:
        raise ValidationError("id must not contain a path separator")
    if not _SAFE_ID_RE.match(value):
        raise ValidationError(
            "id must be a bundle folder name, e.g. 2026-08-18-auth-refactor-plan"
        )
    return value


# ---------------------------------------------------------------- timestamps


def utc_now_iso(now: datetime | None = None) -> str:
    moment = now or datetime.now(timezone.utc)
    if moment.tzinfo is None:
        moment = moment.replace(tzinfo=timezone.utc)
    return moment.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


# -------------------------------------------------------------- return paths


def resolve_return_path(kind: str, session: dict[str, Any]) -> dict[str, Any]:
    """Record enough for the Mac-side watcher to choose a return path.

    We do not fire anything — that is the watcher's job (docs/06). We also
    do not claim any of these commands work: docs/08 question 7 lists their
    semantics as unverified, so every candidate carries ``verified: false``
    and the watcher is expected to try them in order and fall back to the
    share-sheet path described in docs/06.
    """
    session_id = session.get("sessionId")
    if not session_id or kind not in ("claude-code", "codex"):
        return {
            "type": "none",
            "verified": False,
            "sessionIdSource": session.get("source", "unavailable"),
        }

    if kind == "codex":
        candidates = [
            {
                "type": "resume",
                "tool": "codex",
                "command": ["codex", "resume", session_id],
                "verified": False,
            }
        ]
        preferred = "resume"
    else:
        # `claude --cloud` addresses the *web* session, which carries a
        # different id from the local session UUID when Claude Code is
        # running remotely. Prefer it when we have it.
        cloud_id = session.get("cloudSessionId") or session_id
        candidates = [
            {
                "type": "cloud",
                "tool": "claude",
                "command": ["claude", "--cloud", cloud_id, "-p", "<review>"],
                "sessionId": cloud_id,
                "verified": False,
                "note": "queues into a live web session; works away from the Mac",
            },
            {
                "type": "resume",
                "tool": "claude",
                "command": ["claude", "-p", "<review>", "--resume", session_id],
                "sessionId": session_id,
                "verified": False,
                "note": "local session must be idle; a running session cannot "
                "be injected into",
            },
        ]
        preferred = "cloud"

    path: dict[str, Any] = {
        "type": preferred,
        "sessionId": session_id,
        "sessionIdSource": session.get("source", "unavailable"),
        "verified": False,
        "candidates": candidates,
    }
    if session.get("cloudSessionId") and kind == "claude-code":
        path["cloudSessionId"] = session["cloudSessionId"]
    if session.get("cwd"):
        path["cwd"] = session["cwd"]
    if session.get("transcriptPath"):
        path["transcriptPath"] = session["transcriptPath"]
    assert path["type"] in RETURN_PATH_TYPES
    return path


# ------------------------------------------------------------- atomic writes


def _fsync_dir(path: Path) -> None:
    try:
        fd = os.open(path, os.O_RDONLY)
    except OSError:
        return
    try:
        os.fsync(fd)
    except OSError:
        pass
    finally:
        os.close(fd)


def _write_file(path: Path, text: str) -> None:
    with path.open("w", encoding="utf-8", newline="\n") as handle:
        handle.write(text)
        handle.flush()
        os.fsync(handle.fileno())


# Public aliases for callers outside this module (the relay writes bundles the
# same way the folder transport does, and must not reimplement the discipline).
#
# The underscore names stay because the write path below calls them by module
# global, and the atomicity tests rebind those globals to inject failures. Two
# names for one function is worth a durable test that proves a half-written
# bundle never appears.
write_file = _write_file
fsync_dir = _fsync_dir


def _ensure_h1(content: str, title: str) -> str:
    """Give the renderer a title to work with, without rewriting the body."""
    for line in content.splitlines():
        if line.strip():
            return content if line.lstrip().startswith("# ") else (
                f"# {title}\n\n{content}"
            )
    return f"# {title}\n\n{content}"


def build_meta(
    *,
    title: str,
    kind: str,
    session: dict[str, Any],
    tags: list[str],
    thread_title: str | None = None,
    now: datetime | None = None,
    document_id: str | None = None,
) -> dict[str, Any]:
    """The ``meta.json`` payload, shaped exactly as docs/05 shows it.

    ``pageCount`` is deliberately absent: we ship markdown and the iPad app
    renders the PDF, so the page count is not knowable at write time.
    """
    origin: dict[str, Any] = {"kind": kind}
    if session.get("sessionId"):
        origin["sessionId"] = session["sessionId"]
    if thread_title:
        origin["threadTitle"] = thread_title
    origin["returnPath"] = resolve_return_path(kind, session)

    meta: dict[str, Any] = {
        "id": document_id or uuid.uuid4().hex.upper(),
        "title": title,
        "createdAt": utc_now_iso(now),
        "origin": origin,
        "sourceFormat": "markdown",
    }
    if tags:
        meta["tags"] = tags
    return meta


@dataclass
class BundleStaging:
    """A bundle being built, and where it landed once it has.

    `final` is None until the rename succeeds, which is the only moment the
    bundle becomes visible to anything watching the directory.
    """

    directory: Path
    final: Path | None = None


def stage_bundle(parent: Path, base: str) -> Path:
    """A hidden sibling directory to build a bundle in.

    Dot-prefixed so every watcher in `integrations/` ignores it while it is
    being filled, and uniquely suffixed so two writers cannot collide.
    """
    parent.mkdir(parents=True, exist_ok=True)
    staging = parent / f".{base}.{uuid.uuid4().hex[:8]}.tmp"
    staging.mkdir(parents=False, exist_ok=False)
    return staging


def commit_bundle(staging: Path, parent: Path, base: str) -> Path:
    """Land a staged bundle with one rename, taking the first free name.

    - Raises: OSError when every candidate name is taken.
    """
    _fsync_dir(staging)
    for name in candidate_names(base):
        target = parent / name
        if target.exists():
            continue
        try:
            os.rename(staging, target)
        except OSError:
            continue
        _fsync_dir(parent)
        return target
    raise OSError(
        f"could not place bundle: {MAX_COLLISION_SUFFIX} name collisions on {base}"
    )


def discard_bundle(staging: Path) -> None:
    """Remove a staged bundle. Never raises — the caller is already failing."""
    shutil.rmtree(staging, ignore_errors=True)


@contextmanager
def atomic_bundle_dir(parent: Path, base: str) -> Iterator[BundleStaging]:
    """Build a bundle and land it, or leave nothing behind.

    For a writer that has every file to hand in one go. A writer that receives
    files across several requests — the relay taking a review bundle upload —
    holds `stage_bundle` / `commit_bundle` / `discard_bundle` itself, because
    the staging directory has to outlive the request that created it.
    """
    handle = BundleStaging(stage_bundle(parent, base))
    try:
        yield handle
        handle.final = commit_bundle(handle.directory, parent, base)
    except BaseException:
        discard_bundle(handle.directory)
        raise


def prepare_inbox_bundle(
    *,
    content: Any,
    title: Any = None,
    tags: Any = None,
    origin_kind: str | None = None,
    session_id: str | None = None,
    thread_title: str | None = None,
    now: datetime | None = None,
    document_id: str | None = None,
) -> tuple[str, dict[str, Any], str]:
    """Validate and shape a bundle, touching no filesystem at all.

    Split out so the relay and the folder transport cannot drift on slug rules,
    validation limits, title derivation or the shape of `meta.json`. Everything
    that can be rejected is rejected here, before any caller has created a
    directory — which is what makes "a failure leaves no trace" cheap to keep
    true rather than something each writer has to remember.

    - Returns: the base folder name, the `meta.json` payload, and `source.md`.
    - Raises: `ValidationError`, and nothing else.
    """
    body = validate_content(content)
    clean_title = validate_title(title, body)
    clean_tags = validate_tags(tags)
    kind = detect_origin_kind(origin_kind)
    session = detect_session(session_id)

    meta = build_meta(
        title=clean_title,
        kind=kind,
        session=session,
        tags=clean_tags,
        thread_title=thread_title,
        now=now,
        document_id=document_id,
    )
    base = bundle_name(clean_title, now.date() if now else None)
    return base, meta, _ensure_h1(body, clean_title)


def write_inbox_bundle(
    sync_root: Path,
    *,
    content: Any,
    title: Any = None,
    tags: Any = None,
    origin_kind: str | None = None,
    session_id: str | None = None,
    thread_title: str | None = None,
    now: datetime | None = None,
) -> dict[str, Any]:
    """Validate, then write ``inbox/YYYY-MM-DD-<slug>/`` atomically.

    Everything is built inside a hidden sibling ``.tmp`` directory and moved
    into place with a single rename, so a watcher never sees a partial
    bundle. If anything fails, the temporary directory is removed and the
    inbox is left exactly as it was.
    """
    # 1 · validate before touching the filesystem at all
    base, meta, source_md = prepare_inbox_bundle(
        content=content,
        title=title,
        tags=tags,
        origin_kind=origin_kind,
        session_id=session_id,
        thread_title=thread_title,
        now=now,
    )

    inbox = Path(sync_root).expanduser() / "inbox"

    # 2 · build in a uniquely named hidden temp dir, then land it with one
    #     rename. `atomic_bundle_dir` removes the staging directory on any
    #     failure, so a half-written bundle never reaches the inbox.
    with atomic_bundle_dir(inbox, base) as staging:
        _write_file(staging.directory / "source.md", source_md)
        _write_file(
            staging.directory / "meta.json",
            json.dumps(meta, indent=2, ensure_ascii=False) + "\n",
        )

    final = staging.final
    if final is None:  # unreachable: the manager raises rather than returning
        raise OSError(f"bundle did not land: {base}")
    return {
        "id": final.name,
        "path": str(final),
        "title": meta["title"],
        "tags": meta.get("tags", []),
        "origin": meta["origin"],
        "documentId": meta["id"],
        "createdAt": meta["createdAt"],
    }


# ----------------------------------------------------------- reading reviews
# Strictly read-only. Nothing below creates, moves or deletes anything.


def _read_text(path: Path) -> str | None:
    try:
        return path.read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError):
        return None


def _read_json_file(path: Path) -> Any:
    text = _read_text(path)
    if text is None:
        return None
    try:
        return json.loads(text)
    except ValueError:
        return None


# Public aliases, for the relay. Same reasoning as write_file/fsync_dir above:
# the underscore names stay because this module calls them by module global.
read_text_file = _read_text
read_json_file = _read_json_file


def _title_from_review_md(text: str | None) -> str | None:
    if not text:
        return None
    match = _HEADING_RE.search(text)
    if not match:
        return None
    heading = match.group(1).strip()
    for dash in ("—", "–", "-"):
        marker = f"Review {dash} "
        if heading.startswith(marker):
            return heading[len(marker):].strip()
    return heading


def _title_from_name(name: str) -> str:
    stem = re.sub(r"^\d{4}-\d{2}-\d{2}-", "", name)
    return stem.replace("-", " ").strip().capitalize() or name


def _count_comments(review_json: Any, review_md: str | None) -> int:
    if isinstance(review_json, dict):
        comments = review_json.get("comments")
        if isinstance(comments, list):
            return len(comments)
    if review_md:
        return len(re.findall(r"^###\s+\d+\s+—", review_md, re.MULTILINE)) or len(
            re.findall(r"^###\s+", review_md, re.MULTILINE)
        )
    return 0


def summarise_review(bundle: Path) -> dict[str, Any]:
    """One row for ``list_reviews``. Never raises on a malformed bundle."""
    review_md = _read_text(bundle / "review.md")
    review_json = _read_json_file(bundle / "review.json")
    manifest = _read_json_file(bundle / "manifest.json")

    title = _title_from_review_md(review_md)
    if not title and isinstance(manifest, dict):
        candidate = manifest.get("title")
        if isinstance(candidate, str) and candidate.strip():
            title = candidate.strip()
    if not title:
        title = _title_from_name(bundle.name[: -len(".review")])

    reviewed_at = None
    for source in (review_json, manifest):
        if isinstance(source, dict):
            value = source.get("reviewedAt")
            if isinstance(value, str) and value.strip():
                reviewed_at = value.strip()
                break
    if reviewed_at is None:
        try:
            reviewed_at = utc_now_iso(
                datetime.fromtimestamp(bundle.stat().st_mtime, tz=timezone.utc)
            )
        except OSError:
            reviewed_at = None

    summary: dict[str, Any] = {
        "id": bundle.name[: -len(".review")],
        "title": title,
        "reviewedAt": reviewed_at,
        "commentCount": _count_comments(review_json, review_md),
        "hasReply": (bundle / "reply.md").is_file(),
        "hasReviewMarkdown": review_md is not None,
        "path": str(bundle),
    }
    if review_md is None and review_json is None:
        summary["warning"] = "bundle has neither review.md nor review.json"
    return summary


def list_review_bundles(sync_root: Path) -> list[dict[str, Any]]:
    """Every ``outbox/*.review/`` bundle, newest first.

    A missing outbox is not an error — the iPad may never have run.
    """
    outbox = Path(sync_root).expanduser() / "outbox"
    if not outbox.is_dir():
        return []
    rows: list[dict[str, Any]] = []
    try:
        entries = sorted(outbox.iterdir())
    except OSError:
        return []
    for entry in entries:
        if entry.name.startswith(".") or not entry.name.endswith(".review"):
            continue
        if not entry.is_dir():
            continue
        rows.append(summarise_review(entry))
    rows.sort(key=lambda row: (row.get("reviewedAt") or "", row["id"]), reverse=True)
    return rows


def read_review(sync_root: Path, raw_id: Any) -> dict[str, Any]:
    """Full contents of one review bundle. Read-only, always.

    Raises ``FileNotFoundError`` when the id names no bundle, so the caller
    can tell "not there yet" apart from "broken".
    """
    name = validate_bundle_id(raw_id)
    outbox = (Path(sync_root).expanduser() / "outbox").resolve()
    bundle = (outbox / f"{name}.review").resolve()
    # Defence in depth: the id is already sanitised, but never escape outbox.
    if outbox not in bundle.parents:
        raise ValidationError("id resolves outside the outbox")
    if not bundle.is_dir():
        raise FileNotFoundError(f"no review bundle with id {name!r}")

    summary = summarise_review(bundle)
    review_md = _read_text(bundle / "review.md")
    ink_dir = bundle / "ink"
    ink_images: list[str] = []
    if ink_dir.is_dir():
        try:
            ink_images = sorted(
                f"ink/{p.name}"
                for p in ink_dir.iterdir()
                if p.is_file() and not p.name.startswith(".")
            )
        except OSError:
            ink_images = []

    result = dict(summary)
    result.update(
        {
            "reviewMarkdown": review_md,
            "review": _read_json_file(bundle / "review.json"),
            "manifest": _read_json_file(bundle / "manifest.json"),
            "inkImages": ink_images,
            "replyMarkdown": _read_text(bundle / "reply.md")
            if (bundle / "reply.md").is_file()
            else None,
        }
    )
    return result
