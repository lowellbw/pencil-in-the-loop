"""The bundle-building layer, split out of `write_inbox_bundle`.

`write_inbox_bundle` is tested end to end in test_core.py and those tests are
the proof that this extraction changed no behaviour. What is tested here is the
part the relay needs and the folder transport never did: shaping a bundle
without a filesystem, and holding a staging directory open across more than one
request, so a review bundle can be uploaded a file at a time and still land in
one rename.
"""

from __future__ import annotations

import json
import shutil
import tempfile
import unittest
from datetime import datetime, timezone
from pathlib import Path

from pencil_in_the_loop_mcp import core

FIXED = datetime(2026, 8, 18, 18, 22, 4, tzinfo=timezone.utc)


class PrepareInboxBundleTests(unittest.TestCase):
    """Validation and shaping, with no disk anywhere near it."""

    def test_it_returns_the_name_the_meta_and_the_markdown(self) -> None:
        base, meta, source = core.prepare_inbox_bundle(
            content="# Auth refactor plan\n\nThe body.",
            now=FIXED,
        )
        self.assertEqual(base, "2026-08-18-auth-refactor-plan")
        self.assertEqual(meta["title"], "Auth refactor plan")
        self.assertEqual(meta["createdAt"], "2026-08-18T18:22:04Z")
        self.assertEqual(meta["sourceFormat"], "markdown")
        self.assertTrue(source.startswith("# Auth refactor plan"))

    def test_a_document_id_can_be_supplied_so_a_retry_is_the_same_document(self) -> None:
        """The relay's idempotency key. Two calls, one document."""
        _, first, _ = core.prepare_inbox_bundle(
            content="# Plan\n\nbody", now=FIXED, document_id="ABC123"
        )
        _, second, _ = core.prepare_inbox_bundle(
            content="# Plan\n\nbody", now=FIXED, document_id="ABC123"
        )
        self.assertEqual(first["id"], "ABC123")
        self.assertEqual(first["id"], second["id"])

    def test_two_calls_without_one_are_two_documents(self) -> None:
        """Idempotency is about retrying a call, not deduplicating intent."""
        _, first, _ = core.prepare_inbox_bundle(content="# Plan\n\nbody", now=FIXED)
        _, second, _ = core.prepare_inbox_bundle(content="# Plan\n\nbody", now=FIXED)
        self.assertNotEqual(first["id"], second["id"])

    def test_bad_input_is_refused_here_rather_than_by_the_writer(self) -> None:
        """Rejection before a caller has created anything is what makes
        "a failure leaves no trace" cheap to keep true."""
        for value in (None, "", "   ", 42, "a\x00b"):
            with self.assertRaises(core.ValidationError):
                core.prepare_inbox_bundle(content=value)

    def test_an_h1_is_added_only_when_the_body_lacks_one(self) -> None:
        _, _, added = core.prepare_inbox_bundle(content="Just a paragraph.", title="T")
        _, _, kept = core.prepare_inbox_bundle(content="# Mine\n\nBody.")
        self.assertTrue(added.startswith("# T\n"))
        self.assertEqual(kept.count("# Mine"), 1)


class StagingTests(unittest.TestCase):
    """`stage_bundle` / `commit_bundle` / `discard_bundle`."""

    def setUp(self) -> None:
        self.root = Path(tempfile.mkdtemp())
        self.parent = self.root / "inbox"
        self.addCleanup(shutil.rmtree, self.root, ignore_errors=True)

    def test_staging_is_hidden_and_inside_the_parent(self) -> None:
        staging = core.stage_bundle(self.parent, "2026-08-18-plan")
        self.assertEqual(staging.parent, self.parent)
        self.assertTrue(staging.name.startswith("."))
        self.assertTrue(staging.name.endswith(".tmp"))
        self.assertTrue(staging.is_dir())

    def test_a_staged_bundle_is_invisible_to_a_scanner_until_it_commits(self) -> None:
        """Every watcher in integrations/ skips dot-prefixed entries, so this is
        the property that makes an upload spanning several requests safe."""
        staging = core.stage_bundle(self.parent, "2026-08-18-plan")
        core.write_file(staging / "source.md", "# Plan\n")
        visible = [p.name for p in self.parent.iterdir() if not p.name.startswith(".")]
        self.assertEqual(visible, [])

        final = core.commit_bundle(staging, self.parent, "2026-08-18-plan")
        visible = [p.name for p in self.parent.iterdir() if not p.name.startswith(".")]
        self.assertEqual(visible, ["2026-08-18-plan"])
        self.assertEqual(final.name, "2026-08-18-plan")
        self.assertFalse(staging.exists())

    def test_staging_outlives_the_call_that_made_it(self) -> None:
        """The relay receives a review bundle one PUT at a time. The directory
        has to survive between requests, which is the whole reason these are
        three functions rather than one context manager."""
        staging = core.stage_bundle(self.parent, "2026-08-18-plan")
        core.write_file(staging / "review.md", "# Review\n")
        # ... a later request, with nothing held in memory but the path ...
        reopened = Path(str(staging))
        core.write_file(reopened / "manifest.json", "{}\n")

        final = core.commit_bundle(reopened, self.parent, "2026-08-18-plan")
        self.assertEqual(
            sorted(p.name for p in final.iterdir()),
            ["manifest.json", "review.md"],
        )

    def test_a_taken_name_falls_through_to_the_collision_suffix(self) -> None:
        first = core.commit_bundle(
            core.stage_bundle(self.parent, "2026-08-18-plan"),
            self.parent,
            "2026-08-18-plan",
        )
        second = core.commit_bundle(
            core.stage_bundle(self.parent, "2026-08-18-plan"),
            self.parent,
            "2026-08-18-plan",
        )
        self.assertEqual(first.name, "2026-08-18-plan")
        self.assertEqual(second.name, "2026-08-18-plan-2")

    def test_discard_leaves_nothing_behind(self) -> None:
        staging = core.stage_bundle(self.parent, "2026-08-18-plan")
        core.write_file(staging / "source.md", "# Plan\n")
        core.discard_bundle(staging)
        self.assertFalse(staging.exists())
        self.assertEqual(list(self.parent.iterdir()), [])

    def test_discard_does_not_raise_on_a_directory_already_gone(self) -> None:
        """The caller is already failing; a cleanup that throws would replace
        the real error with a worse one."""
        staging = core.stage_bundle(self.parent, "2026-08-18-plan")
        core.discard_bundle(staging)
        core.discard_bundle(staging)


class AtomicBundleDirTests(unittest.TestCase):
    """The single-request sugar over the three primitives."""

    def setUp(self) -> None:
        self.root = Path(tempfile.mkdtemp())
        self.parent = self.root / "inbox"
        self.addCleanup(shutil.rmtree, self.root, ignore_errors=True)

    def test_it_lands_the_bundle_and_reports_where(self) -> None:
        with core.atomic_bundle_dir(self.parent, "2026-08-18-plan") as staging:
            core.write_file(staging.directory / "meta.json", json.dumps({"id": "X"}))
            self.assertIsNone(staging.final, "not landed until the block ends")

        self.assertIsNotNone(staging.final)
        self.assertEqual(staging.final.name, "2026-08-18-plan")

    def test_a_failure_inside_the_block_leaves_the_parent_empty(self) -> None:
        with self.assertRaises(RuntimeError):
            with core.atomic_bundle_dir(self.parent, "2026-08-18-plan") as staging:
                core.write_file(staging.directory / "meta.json", "{}")
                raise RuntimeError("on purpose")

        self.assertEqual(list(self.parent.iterdir()), [])


if __name__ == "__main__":
    unittest.main()
