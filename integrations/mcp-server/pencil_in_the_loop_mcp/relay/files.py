"""Bytes in and out of the relay's sync root, and the rules about which bytes.

`{name}` and `{folderName}` arrive from the network, so this module is the new
attack surface. `core.validate_bundle_id` already defends the folder transport
against path traversal and is reused verbatim; what is added here is a strict
allowlist per file, because "any name inside the bundle" is a wider door than
this contract ever needs — `docs/05-file-contracts.md` names every file that
may exist, so anything else is a mistake or an attack and both deserve a 400.

Nothing here buffers a whole file. A 100MB PDF is streamed to disk, hashed on
the way past, and never exists as a `bytes` in memory.
"""

from __future__ import annotations

import hashlib
import os
import re
import shutil
from pathlib import Path
from typing import Any, Iterable, Iterator

from .. import core

# docs/05-file-contracts.md names every file an inbox bundle may hold. The
# sender writes source.md and meta.json; the iPad writes document.pdf and
# sourcemap.json back after it renders them, so a second device does not
# re-render and sourceRange resolves everywhere.
DOCUMENT_FILES = frozenset(
    {"meta.json", "source.md", "document.pdf", "sourcemap.json"}
)

# The review bundle. `ink/page-NN.png` is the only nested path in the contract.
REVIEW_FILES = frozenset({"review.md", "review.json", "manifest.json", "reply.md"})
INK_PATH_RE = re.compile(r"^ink/page-[0-9]{2,}\.png$")

# Checked against Content-Length before a byte is read. A container with 512MB
# of RAM cannot afford to discover a body is too big by receiving it.
MAX_DOCUMENT_PDF_BYTES = 100 * 1024 * 1024
MAX_OTHER_FILE_BYTES = 25 * 1024 * 1024
MAX_JSON_BODY_BYTES = 8 * 1024 * 1024
MAX_REVIEW_BUNDLE_BYTES = 50 * 1024 * 1024

# Below this the volume is treated as full. Writes fail loudly rather than
# half-succeeding, because a truncated document is worse than a refused one.
MIN_FREE_BYTES = 500 * 1024 * 1024

CHUNK_BYTES = 1024 * 1024


class FileRejected(ValueError):
    """A name or size that must never reach the sync root."""


def validate_document_file(name: Any) -> str:
    """One of the four names an inbox bundle may hold.

    - Raises: `FileRejected` for anything else, including anything with a path
      separator in it. There is deliberately no normalisation step — a name
      that needs normalising is not one of the four.
    """
    if not isinstance(name, str) or name not in DOCUMENT_FILES:
        raise FileRejected(
            f"not a document file: {name!r}. "
            f"Expected one of {sorted(DOCUMENT_FILES)}"
        )
    return name


def validate_review_file(path: Any) -> str:
    """A review bundle path: a known name, or `ink/page-NN.png`."""
    if not isinstance(path, str):
        raise FileRejected(f"not a review file: {path!r}")
    if path in REVIEW_FILES:
        return path
    if INK_PATH_RE.match(path):
        return path
    raise FileRejected(
        f"not a review file: {path!r}. Expected one of {sorted(REVIEW_FILES)} "
        "or ink/page-NN.png"
    )


def max_bytes_for(name: str) -> int:
    return MAX_DOCUMENT_PDF_BYTES if name == "document.pdf" else MAX_OTHER_FILE_BYTES


def check_declared_size(name: str, byte_count: Any) -> int:
    """The size gate, applied to a declaration rather than to a body."""
    if not isinstance(byte_count, int) or isinstance(byte_count, bool):
        raise FileRejected(f"{name}: byte count must be an integer")
    if byte_count < 0:
        raise FileRejected(f"{name}: byte count must not be negative")
    limit = max_bytes_for(name)
    if byte_count > limit:
        raise FileRejected(
            f"{name}: {byte_count} bytes exceeds the {limit} byte limit"
        )
    return byte_count


def free_bytes(path: Path) -> int:
    return shutil.disk_usage(path).free


def has_room_for(path: Path, byte_count: int) -> bool:
    """Whether a write of `byte_count` leaves the volume above its floor."""
    try:
        return free_bytes(path) - byte_count >= MIN_FREE_BYTES
    except OSError:
        # Cannot tell. Let the write attempt decide rather than refusing work
        # on the strength of a failed stat.
        return True


def sha256_of(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(CHUNK_BYTES), b""):
            digest.update(chunk)
    return digest.hexdigest()


def write_stream(chunks: Iterable[bytes], destination: Path) -> tuple[int, str]:
    """Stream `chunks` to `destination`, hashing as they pass.

    Never holds the whole file. The digest is computed on the way through
    rather than by re-reading, so a 100MB upload touches the disk once.

    - Returns: `(byte_count, sha256)`.
    """
    destination.parent.mkdir(parents=True, exist_ok=True)
    digest = hashlib.sha256()
    written = 0
    with destination.open("wb") as handle:
        for chunk in chunks:
            if not chunk:
                continue
            handle.write(chunk)
            digest.update(chunk)
            written += len(chunk)
        handle.flush()
        os.fsync(handle.fileno())
    return written, digest.hexdigest()


async def write_stream_async(chunks: Any, destination: Path) -> tuple[int, str]:
    """`write_stream` for an ASGI request body, which is an async generator.

    Same contract, same guarantee: the file is never held in memory and the
    digest is computed on the way past.
    """
    destination.parent.mkdir(parents=True, exist_ok=True)
    digest = hashlib.sha256()
    written = 0
    with destination.open("wb") as handle:
        async for chunk in chunks:
            if not chunk:
                continue
            handle.write(chunk)
            digest.update(chunk)
            written += len(chunk)
        handle.flush()
        os.fsync(handle.fileno())
    return written, digest.hexdigest()


def manifest_entries(manifest: Any) -> list[dict[str, Any]]:
    """The `files` array from a manifest, validated shape by shape.

    - Raises: `FileRejected` when the manifest is not an object, has no usable
      `files` array, or names a path outside the contract.
    """
    if not isinstance(manifest, dict):
        raise FileRejected("manifest.json must be an object")
    raw = manifest.get("files")
    if not isinstance(raw, list) or not raw:
        raise FileRejected("manifest.json must list at least one file")

    entries: list[dict[str, Any]] = []
    seen: set[str] = set()
    for item in raw:
        if not isinstance(item, dict):
            raise FileRejected("every manifest entry must be an object")
        path = validate_review_file(item.get("path"))
        if path in seen:
            raise FileRejected(f"manifest lists {path} twice")
        seen.add(path)
        entries.append(
            {
                "path": path,
                "bytes": item.get("bytes"),
                "sha256": _lower_hex(item.get("sha256"), path),
            }
        )
    if "review.md" not in seen:
        raise FileRejected("manifest.json must list review.md")
    if "manifest.json" in seen:
        raise FileRejected("manifest.json must not list itself")
    return entries


def verify_against_manifest(directory: Path, entries: Iterable[dict[str, Any]]) -> None:
    """Every declared file is present, the right size, and the right bytes.

    Runs before the bundle is committed. `manifest.json` is the parts list and
    the completeness signal — this is the check that makes it mean something
    rather than being a file nobody reads.

    - Raises: `FileRejected` naming the first file that does not match.
    """
    for entry in entries:
        path = directory / entry["path"]
        if not path.is_file():
            raise FileRejected(f"{entry['path']}: declared but not uploaded")
        actual = path.stat().st_size
        declared = entry.get("bytes")
        if isinstance(declared, int) and not isinstance(declared, bool):
            if actual != declared:
                raise FileRejected(
                    f"{entry['path']}: manifest says {declared} bytes, got {actual}"
                )
        expected = entry.get("sha256")
        if expected:
            got = sha256_of(path)
            if got != expected:
                raise FileRejected(
                    f"{entry['path']}: manifest says sha256 {expected}, got {got}"
                )


def strip_return_path_secrets(meta: dict[str, Any]) -> dict[str, Any]:
    """Remove the parts of `meta.json` that must not sit on a server.

    `origin.returnPath.triggerId` fires a turn into someone's conversation, so
    it is closer to a credential than to metadata, and it has no meaning here
    anyway: on the relay the return path *is* the MCP connection — the agent
    calls `list_reviews()` on its next turn.

    `returnPath.type` is left as a value the frozen enum already knows. A new
    `"relay"` value would buy nothing, because `docs/05` says unknown types read
    as `none`; `detail` is free text and carries the nuance instead.
    """
    if not isinstance(meta, dict):
        return meta
    origin = meta.get("origin")
    if not isinstance(origin, dict):
        return meta
    return_path = origin.get("returnPath")
    if not isinstance(return_path, dict):
        return meta
    if "triggerId" not in return_path and return_path.get("type") in (None, "none"):
        return meta

    cleaned = dict(meta)
    cleaned_origin = dict(origin)
    cleaned_origin["returnPath"] = {
        "type": "none",
        "detail": "relay; the agent pulls with list_reviews",
    }
    cleaned["origin"] = cleaned_origin
    return cleaned


def visible_files(directory: Path) -> Iterator[Path]:
    """Files in a bundle, skipping the staging and dot-files every unit ignores."""
    if not directory.is_dir():
        return
    for entry in sorted(directory.rglob("*")):
        if entry.is_file() and not any(
            part.startswith(".") for part in entry.relative_to(directory).parts
        ):
            yield entry


def _lower_hex(value: Any, path: str) -> str | None:
    if value is None:
        return None
    if not isinstance(value, str) or not re.fullmatch(r"[0-9a-fA-F]{64}", value):
        raise FileRejected(f"{path}: sha256 must be 64 hex characters")
    return value.lower()


PDF_MAGIC = b"%PDF-"


def fetch_pdf(url: str, *, timeout: float = 30.0) -> bytes:
    """Download a PDF, refusing anything that is not plainly one.

    The relay fetches rather than the caller uploading, because a hosted MCP
    server cannot read the caller's disk and a PDF does not survive a JSON-RPC
    body — the transport caps at four megabytes and base64 adds a third on top.
    A URL costs neither.

    A server fetching a URL somebody else chose is a request-forgery risk, so
    the guards are deliberate rather than incidental: `https` only, so this
    cannot be pointed at a plaintext service on the local network; the size cap
    applied while reading rather than after, so a hostile length header cannot
    exhaust the container; and the PDF magic checked on the first bytes, so what
    lands in the inbox is what the reader can open.

    - Raises: `FileRejected` with a sentence for the caller.
    """
    import urllib.error
    import urllib.request

    if not isinstance(url, str) or not url.lower().startswith("https://"):
        raise FileRejected("the address must start with https://")

    request = urllib.request.Request(url, headers={"Accept": "application/pdf"})
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            declared = response.headers.get("content-type", "").split(";")[0].strip()
            if declared and declared not in ("application/pdf", "application/octet-stream"):
                raise FileRejected(
                    f"that address returned {declared}, not a PDF"
                )
            chunks: list[bytes] = []
            total = 0
            while chunk := response.read(CHUNK_BYTES):
                total += len(chunk)
                if total > MAX_DOCUMENT_PDF_BYTES:
                    raise FileRejected(
                        f"that PDF is over the {MAX_DOCUMENT_PDF_BYTES} byte limit"
                    )
                chunks.append(chunk)
    except FileRejected:
        raise
    except urllib.error.HTTPError as error:
        raise FileRejected(f"that address returned {error.code}") from error
    except Exception as error:  # URLError, timeouts, malformed URLs
        raise FileRejected(f"that address could not be reached: {error}") from error

    body = b"".join(chunks)
    if not body.startswith(PDF_MAGIC):
        raise FileRejected("what came back is not a PDF")
    return body


def commit_to(staging: Path, target: Path) -> Path:
    """Land a staged bundle at an exact name, rather than the first free one.

    `core.commit_bundle` picks a name from the collision ladder, which is right
    when the writer has everything to hand. The relay cannot: it allocated the
    name when the upload was announced, so a second POST arriving mid-upload
    could not be handed the same one, and it must land at that name and no
    other.
    """
    core.fsync_dir(staging)
    target.parent.mkdir(parents=True, exist_ok=True)
    os.rename(staging, target)
    core.fsync_dir(target.parent)
    return target


def bundle_id(raw: Any) -> str:
    """A folder name from the network, defended exactly as the MCP server does."""
    return core.validate_bundle_id(raw)
