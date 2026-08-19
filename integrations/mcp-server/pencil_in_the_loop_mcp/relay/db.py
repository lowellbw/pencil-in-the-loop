"""The relay's index: a cursor, a uniqueness constraint, and a completeness flag.

**This database is disposable.** Every fact in it is derivable by walking
`inbox/` and `outbox/`, and `reindex()` does exactly that. It exists so that
"what changed since cursor N" is one indexed query rather than a directory walk
per poll, and so that `documentId` uniqueness and folder-name allocation are
enforced by something atomic rather than by checking-then-writing.

That disposability is the design, not a caveat. If the file is lost, deleted or
corrupted, the relay rebuilds it and mints a fresh `epoch`; devices notice the
epoch changed, reset their cursor to zero and re-list. Nothing a user wrote can
be lost this way, because nothing a user wrote lives here.

**Single writer.** A Railway volume attaches to one instance, so the server runs
`--workers 1`. WAL plus one writer is what makes the rename-based commits in
`core.py` safe alongside these transactions.
"""

from __future__ import annotations

import os
import sqlite3
import uuid
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Iterable, Iterator

from .. import core

SCHEMA = """
CREATE TABLE IF NOT EXISTS meta (
    key   TEXT PRIMARY KEY,
    value TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS documents (
    folder_name  TEXT PRIMARY KEY,
    document_id  TEXT NOT NULL UNIQUE,
    title        TEXT,
    created_at   TEXT,
    origin_kind  TEXT,
    complete     INTEGER NOT NULL DEFAULT 0,
    staging_path TEXT,
    seq          INTEGER NOT NULL,
    updated_at   TEXT,
    deleted_at   TEXT
);

CREATE TABLE IF NOT EXISTS document_files (
    folder_name TEXT NOT NULL,
    name        TEXT NOT NULL,
    bytes       INTEGER,
    sha256      TEXT,
    present     INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY (folder_name, name)
);

CREATE TABLE IF NOT EXISTS reviews (
    folder_name  TEXT PRIMARY KEY,
    document_id  TEXT,
    revision     INTEGER NOT NULL DEFAULT 1,
    manifest_sha TEXT NOT NULL,
    reviewed_at  TEXT,
    complete     INTEGER NOT NULL DEFAULT 0,
    has_reply    INTEGER NOT NULL DEFAULT 0,
    staging_path TEXT,
    seq          INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS review_files (
    folder_name TEXT NOT NULL,
    name        TEXT NOT NULL,
    bytes       INTEGER,
    sha256      TEXT,
    present     INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY (folder_name, name)
);

CREATE INDEX IF NOT EXISTS documents_seq ON documents(seq);
CREATE INDEX IF NOT EXISTS reviews_seq   ON reviews(seq);
"""


@dataclass
class DocumentRow:
    """One inbox document, as the feed reports it."""

    folder_name: str
    document_id: str
    title: str | None
    created_at: str | None
    origin_kind: str | None
    complete: bool
    seq: int
    updated_at: str | None
    deleted_at: str | None
    files: list[dict[str, Any]] = field(default_factory=list)

    def as_feed_entry(self) -> dict[str, Any]:
        return {
            "folderName": self.folder_name,
            "documentId": self.document_id,
            "title": self.title,
            "createdAt": self.created_at,
            "seq": self.seq,
            "deletedAt": self.deleted_at,
            "files": self.files,
        }


class Index:
    """The SQLite index, and the only thing that allocates a sequence number."""

    def __init__(self, path: Path) -> None:
        self.path = Path(path)
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self.connection = sqlite3.connect(
            self.path, isolation_level=None, check_same_thread=False
        )
        self.connection.row_factory = sqlite3.Row
        self.connection.execute("PRAGMA journal_mode=WAL")
        self.connection.execute("PRAGMA synchronous=NORMAL")
        self.connection.execute("PRAGMA busy_timeout=5000")
        self.connection.execute("PRAGMA foreign_keys=ON")
        self.connection.executescript(SCHEMA)
        self._ensure_meta()

    def close(self) -> None:
        self.connection.close()

    # ------------------------------------------------------------------ meta

    def _ensure_meta(self) -> None:
        with self.transaction():
            self.connection.execute(
                "INSERT OR IGNORE INTO meta (key, value) VALUES ('seq', '0')"
            )
            self.connection.execute(
                "INSERT OR IGNORE INTO meta (key, value) VALUES (?, ?)",
                ("epoch", uuid.uuid4().hex),
            )

    @property
    def epoch(self) -> str:
        """Changes when the index is rebuilt, telling devices to re-list.

        A device that sees an unfamiliar epoch resets its cursor to zero. That
        is the whole recovery story for a lost index, and it costs one re-list
        of documents the device mostly already has pinned.
        """
        row = self.connection.execute(
            "SELECT value FROM meta WHERE key = 'epoch'"
        ).fetchone()
        return str(row["value"])

    @property
    def cursor(self) -> int:
        row = self.connection.execute(
            "SELECT value FROM meta WHERE key = 'seq'"
        ).fetchone()
        return int(row["value"])

    def transaction(self) -> Any:
        """`with index.transaction():` — one IMMEDIATE write transaction."""
        return _Transaction(self.connection)

    def next_seq(self) -> int:
        """Allocate the next sequence number.

        Must be called inside `transaction()` together with the row it stamps,
        or a reader can observe a cursor that runs ahead of the rows it names —
        which loses a document rather than repeating one, and repeating is the
        only affordable failure here.
        """
        row = self.connection.execute(
            "UPDATE meta SET value = CAST(value AS INTEGER) + 1 "
            "WHERE key = 'seq' RETURNING value"
        ).fetchone()
        return int(row["value"])

    # ------------------------------------------------------------- documents

    def document_by_id(self, document_id: str) -> DocumentRow | None:
        """The idempotency lookup: has this exact document been sent before?"""
        row = self.connection.execute(
            "SELECT * FROM documents WHERE document_id = ?", (document_id,)
        ).fetchone()
        return self._document_row(row) if row else None

    def document(self, folder_name: str) -> DocumentRow | None:
        row = self.connection.execute(
            "SELECT * FROM documents WHERE folder_name = ?", (folder_name,)
        ).fetchone()
        return self._document_row(row) if row else None

    def reserve_document(
        self,
        *,
        base: str,
        document_id: str,
        title: str | None,
        created_at: str | None,
        origin_kind: str | None,
        staging_path: Path | None,
        expected_files: Iterable[dict[str, Any]],
        inbox: Path,
    ) -> str:
        """Claim a folder name for a document that is still being uploaded.

        The name is allocated here rather than at commit time because a second
        `POST` arriving mid-upload must not be handed the same one. The PRIMARY
        KEY is what makes that atomic: a racing insert fails and we try the next
        candidate, which is the same `-2`/`-3` ladder `core.candidate_names`
        walks for the folder transport.

        - Returns: the allocated folder name.
        - Raises: OSError when every candidate is taken.
        """
        for name in core.candidate_names(base):
            if (inbox / name).exists():
                continue
            try:
                with self.transaction():
                    seq = self.next_seq()
                    self.connection.execute(
                        "INSERT INTO documents (folder_name, document_id, title, "
                        "created_at, origin_kind, complete, staging_path, seq, "
                        "updated_at) VALUES (?, ?, ?, ?, ?, 0, ?, ?, ?)",
                        (
                            name,
                            document_id,
                            title,
                            created_at,
                            origin_kind,
                            str(staging_path) if staging_path else None,
                            seq,
                            core.utc_now_iso(),
                        ),
                    )
                    for entry in expected_files:
                        self.connection.execute(
                            "INSERT OR REPLACE INTO document_files "
                            "(folder_name, name, bytes, sha256, present) "
                            "VALUES (?, ?, ?, ?, ?)",
                            (
                                name,
                                entry["name"],
                                entry.get("bytes"),
                                entry.get("sha256"),
                                1 if entry.get("present") else 0,
                            ),
                        )
                return name
            except sqlite3.IntegrityError as error:
                if "documents.document_id" in str(error):
                    raise
                continue
        raise OSError(
            f"could not allocate a folder name: {core.MAX_COLLISION_SUFFIX} "
            f"collisions on {base}"
        )

    def mark_file_present(
        self, folder_name: str, name: str, *, byte_count: int, sha256: str
    ) -> None:
        with self.transaction():
            self.connection.execute(
                "INSERT INTO document_files (folder_name, name, bytes, sha256, present) "
                "VALUES (?, ?, ?, ?, 1) "
                "ON CONFLICT(folder_name, name) DO UPDATE SET "
                "bytes = excluded.bytes, sha256 = excluded.sha256, present = 1",
                (folder_name, name, byte_count, sha256),
            )

    def missing_files(self, folder_name: str) -> list[str]:
        rows = self.connection.execute(
            "SELECT name FROM document_files WHERE folder_name = ? AND present = 0 "
            "ORDER BY name",
            (folder_name,),
        ).fetchall()
        return [str(row["name"]) for row in rows]

    def complete_document(self, folder_name: str) -> int:
        """Mark a document complete and give it a fresh sequence number.

        The seq is re-stamped rather than kept from `reserve_document` so that
        the document enters the feed at the moment it became readable, not the
        moment it was announced. A device polling in between sees nothing, which
        is the correct answer — the bytes were not there yet.
        """
        with self.transaction():
            seq = self.next_seq()
            self.connection.execute(
                "UPDATE documents SET complete = 1, staging_path = NULL, seq = ?, "
                "updated_at = ? WHERE folder_name = ?",
                (seq, core.utc_now_iso(), folder_name),
            )
        return seq

    def delete_document(self, folder_name: str) -> int:
        """Tombstone, not a row deletion — the feed has to carry the news."""
        with self.transaction():
            seq = self.next_seq()
            self.connection.execute(
                "UPDATE documents SET deleted_at = ?, seq = ? WHERE folder_name = ?",
                (core.utc_now_iso(), seq, folder_name),
            )
        return seq

    def files_for(self, folder_name: str) -> list[dict[str, Any]]:
        rows = self.connection.execute(
            "SELECT name, bytes, sha256 FROM document_files "
            "WHERE folder_name = ? AND present = 1 ORDER BY name",
            (folder_name,),
        ).fetchall()
        return [
            {"name": row["name"], "bytes": row["bytes"], "sha256": row["sha256"]}
            for row in rows
        ]

    def changes_since(self, since: int, limit: int = 100) -> list[DocumentRow]:
        """Complete documents, and tombstones, newer than `since`.

        Incomplete documents are never returned: a device must not learn about
        a document whose bytes it cannot yet download in full, because it would
        pin a partial copy and non-negotiable 2 would be a lie.
        """
        rows = self.connection.execute(
            "SELECT * FROM documents WHERE seq > ? AND (complete = 1 OR "
            "deleted_at IS NOT NULL) ORDER BY seq LIMIT ?",
            (since, limit),
        ).fetchall()
        return [self._document_row(row) for row in rows]

    def _document_row(self, row: sqlite3.Row) -> DocumentRow:
        document = DocumentRow(
            folder_name=str(row["folder_name"]),
            document_id=str(row["document_id"]),
            title=row["title"],
            created_at=row["created_at"],
            origin_kind=row["origin_kind"],
            complete=bool(row["complete"]),
            seq=int(row["seq"]),
            updated_at=row["updated_at"],
            deleted_at=row["deleted_at"],
        )
        document.files = self.files_for(document.folder_name)
        return document

    def staging_path(self, folder_name: str) -> Path | None:
        row = self.connection.execute(
            "SELECT staging_path FROM documents WHERE folder_name = ?",
            (folder_name,),
        ).fetchone()
        if row is None or row["staging_path"] is None:
            return None
        return Path(str(row["staging_path"]))

    # --------------------------------------------------------------- reviews

    def review(self, folder_name: str) -> dict[str, Any] | None:
        row = self.connection.execute(
            "SELECT * FROM reviews WHERE folder_name = ?", (folder_name,)
        ).fetchone()
        return dict(row) if row else None

    def record_review(
        self,
        *,
        folder_name: str,
        document_id: str | None,
        manifest_sha: str,
        reviewed_at: str | None,
        staging_path: Path | None,
        expected_files: Iterable[dict[str, Any]],
    ) -> tuple[int, bool]:
        """Declare a review bundle.

        Three cases, and the distinction between the first two matters:

        - **A retry.** The same manifest for a review that already landed
          complete. Same revision, no new sequence number, nothing rewritten.
          That is what makes the iPad's `flushQueue()` safe to run on every
          poll — a review delivered twice would be a duplicate message in
          someone's conversation.
        - **A resumed upload.** The same manifest for a bundle that never
          finished, because the connection died between ink pages. Same
          revision, but the staging directory is replaced so the upload can
          start again cleanly.
        - **A genuinely new bundle.** A different manifest. Revision *n+1*,
          with the previous bundle retained, so two iPads both pressing Send
          lose nothing.

        - Returns: `(revision, is_retry)`.
        """
        existing = self.review(folder_name)
        if existing is None:
            revision = 1
        elif existing["manifest_sha"] == manifest_sha:
            if existing["complete"]:
                return int(existing["revision"]), True
            revision = int(existing["revision"])
        else:
            revision = int(existing["revision"]) + 1
        with self.transaction():
            seq = self.next_seq()
            self.connection.execute(
                "INSERT INTO reviews (folder_name, document_id, revision, "
                "manifest_sha, reviewed_at, complete, has_reply, staging_path, seq) "
                "VALUES (?, ?, ?, ?, ?, 0, COALESCE("
                "(SELECT has_reply FROM reviews WHERE folder_name = ?), 0), ?, ?) "
                "ON CONFLICT(folder_name) DO UPDATE SET "
                "document_id = excluded.document_id, revision = excluded.revision, "
                "manifest_sha = excluded.manifest_sha, "
                "reviewed_at = excluded.reviewed_at, complete = 0, "
                "staging_path = excluded.staging_path, seq = excluded.seq",
                (
                    folder_name,
                    document_id,
                    revision,
                    manifest_sha,
                    reviewed_at,
                    folder_name,
                    str(staging_path) if staging_path else None,
                    seq,
                ),
            )
            self.connection.execute(
                "DELETE FROM review_files WHERE folder_name = ?", (folder_name,)
            )
            for entry in expected_files:
                self.connection.execute(
                    "INSERT INTO review_files (folder_name, name, bytes, sha256, present) "
                    "VALUES (?, ?, ?, ?, ?)",
                    (
                        folder_name,
                        entry["path"],
                        entry.get("bytes"),
                        entry.get("sha256"),
                        1 if entry.get("present") else 0,
                    ),
                )
        return revision, False

    def mark_review_file_present(
        self, folder_name: str, name: str, *, byte_count: int, sha256: str
    ) -> None:
        with self.transaction():
            self.connection.execute(
                "INSERT INTO review_files (folder_name, name, bytes, sha256, present) "
                "VALUES (?, ?, ?, ?, 1) "
                "ON CONFLICT(folder_name, name) DO UPDATE SET "
                "bytes = excluded.bytes, sha256 = excluded.sha256, present = 1",
                (folder_name, name, byte_count, sha256),
            )

    def missing_review_files(self, folder_name: str) -> list[str]:
        rows = self.connection.execute(
            "SELECT name FROM review_files WHERE folder_name = ? AND present = 0 "
            "ORDER BY name",
            (folder_name,),
        ).fetchall()
        return [str(row["name"]) for row in rows]

    def complete_review(self, folder_name: str) -> int:
        with self.transaction():
            seq = self.next_seq()
            self.connection.execute(
                "UPDATE reviews SET complete = 1, staging_path = NULL, seq = ? "
                "WHERE folder_name = ?",
                (seq, folder_name),
            )
        return seq

    def set_reply(self, folder_name: str, *, has_reply: bool) -> int:
        with self.transaction():
            seq = self.next_seq()
            self.connection.execute(
                "UPDATE reviews SET has_reply = ?, seq = ? WHERE folder_name = ?",
                (1 if has_reply else 0, seq, folder_name),
            )
        return seq

    def replies_since(self, since: int) -> list[dict[str, Any]]:
        rows = self.connection.execute(
            "SELECT folder_name, seq FROM reviews "
            "WHERE seq > ? AND has_reply = 1 ORDER BY seq",
            (since,),
        ).fetchall()
        return [
            {"folderName": row["folder_name"], "seq": int(row["seq"])} for row in rows
        ]

    def review_staging_path(self, folder_name: str) -> Path | None:
        row = self.connection.execute(
            "SELECT staging_path FROM reviews WHERE folder_name = ?", (folder_name,)
        ).fetchone()
        if row is None or row["staging_path"] is None:
            return None
        return Path(str(row["staging_path"]))

    # --------------------------------------------------------------- rebuild

    def reindex(self, sync_root: Path) -> int:
        """Rebuild every row by walking the sync root, and mint a fresh epoch.

        The recovery path, and also the migration path: drop a folder-transport
        sync root onto the volume, reindex, and every document in it is served.

        - Returns: how many documents were indexed.
        """
        root = Path(sync_root)
        inbox = root / "inbox"
        outbox = root / "outbox"

        with self.transaction():
            for table in ("documents", "document_files", "reviews", "review_files"):
                self.connection.execute(f"DELETE FROM {table}")
            self.connection.execute(
                "UPDATE meta SET value = ? WHERE key = 'epoch'", (uuid.uuid4().hex,)
            )
            self.connection.execute("UPDATE meta SET value = '0' WHERE key = 'seq'")

        count = 0
        for directory in sorted(_visible_directories(inbox)):
            meta = core.read_json_file(directory / "meta.json")
            meta = meta if isinstance(meta, dict) else {}
            document_id = str(meta.get("id") or f"reindexed-{directory.name}")
            origin = meta.get("origin")
            files = [
                {
                    "name": entry.name,
                    "bytes": entry.stat().st_size,
                    "sha256": None,
                    "present": True,
                }
                for entry in sorted(directory.iterdir())
                if entry.is_file() and not entry.name.startswith(".")
            ]
            try:
                with self.transaction():
                    seq = self.next_seq()
                    self.connection.execute(
                        "INSERT INTO documents (folder_name, document_id, title, "
                        "created_at, origin_kind, complete, seq, updated_at) "
                        "VALUES (?, ?, ?, ?, ?, 1, ?, ?)",
                        (
                            directory.name,
                            document_id,
                            meta.get("title"),
                            meta.get("createdAt"),
                            (origin or {}).get("kind")
                            if isinstance(origin, dict)
                            else None,
                            seq,
                            core.utc_now_iso(),
                        ),
                    )
                    for entry in files:
                        self.connection.execute(
                            "INSERT INTO document_files (folder_name, name, bytes, "
                            "sha256, present) VALUES (?, ?, ?, ?, 1)",
                            (
                                directory.name,
                                entry["name"],
                                entry["bytes"],
                                entry["sha256"],
                            ),
                        )
                count += 1
            except sqlite3.IntegrityError:
                # Two directories claiming one documentId. The second is a copy
                # somebody made by hand; index the first and leave the other on
                # disk rather than dropping bytes we did not write.
                continue

        for directory in sorted(_visible_directories(outbox)):
            if not directory.name.endswith(".review"):
                continue
            folder_name = directory.name[: -len(".review")]
            manifest = core.read_json_file(directory / "manifest.json")
            manifest = manifest if isinstance(manifest, dict) else {}
            with self.transaction():
                seq = self.next_seq()
                self.connection.execute(
                    "INSERT OR REPLACE INTO reviews (folder_name, document_id, "
                    "revision, manifest_sha, reviewed_at, complete, has_reply, seq) "
                    "VALUES (?, ?, 1, ?, ?, 1, ?, ?)",
                    (
                        folder_name,
                        manifest.get("documentId"),
                        f"reindexed-{folder_name}",
                        manifest.get("createdAt"),
                        1 if (directory / "reply.md").exists() else 0,
                        seq,
                    ),
                )
        return count


class _Transaction:
    """`BEGIN IMMEDIATE` … `COMMIT`, or `ROLLBACK` on any exception."""

    def __init__(self, connection: sqlite3.Connection) -> None:
        self.connection = connection
        self.owns = False

    def __enter__(self) -> _Transaction:
        if not self.connection.in_transaction:
            self.connection.execute("BEGIN IMMEDIATE")
            self.owns = True
        return self

    def __exit__(self, exc_type: Any, exc: Any, tb: Any) -> None:
        if not self.owns:
            return
        if exc_type is None:
            self.connection.execute("COMMIT")
        else:
            self.connection.execute("ROLLBACK")


def _visible_directories(parent: Path) -> Iterator[Path]:
    if not parent.is_dir():
        return
    for entry in parent.iterdir():
        if entry.is_dir() and not entry.name.startswith("."):
            yield entry
