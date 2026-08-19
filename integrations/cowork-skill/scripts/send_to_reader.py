#!/usr/bin/env python3
"""Write a document into the Pencil-in-the-loop reader inbox.

Mechanical half of the `send-to-reader` skill: locate the reader folder, make a
slug, avoid collisions, assemble `meta.json`, and write the bundle atomically so
a watcher on the iPad side never sees a half-written document.

On-disk contract: `docs/05-file-contracts.md`. Python 3 standard library only.

Importable:

    from send_to_reader import send, slugify, validate_reader_folder

CLI:

    send_to_reader.py --title "Auth refactor plan" --source plan.md \
        --session-id 8f3c1d --thread-title "Q3 platform planning" \
        --return-path checkin
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import sys
import time
import unicodedata
import uuid
from datetime import datetime, timezone
from pathlib import Path

__all__ = [
    "ReaderFolderError",
    "DEFAULT_CONFIG_PATH",
    "ORIGIN_KINDS",
    "RETURN_PATH_TYPES",
    "SYNC_ROOT_KEYS",
    "ENV_KEYS",
    "load_config",
    "save_config",
    "resolve_reader_folder",
    "validate_reader_folder",
    "slugify",
    "allocate_bundle_name",
    "build_meta",
    "send",
]

DEFAULT_CONFIG_PATH = Path.home() / ".pencil-loop" / "config.json"

# Canonical key is ``syncRoot`` — docs/05 calls the folder the sync root, and the
# Mac watcher reads that name. The others are accepted so an older or
# hand-written config still works.
SYNC_ROOT_KEYS = ("syncRoot", "readerFolder", "syncFolder", "folder")

# ``PENCIL_SYNC_ROOT`` is what the Claude Code MCP server uses; accepting it too
# means one exported variable configures every unit.
ENV_KEYS = ("PENCIL_SYNC_ROOT", "PENCIL_LOOP_READER_FOLDER")

ORIGIN_KINDS = ("cowork", "claude-code", "codex", "share", "manual")
RETURN_PATH_TYPES = ("poke", "checkin", "resume", "cloud", "none")

MAX_SLUG_LENGTH = 60
LOCK_STALE_SECONDS = 30


class ReaderFolderError(Exception):
    """The reader folder is missing, unset, or not shaped like a reader folder."""


# --------------------------------------------------------------------------
# config
# --------------------------------------------------------------------------


def load_config(config_path: os.PathLike | str | None = None) -> dict:
    """Return the contents of the config file, or {} if there isn't one."""
    path = Path(config_path) if config_path else DEFAULT_CONFIG_PATH
    try:
        with open(path, "r", encoding="utf-8") as handle:
            data = json.load(handle)
    except FileNotFoundError:
        return {}
    except (OSError, ValueError) as exc:
        raise ReaderFolderError(f"config at {path} is unreadable: {exc}") from exc
    if not isinstance(data, dict):
        raise ReaderFolderError(f"config at {path} is not a JSON object")
    return data


def save_config(values: dict, config_path: os.PathLike | str | None = None) -> Path:
    """Merge `values` into the config file, creating it if needed."""
    path = Path(config_path) if config_path else DEFAULT_CONFIG_PATH
    path.parent.mkdir(parents=True, exist_ok=True)
    merged = load_config(path)
    merged.update(values)
    merged.setdefault("version", 1)
    tmp = path.with_name(path.name + ".tmp")
    with open(tmp, "w", encoding="utf-8") as handle:
        json.dump(merged, handle, indent=2, sort_keys=True)
        handle.write("\n")
    os.replace(tmp, path)
    return path


def resolve_reader_folder(
    explicit: os.PathLike | str | None = None,
    config_path: os.PathLike | str | None = None,
) -> Path:
    """Find the reader folder: explicit argument, then env, then config file."""
    if explicit:
        return Path(explicit).expanduser()

    for key in ENV_KEYS:
        env = os.environ.get(key)
        if env:
            return Path(env).expanduser()

    config = load_config(config_path)
    folder = next((config[key] for key in SYNC_ROOT_KEYS if config.get(key)), None)
    if not folder:
        raise ReaderFolderError(
            "No reader folder configured. Ask the user for the folder they "
            "connected in the Claude desktop app and pointed the iPad app at, "
            f"then record it with: send_to_reader.py --set-folder <path>  "
            f"(writes syncRoot into {config_path or DEFAULT_CONFIG_PATH})."
        )
    return Path(folder).expanduser()


def validate_reader_folder(folder: os.PathLike | str) -> list[str]:
    """Return a list of human-readable problems. Empty list means it is usable."""
    path = Path(folder).expanduser()
    problems: list[str] = []

    if not path.exists():
        return [f"{path} does not exist"]
    if not path.is_dir():
        return [f"{path} is not a directory"]

    for name in ("inbox", "outbox"):
        child = path / name
        if not child.exists():
            problems.append(f"{path} has no {name}/ subfolder")
        elif not child.is_dir():
            problems.append(f"{child} exists but is not a directory")

    if not problems and not os.access(path / "inbox", os.W_OK):
        problems.append(f"{path / 'inbox'} is not writable")

    return problems


# --------------------------------------------------------------------------
# slugs
# --------------------------------------------------------------------------


def slugify(text: str, max_length: int = MAX_SLUG_LENGTH) -> str:
    """Lowercase, hyphenated, ASCII. Never empty; falls back to 'document'."""
    if text is None:
        text = ""
    decomposed = unicodedata.normalize("NFKD", str(text))
    ascii_text = decomposed.encode("ascii", "ignore").decode("ascii")
    ascii_text = ascii_text.lower()
    ascii_text = re.sub(r"[^a-z0-9]+", "-", ascii_text)
    slug = ascii_text.strip("-")

    if len(slug) > max_length:
        slug = slug[:max_length]
        # Prefer cutting at a word boundary rather than mid-word.
        if "-" in slug[1:]:
            slug = slug[: slug.rindex("-")]
        slug = slug.strip("-")

    return slug or "document"


def allocate_bundle_name(inbox: os.PathLike | str, date_str: str, slug: str) -> str:
    """First free `YYYY-MM-DD-<slug>`, then `-2`, `-3`, … on collision."""
    inbox_path = Path(inbox)
    base = f"{date_str}-{slug}"
    if not (inbox_path / base).exists():
        return base
    suffix = 2
    while (inbox_path / f"{base}-{suffix}").exists():
        suffix += 1
    return f"{base}-{suffix}"


# --------------------------------------------------------------------------
# meta.json
# --------------------------------------------------------------------------


def _utc_now_iso() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace(
        "+00:00", "Z"
    )


def build_meta(
    *,
    title: str,
    source_format: str,
    created_at: str | None = None,
    document_id: str | None = None,
    origin_kind: str = "cowork",
    session_id: str | None = None,
    thread_title: str | None = None,
    return_path: str | None = None,
    trigger_id: str | None = None,
    page_count: int | None = None,
) -> dict:
    """Assemble a meta.json body per docs/05-file-contracts.md."""
    if origin_kind not in ORIGIN_KINDS:
        raise ValueError(f"origin.kind must be one of {ORIGIN_KINDS}, got {origin_kind!r}")
    if return_path is not None and return_path not in RETURN_PATH_TYPES:
        raise ValueError(
            f"origin.returnPath.type must be one of {RETURN_PATH_TYPES}, got {return_path!r}"
        )
    if source_format not in ("markdown", "pdf"):
        raise ValueError(f"sourceFormat must be 'markdown' or 'pdf', got {source_format!r}")

    meta: dict = {
        "id": document_id or uuid.uuid4().hex.upper(),
        "title": title.strip() or "Untitled",
        "createdAt": created_at or _utc_now_iso(),
        "sourceFormat": source_format,
    }

    origin: dict = {"kind": origin_kind}
    if session_id:
        origin["sessionId"] = session_id
    if thread_title:
        origin["threadTitle"] = thread_title
    if return_path:
        rp: dict = {"type": return_path}
        if trigger_id:
            rp["triggerId"] = trigger_id
        origin["returnPath"] = rp
    meta["origin"] = origin

    if page_count is not None:
        meta["pageCount"] = page_count

    # Stable, readable key order matching the contract's example.
    order = ["id", "title", "createdAt", "origin", "sourceFormat", "pageCount"]
    return {key: meta[key] for key in order if key in meta}


def _pdf_page_count(path: os.PathLike | str) -> int | None:
    """Best-effort page count for an uncompressed-enough PDF. None when unsure."""
    try:
        data = Path(path).read_bytes()
    except OSError:
        return None
    counts = [int(m) for m in re.findall(rb"/Count\s+(\d+)", data)]
    if counts:
        return max(counts)
    pages = len(re.findall(rb"/Type\s*/Page[^s]", data))
    return pages or None


# --------------------------------------------------------------------------
# atomic write
# --------------------------------------------------------------------------


class _FolderLock:
    """Best-effort cross-process lock so two senders can't claim one name."""

    def __init__(self, path: Path):
        self.path = path
        self.fd: int | None = None

    def __enter__(self) -> "_FolderLock":
        self.path.parent.mkdir(parents=True, exist_ok=True)
        deadline = time.time() + LOCK_STALE_SECONDS
        while True:
            try:
                self.fd = os.open(str(self.path), os.O_CREAT | os.O_EXCL | os.O_WRONLY)
                return self
            except FileExistsError:
                try:
                    age = time.time() - self.path.stat().st_mtime
                except OSError:
                    age = 0
                if age > LOCK_STALE_SECONDS or time.time() > deadline:
                    # Stale or we waited long enough; take it.
                    try:
                        self.path.unlink()
                    except OSError:
                        pass
                    continue
                time.sleep(0.05)

    def __exit__(self, *exc_info) -> None:
        if self.fd is not None:
            os.close(self.fd)
        try:
            self.path.unlink()
        except OSError:
            pass


def _write_bundle_atomically(inbox: Path, name: str, files: dict[str, bytes]) -> Path:
    """Build the bundle in a hidden sibling .tmp dir, then rename it into place.

    Nothing under a name the watcher looks at ever exists in a partial state:
    the staging directory is dot-prefixed, and `os.rename` on the same
    filesystem is atomic.
    """
    staging = inbox / f".{name}.{os.getpid()}.tmp"
    if staging.exists():
        shutil.rmtree(staging)
    staging.mkdir(parents=True)

    try:
        for relative_name, payload in files.items():
            target = staging / relative_name
            target.parent.mkdir(parents=True, exist_ok=True)
            with open(target, "wb") as handle:
                handle.write(payload)
                handle.flush()
                os.fsync(handle.fileno())

        final = inbox / name
        if final.exists():
            raise FileExistsError(f"{final} appeared while the bundle was being built")
        os.rename(staging, final)
        return final
    except BaseException:
        shutil.rmtree(staging, ignore_errors=True)
        raise


# --------------------------------------------------------------------------
# the operation
# --------------------------------------------------------------------------


def send(
    *,
    title: str,
    markdown: str | None = None,
    pdf_path: os.PathLike | str | None = None,
    folder: os.PathLike | str | None = None,
    config_path: os.PathLike | str | None = None,
    origin_kind: str = "cowork",
    session_id: str | None = None,
    thread_title: str | None = None,
    return_path: str | None = "checkin",
    trigger_id: str | None = None,
    slug: str | None = None,
    date: str | None = None,
    dry_run: bool = False,
) -> dict:
    """Write one document into `inbox/`. Returns a result dict.

    Exactly one of `markdown` or `pdf_path` must be given. A PDF source is
    copied to `document.pdf`; markdown is written to `source.md` and the iPad
    renders the PDF on ingest.
    """
    if (markdown is None) == (pdf_path is None):
        raise ValueError("pass exactly one of markdown= or pdf_path=")

    reader_folder = resolve_reader_folder(folder, config_path)
    problems = validate_reader_folder(reader_folder)
    if problems:
        raise ReaderFolderError(
            "Reader folder is not usable: "
            + "; ".join(problems)
            + ". Expected a folder connected in the Claude desktop app "
            "containing inbox/ and outbox/."
        )

    inbox = Path(reader_folder) / "inbox"
    date_str = date or datetime.now().strftime("%Y-%m-%d")
    if not re.fullmatch(r"\d{4}-\d{2}-\d{2}", date_str):
        raise ValueError(f"date must be YYYY-MM-DD, got {date_str!r}")
    document_slug = slugify(slug or title)

    files: dict[str, bytes] = {}
    if pdf_path is not None:
        source = Path(pdf_path).expanduser()
        files["document.pdf"] = source.read_bytes()
        source_format = "pdf"
        page_count = _pdf_page_count(source)
    else:
        text = markdown if markdown.endswith("\n") else markdown + "\n"
        files["source.md"] = text.encode("utf-8")
        source_format = "markdown"
        page_count = None

    meta = build_meta(
        title=title,
        source_format=source_format,
        origin_kind=origin_kind,
        session_id=session_id,
        thread_title=thread_title,
        return_path=return_path,
        trigger_id=trigger_id,
        page_count=page_count,
    )
    files["meta.json"] = (json.dumps(meta, indent=2) + "\n").encode("utf-8")

    if dry_run:
        name = allocate_bundle_name(inbox, date_str, document_slug)
        return {
            "ok": True,
            "dryRun": True,
            "bundle": name,
            "path": str(inbox / name),
            "files": sorted(files),
            "meta": meta,
        }

    lock_path = Path(config_path).parent / "send.lock" if config_path else (
        DEFAULT_CONFIG_PATH.parent / "send.lock"
    )
    with _FolderLock(lock_path):
        name = allocate_bundle_name(inbox, date_str, document_slug)
        final = _write_bundle_atomically(inbox, name, files)

    return {
        "ok": True,
        "dryRun": False,
        "bundle": name,
        "path": str(final),
        "files": sorted(files),
        "meta": meta,
    }


# --------------------------------------------------------------------------
# CLI
# --------------------------------------------------------------------------


def _build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="send_to_reader.py",
        description="Write a document into the Pencil-in-the-loop reader inbox.",
    )
    parser.add_argument("--title", help="Document title, also the basis for the slug")
    parser.add_argument("--source", help="Path to a .md or .pdf file to send")
    parser.add_argument(
        "--stdin", action="store_true", help="Read markdown from standard input"
    )
    parser.add_argument("--slug", help="Override the generated slug")
    parser.add_argument("--date", help="Override the YYYY-MM-DD prefix")
    parser.add_argument("--folder", help="Reader folder; overrides env and config")
    parser.add_argument("--config", help="Config file path (default ~/.pencil-loop/config.json)")
    parser.add_argument("--origin-kind", default="cowork", choices=ORIGIN_KINDS)
    parser.add_argument("--session-id", help="Cowork session id, recorded in meta.json")
    parser.add_argument("--thread-title", help="Conversation title, recorded in meta.json")
    parser.add_argument(
        "--return-path",
        default="checkin",
        choices=RETURN_PATH_TYPES,
        help="How the review comes back (default: checkin)",
    )
    parser.add_argument("--trigger-id", help="Trigger id for poke or checkin return paths")
    parser.add_argument(
        "--set-folder",
        metavar="PATH",
        help="Record PATH as the reader folder in the config file, then validate it",
    )
    parser.add_argument(
        "--check",
        action="store_true",
        help="Validate the reader folder and exit; writes nothing",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Report what would be written without writing it",
    )
    return parser


def main(argv: list[str] | None = None) -> int:
    args = _build_parser().parse_args(argv)

    try:
        if args.set_folder:
            folder = Path(args.set_folder).expanduser()
            problems = validate_reader_folder(folder)
            config_file = save_config({"syncRoot": str(folder)}, args.config)
            print(
                json.dumps(
                    {
                        "ok": not problems,
                        "config": str(config_file),
                        "folder": str(folder),
                        "problems": problems,
                    },
                    indent=2,
                )
            )
            return 0 if not problems else 1

        if args.check:
            folder = resolve_reader_folder(args.folder, args.config)
            problems = validate_reader_folder(folder)
            print(
                json.dumps(
                    {"ok": not problems, "folder": str(folder), "problems": problems},
                    indent=2,
                )
            )
            return 0 if not problems else 1

        if not args.title:
            print(json.dumps({"ok": False, "error": "--title is required"}), file=sys.stderr)
            return 2
        if bool(args.source) == bool(args.stdin):
            print(
                json.dumps({"ok": False, "error": "pass exactly one of --source or --stdin"}),
                file=sys.stderr,
            )
            return 2

        markdown = None
        pdf_path = None
        if args.stdin:
            markdown = sys.stdin.read()
        else:
            source = Path(args.source).expanduser()
            if source.suffix.lower() == ".pdf":
                pdf_path = source
            else:
                markdown = source.read_text(encoding="utf-8")

        result = send(
            title=args.title,
            markdown=markdown,
            pdf_path=pdf_path,
            folder=args.folder,
            config_path=args.config,
            origin_kind=args.origin_kind,
            session_id=args.session_id,
            thread_title=args.thread_title,
            return_path=args.return_path,
            trigger_id=args.trigger_id,
            slug=args.slug,
            date=args.date,
            dry_run=args.dry_run,
        )
    except (ReaderFolderError, ValueError, OSError) as exc:
        print(json.dumps({"ok": False, "error": str(exc)}, indent=2), file=sys.stderr)
        return 1

    print(json.dumps(result, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
