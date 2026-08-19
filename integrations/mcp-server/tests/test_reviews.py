"""Tests for reading review bundles out of outbox/. Read-only, always."""

from __future__ import annotations

import json
import os
from datetime import datetime, timezone
import unittest
from pathlib import Path
from tempfile import TemporaryDirectory

from pencil_in_the_loop_mcp import core

REVIEW_MD = """# Review — Auth refactor plan

Reviewed 18 Aug 2026, 21:14 · 2 comments · 1 inked page
Origin: Claude Code · session 8f3c1d

## What I want done

Rework phase 2 with the shadow read, then re-scope the estimate.

## Comments

### 1 — page 1

> The migration runs in a single deploy.

No dual-write window means we can't roll back.

### 2 — page 2

> await refresh(session)

Needs exponential backoff and a cap.
"""

REVIEW_JSON = {
    "documentId": "F7A1",
    "reviewedAt": "2026-08-18T21:14:00Z",
    "closingInstruction": "Rework phase 2 with the shadow read.",
    "comments": [
        {"id": "C1", "index": 1, "text": "No dual-write window.", "source": "voice"},
        {"id": "C2", "index": 2, "text": "Needs backoff.", "source": "handwriting"},
    ],
    "inkPages": [{"pageIndex": 0, "image": "ink/page-01.png"}],
}


def make_outbox(root: Path) -> None:
    """A fixture outbox covering the cases list_reviews has to survive."""
    outbox = root / "outbox"

    full = outbox / "2026-08-18-auth-refactor-plan.review"
    (full / "ink").mkdir(parents=True)
    (full / "review.md").write_text(REVIEW_MD, encoding="utf-8")
    (full / "review.json").write_text(json.dumps(REVIEW_JSON), encoding="utf-8")
    (full / "manifest.json").write_text(json.dumps({"version": 1}), encoding="utf-8")
    (full / "ink" / "page-01.png").write_bytes(b"\x89PNG\r\n\x1a\n")
    (full / "ink" / ".DS_Store").write_bytes(b"junk")

    replied = outbox / "2026-08-17-q3-planning.review"
    replied.mkdir(parents=True)
    (replied / "review.md").write_text(
        "# Review — Q3 planning\n\n## Comments\n\n### 1 — page 1\n\nfine\n",
        encoding="utf-8",
    )
    (replied / "reply.md").write_text("Done, see the new draft.\n", encoding="utf-8")

    broken = outbox / "2026-08-16-broken.review"
    broken.mkdir(parents=True)
    (broken / "review.json").write_text("{not json at all", encoding="utf-8")

    # things list_reviews must ignore
    (outbox / ".2026-08-19-in-flight.review.tmp").mkdir(parents=True)
    (outbox / "not-a-review").mkdir(parents=True)
    (outbox / "stray.review").write_text("a file, not a directory", encoding="utf-8")

    # Pin directory mtimes. list_review_bundles sorts on review.json's
    # `reviewedAt` and falls back to the directory's mtime when there is none,
    # so a bundle without a readable review.json otherwise sorts by wall-clock
    # "now" -- which silently reorders this fixture the moment the date rolls
    # over. Explicit mtimes make the assertion mean what it says.
    for name, when in (
        ("2026-08-18-auth-refactor-plan.review", "2026-08-18T21:14:00Z"),
        ("2026-08-17-q3-planning.review", "2026-08-17T09:00:00Z"),
        ("2026-08-16-broken.review", "2026-08-16T09:00:00Z"),
    ):
        stamp = datetime.strptime(when, "%Y-%m-%dT%H:%M:%SZ").replace(
            tzinfo=timezone.utc
        ).timestamp()
        os.utime(outbox / name, (stamp, stamp))


class ReviewReadingTests(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.root = Path(self._tmp.name) / "sync"
        make_outbox(self.root)

    def test_list_reviews_on_the_fixture_outbox(self) -> None:
        rows = core.list_review_bundles(self.root)
        self.assertEqual(
            [r["id"] for r in rows],
            [
                "2026-08-18-auth-refactor-plan",
                "2026-08-17-q3-planning",
                "2026-08-16-broken",
            ],
            "newest first, ignoring temp dirs, non-.review dirs and stray files",
        )

        full, replied, broken = rows
        self.assertEqual(full["title"], "Auth refactor plan")
        self.assertEqual(full["reviewedAt"], "2026-08-18T21:14:00Z")
        self.assertEqual(full["commentCount"], 2)
        self.assertFalse(full["hasReply"])

        self.assertEqual(replied["title"], "Q3 planning")
        self.assertEqual(replied["commentCount"], 1, "counted from review.md")
        self.assertTrue(replied["hasReply"])

        self.assertEqual(broken["title"], "Broken", "falls back to the folder name")
        self.assertEqual(broken["commentCount"], 0)
        self.assertIn("warning", broken)

    def test_list_reviews_when_the_ipad_has_never_run(self) -> None:
        empty = Path(self._tmp.name) / "never-used"
        self.assertEqual(core.list_review_bundles(empty), [])

    def test_get_review_returns_markdown_and_structured_json(self) -> None:
        review = core.read_review(self.root, "2026-08-18-auth-refactor-plan")
        self.assertIn("Rework phase 2", review["reviewMarkdown"])
        self.assertEqual(review["review"]["documentId"], "F7A1")
        self.assertEqual(review["manifest"], {"version": 1})
        self.assertEqual(review["inkImages"], ["ink/page-01.png"], "hidden files skipped")
        self.assertIsNone(review["replyMarkdown"])
        self.assertEqual(review["commentCount"], 2)

    def test_get_review_accepts_the_id_with_or_without_the_suffix(self) -> None:
        a = core.read_review(self.root, "2026-08-17-q3-planning")
        b = core.read_review(self.root, "2026-08-17-q3-planning.review")
        self.assertEqual(a, b)
        self.assertEqual(a["replyMarkdown"], "Done, see the new draft.\n")

    def test_get_review_on_a_missing_id(self) -> None:
        with self.assertRaises(FileNotFoundError):
            core.read_review(self.root, "2026-01-01-never-existed")

    def test_get_review_refuses_to_escape_the_outbox(self) -> None:
        for bad in ("../inbox", "../../etc", "/etc/passwd", "a/b"):
            with self.assertRaises(core.ValidationError, msg=bad):
                core.read_review(self.root, bad)

    def test_get_review_survives_a_malformed_bundle(self) -> None:
        review = core.read_review(self.root, "2026-08-16-broken")
        self.assertIsNone(review["reviewMarkdown"])
        self.assertIsNone(review["review"])
        self.assertEqual(review["inkImages"], [])

    def test_reading_never_mutates_the_outbox(self) -> None:
        def snapshot() -> list[tuple[str, int, int]]:
            out = []
            for path in sorted((self.root / "outbox").rglob("*")):
                stat = path.stat()
                out.append((str(path), stat.st_size, stat.st_mtime_ns))
            return out

        before = snapshot()
        core.list_review_bundles(self.root)
        for row in core.list_review_bundles(self.root):
            core.read_review(self.root, row["id"])
        self.assertEqual(snapshot(), before)


class ServerToolTests(unittest.TestCase):
    """The MCP wrappers, exercised through the underlying functions.

    Importing pencil_in_the_loop_mcp.server needs the mcp SDK; skip cleanly
    when it is not installed so the contract tests still run everywhere.
    """

    def setUp(self) -> None:
        self._tmp = TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.root = Path(self._tmp.name) / "sync"
        make_outbox(self.root)

        self._saved = dict(os.environ)
        self.addCleanup(lambda: (os.environ.clear(), os.environ.update(self._saved)))
        os.environ["PENCIL_SYNC_ROOT"] = str(self.root)
        os.environ["PENCIL_CONFIG_DIR"] = str(Path(self._tmp.name) / "config")
        for key in list(os.environ):
            if key.startswith(("CLAUDE_", "CODEX_")):
                del os.environ[key]

        try:
            from pencil_in_the_loop_mcp import server
        except ImportError as exc:  # pragma: no cover
            self.skipTest(f"mcp SDK not installed: {exc}")
        self.server = server

    def _call(self, tool, **kwargs):
        """Call through the SDK's tool object when it wraps the function."""
        fn = getattr(tool, "fn", tool)
        return fn(**kwargs)

    def test_send_to_ipad_round_trips(self) -> None:
        result = self._call(
            self.server.send_to_ipad,
            content="# A plan\n\nOne short paragraph.\n",
            title="A plan",
            tags=["spec"],
        )
        self.assertTrue(result["ok"])
        self.assertTrue((Path(result["path"]) / "meta.json").is_file())

    def test_send_to_ipad_reports_bad_input_without_raising(self) -> None:
        result = self._call(self.server.send_to_ipad, content="")
        self.assertFalse(result["ok"])
        self.assertIn("invalid input", result["error"])

    def test_list_and_get_through_the_tools(self) -> None:
        listed = self._call(self.server.list_reviews)
        self.assertTrue(listed["ok"])
        self.assertEqual(listed["count"], 3)

        got = self._call(self.server.get_review, id=listed["reviews"][0]["id"])
        self.assertTrue(got["ok"])
        self.assertIn("Rework phase 2", got["reviewMarkdown"])

        missing = self._call(self.server.get_review, id="2026-01-01-nope")
        self.assertFalse(missing["ok"])
        self.assertIn("hint", missing)


if __name__ == "__main__":
    unittest.main()
