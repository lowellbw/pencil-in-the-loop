"""Revising and withdrawing a document after it was sent.

Two verbs on a bundle that already landed. What matters most, and what the
tests are named for: a revision never leaves a bundle whose PDF disagrees with
its markdown, a withdrawal never touches the outbox, and neither can reach
outside `inbox/`.
"""

from __future__ import annotations

import json
import os
import unittest
from datetime import datetime, timezone
from pathlib import Path
from tempfile import TemporaryDirectory

from pencil_in_the_loop_mcp import core

FIXED = datetime(2026, 8, 18, 18, 22, 4, tzinfo=timezone.utc)
LATER = datetime(2026, 8, 19, 9, 0, 0, tzinfo=timezone.utc)


class RevisionTestCase(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.root = Path(self._tmp.name) / "sync"
        self.inbox = self.root / "inbox"

    def send(self, content: str = "# Auth refactor plan\n\nBody.\n", **extra) -> str:
        landed = core.write_inbox_bundle(self.root, content=content, now=FIXED, **extra)
        return landed["id"]

    def bundle(self, folder: str) -> Path:
        return self.inbox / folder

    def source(self, folder: str) -> str:
        return (self.bundle(folder) / "source.md").read_text(encoding="utf-8")

    def meta(self, folder: str) -> dict:
        return json.loads((self.bundle(folder) / "meta.json").read_text(encoding="utf-8"))


class ReplaceTests(RevisionTestCase):
    def test_replace_rewrites_the_markdown_and_stamps_when(self) -> None:
        folder = self.send()
        result = core.revise_inbox_bundle(
            self.root, folder, content="# Auth refactor plan\n\nCorrected.\n",
            mode="replace", now=LATER,
        )
        self.assertEqual(self.source(folder), "# Auth refactor plan\n\nCorrected.\n")
        self.assertEqual(self.meta(folder)["revisedAt"], "2026-08-19T09:00:00Z")
        self.assertEqual(result["mode"], "replace")
        self.assertEqual(result["folderName"], folder)

    def test_the_title_changes_only_when_one_is_passed(self) -> None:
        folder = self.send()
        core.revise_inbox_bundle(
            self.root, folder, content="# A different H1\n\nBody.\n", mode="replace"
        )
        self.assertEqual(self.meta(folder)["title"], "Auth refactor plan")

        core.revise_inbox_bundle(
            self.root, folder, content="Body.\n", mode="replace", title="Renamed"
        )
        self.assertEqual(self.meta(folder)["title"], "Renamed")

    def test_a_replacement_without_an_h1_is_given_the_title_as_one(self) -> None:
        """Exactly as a first send is, so the renderer has a title to work with."""
        folder = self.send()
        core.revise_inbox_bundle(self.root, folder, content="Just a body.\n", mode="replace")
        self.assertTrue(self.source(folder).startswith("# Auth refactor plan\n"))

    def test_everything_derived_from_the_old_text_goes_with_it(self) -> None:
        """A stale PDF would hide the new text — the iPad prefers a PDF it is
        given over one it renders — and a narration is a cache of the source
        it was read from."""
        folder = self.send()
        for name in ("document.pdf", "sourcemap.json", "narration.mp3", ".narration.json"):
            (self.bundle(folder) / name).write_bytes(b"stale")

        result = core.revise_inbox_bundle(
            self.root, folder, content="# Auth refactor plan\n\nNew.\n", mode="replace"
        )

        for name in ("document.pdf", "sourcemap.json", "narration.mp3", ".narration.json"):
            self.assertFalse((self.bundle(folder) / name).exists(), name)
        self.assertEqual(
            sorted(result["removed"]),
            sorted(["document.pdf", "sourcemap.json", "narration.mp3", ".narration.json"]),
        )

    def test_every_other_key_in_meta_survives(self) -> None:
        folder = self.send(tags=["spec"], group="Attention Papers")
        before = self.meta(folder)
        core.revise_inbox_bundle(self.root, folder, content="# X\n\nY.\n", mode="replace")
        after = self.meta(folder)
        for key in ("id", "createdAt", "origin", "tags", "group", "sourceFormat"):
            self.assertEqual(after[key], before[key], key)

    def test_no_temporary_file_is_left_behind(self) -> None:
        folder = self.send()
        core.revise_inbox_bundle(self.root, folder, content="# X\n\nY.\n", mode="replace")
        self.assertEqual(
            sorted(entry.name for entry in self.bundle(folder).iterdir()),
            ["meta.json", "source.md"],
        )


class AppendTests(RevisionTestCase):
    def test_append_adds_the_section_after_a_blank_line(self) -> None:
        folder = self.send("# Plan\n\nBody.\n")
        result = core.revise_inbox_bundle(
            self.root, folder, content="## Addendum\n\nOne more thing.\n", mode="append"
        )
        self.assertEqual(
            self.source(folder), "# Plan\n\nBody.\n\n## Addendum\n\nOne more thing.\n"
        )
        self.assertEqual(result["mode"], "append")

    def test_append_never_adds_an_h1_or_touches_the_earlier_text(self) -> None:
        """Earlier pages come out identical, which is what keeps the reader's
        ink on the text it was drawn on."""
        folder = self.send("# Plan\n\nBody.\n")
        core.revise_inbox_bundle(self.root, folder, content="More.\n", mode="append")
        self.assertEqual(self.source(folder).count("# Plan"), 1)
        self.assertTrue(self.source(folder).startswith("# Plan\n\nBody.\n"))

    def test_append_keeps_the_title_unless_one_is_passed(self) -> None:
        folder = self.send("# Plan\n\nBody.\n")
        core.revise_inbox_bundle(self.root, folder, content="More.\n", mode="append")
        self.assertEqual(self.meta(folder)["title"], "Plan")


class RevisionRefusalTests(RevisionTestCase):
    def test_a_pdf_has_no_markdown_to_revise(self) -> None:
        folder = self.send()
        (self.bundle(folder) / "source.md").unlink()
        (self.bundle(folder) / "document.pdf").write_bytes(b"%PDF-1.4 pretend")
        with self.assertRaises(core.ValidationError):
            core.revise_inbox_bundle(self.root, folder, content="# X\n\nY.\n", mode="replace")
        self.assertEqual((self.bundle(folder) / "document.pdf").read_bytes(), b"%PDF-1.4 pretend")

    def test_the_mode_is_required_and_must_be_one_of_the_two(self) -> None:
        folder = self.send()
        for mode in (None, "", "overwrite", "REPLACE"):
            with self.assertRaises(core.ValidationError, msg=repr(mode)):
                core.revise_inbox_bundle(self.root, folder, content="# X\n\nY.\n", mode=mode)
        self.assertEqual(self.source(folder), "# Auth refactor plan\n\nBody.\n")

    def test_bad_content_is_refused_before_anything_is_touched(self) -> None:
        folder = self.send()
        (self.bundle(folder) / "narration.mp3").write_bytes(b"audio")
        for value in (None, "", "   ", "a\x00b"):
            with self.assertRaises(core.ValidationError):
                core.revise_inbox_bundle(self.root, folder, content=value, mode="replace")
        self.assertTrue((self.bundle(folder) / "narration.mp3").exists())

    def test_an_unknown_folder_is_a_not_found(self) -> None:
        with self.assertRaises(FileNotFoundError):
            core.revise_inbox_bundle(
                self.root, "2026-01-01-nope", content="# X\n\nY.\n", mode="replace"
            )

    def test_a_path_cannot_escape_the_inbox(self) -> None:
        for raw in ("../outbox", "a/b", "..", "", "..\\x"):
            with self.assertRaises(core.ValidationError, msg=raw):
                core.revise_inbox_bundle(self.root, raw, content="# X\n\nY.\n", mode="replace")


class RemovalTests(RevisionTestCase):
    def test_remove_deletes_the_bundle_and_nothing_else(self) -> None:
        keep = self.send("# Keep\n\nBody.\n")
        gone = self.send("# Gone\n\nBody.\n")
        result = core.remove_inbox_bundle(self.root, gone)
        self.assertFalse(self.bundle(gone).exists())
        self.assertTrue((self.bundle(keep) / "source.md").is_file())
        self.assertEqual(result["folderName"], gone)

    def test_the_outbox_is_never_touched(self) -> None:
        """A review the reader already sent is their work."""
        folder = self.send()
        review = self.root / "outbox" / f"{folder}.review"
        review.mkdir(parents=True)
        (review / "review.md").write_text("# Review\n", encoding="utf-8")
        core.remove_inbox_bundle(self.root, folder)
        self.assertTrue((review / "review.md").is_file())

    def test_an_unknown_folder_is_a_not_found(self) -> None:
        with self.assertRaises(FileNotFoundError):
            core.remove_inbox_bundle(self.root, "2026-01-01-nope")

    def test_a_path_cannot_escape_the_inbox(self) -> None:
        (self.root / "outbox").mkdir(parents=True)
        for raw in ("../outbox", "a/b", "..", "", ".review", "..\\x"):
            with self.assertRaises(core.ValidationError, msg=raw):
                core.remove_inbox_bundle(self.root, raw)
        self.assertTrue((self.root / "outbox").is_dir())


class FakeIndex:
    """Records what the tools tell the relay's index, when there is one."""

    def __init__(self) -> None:
        self.rewritten: list[str] = []
        self.removed: list[str] = []
        self.added: list[tuple[str, str, int]] = []
        self.known: set[str] = set()

    def note_bundle_rewritten(self, folder: str, inbox: Path) -> int:
        self.rewritten.append(folder)
        return 1

    def document(self, folder: str):
        return object() if folder in self.known else None

    def delete_document(self, folder: str) -> int:
        self.removed.append(folder)
        return 1

    def note_file_added(self, folder: str, name: str, *, byte_count: int, sha256: str) -> int:
        self.added.append((folder, name, byte_count))
        return 1


class ServerToolTests(unittest.TestCase):
    """The MCP wrappers, exercised through the underlying functions.

    Skips cleanly when the SDK is not installed, as `test_reviews.py` does.
    """

    def setUp(self) -> None:
        self._tmp = TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.root = Path(self._tmp.name) / "sync"

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
        self._previous_index = server._index
        self.addCleanup(setattr, server, "_index", self._previous_index)
        server._index = None

    def _call(self, tool, **kwargs):
        fn = getattr(tool, "fn", tool)
        return fn(**kwargs)

    def _send(self) -> str:
        sent = self._call(
            self.server.send_to_ipad, content="# A plan\n\nOne short paragraph.\n"
        )
        self.assertTrue(sent["ok"])
        return sent["id"]

    def test_revise_replaces_or_appends_and_says_which(self) -> None:
        folder = self._send()
        replaced = self._call(
            self.server.revise_on_ipad,
            folder_name=folder, content="# A plan\n\nCorrected.\n", mode="replace",
        )
        self.assertTrue(replaced["ok"])
        self.assertIn("Replaced", replaced["message"])

        appended = self._call(
            self.server.revise_on_ipad,
            folder_name=folder, content="## Addendum\n\nMore.\n", mode="append",
        )
        self.assertTrue(appended["ok"])
        self.assertIn("Added to", appended["message"])
        text = (self.root / "inbox" / folder / "source.md").read_text(encoding="utf-8")
        self.assertEqual(text, "# A plan\n\nCorrected.\n\n## Addendum\n\nMore.\n")

    def test_revise_reports_bad_input_and_a_missing_document_without_raising(self) -> None:
        folder = self._send()
        bad_mode = self._call(
            self.server.revise_on_ipad, folder_name=folder, content="x", mode="rewrite"
        )
        self.assertFalse(bad_mode["ok"])
        self.assertIn("invalid input", bad_mode["error"])

        missing = self._call(
            self.server.revise_on_ipad,
            folder_name="2026-01-01-nope", content="x", mode="replace",
        )
        self.assertFalse(missing["ok"])
        self.assertIn("hint", missing)

    def test_revise_says_when_a_narration_was_dropped(self) -> None:
        folder = self._send()
        (self.root / "inbox" / folder / "narration.mp3").write_bytes(b"audio")
        result = self._call(
            self.server.revise_on_ipad, folder_name=folder, content="# A plan\n\nB.\n", mode="replace"
        )
        self.assertIn("narration", result["message"])

    def test_remove_deletes_the_bundle_and_says_what_the_ipad_does(self) -> None:
        folder = self._send()
        result = self._call(self.server.remove_from_ipad, folder_name=folder)
        self.assertTrue(result["ok"])
        self.assertFalse((self.root / "inbox" / folder).exists())
        self.assertIn("Archived", result["message"])

        again = self._call(self.server.remove_from_ipad, folder_name=folder)
        self.assertFalse(again["ok"])
        self.assertIn("hint", again)

    def test_hosted_in_the_relay_the_tools_tell_the_index(self) -> None:
        """Against a plain folder there is nothing to tell; inside the relay the
        feed is answered from the index, and a change inside a known bundle
        reaches no device until it is told (server.py § _index)."""
        index = FakeIndex()
        self.server._index = index
        folder = self._send()
        index.known.add(folder)

        self._call(
            self.server.revise_on_ipad, folder_name=folder, content="# A plan\n\nB.\n", mode="replace"
        )
        self.assertEqual(index.rewritten, [folder])

        self._call(self.server.remove_from_ipad, folder_name=folder)
        self.assertEqual(index.removed, [folder])

    def test_a_failed_revision_tells_the_index_nothing(self) -> None:
        index = FakeIndex()
        self.server._index = index
        folder = self._send()
        self._call(self.server.revise_on_ipad, folder_name=folder, content="", mode="replace")
        self.assertEqual(index.rewritten, [])


if __name__ == "__main__":
    unittest.main()
