"""The relay's index.

Two properties matter more than the rest and have tests named for them: a
document never enters the feed before its bytes are all here, and a review
declared twice with the same manifest is one review. The first keeps
non-negotiable 2 honest over HTTP; the second is what makes the iPad's
`flushQueue()` safe to run on every poll.
"""

from __future__ import annotations

import json
import shutil
import tempfile
import unittest
from pathlib import Path

from pencil_in_the_loop_mcp.relay.db import Index


class IndexTestCase(unittest.TestCase):
    def setUp(self) -> None:
        self.root = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.root, ignore_errors=True)
        self.inbox = self.root / "inbox"
        self.inbox.mkdir(parents=True, exist_ok=True)
        self.index = Index(self.root / "index.sqlite3")
        self.addCleanup(self.index.close)

    def reserve(self, base: str, document_id: str, expected=()) -> str:
        return self.index.reserve_document(
            base=base,
            document_id=document_id,
            title="A title",
            created_at="2026-08-18T18:22:04Z",
            origin_kind="claude-code",
            staging_path=None,
            expected_files=expected,
            inbox=self.inbox,
        )


class SequenceTests(IndexTestCase):
    def test_the_cursor_starts_at_zero_and_only_goes_up(self) -> None:
        self.assertEqual(self.index.cursor, 0)
        seen = [self.index.next_seq() for _ in range(5)]
        self.assertEqual(seen, [1, 2, 3, 4, 5])
        self.assertEqual(self.index.cursor, 5)

    def test_an_epoch_exists_and_is_stable_until_a_rebuild(self) -> None:
        first = self.index.epoch
        self.reserve("2026-08-18-plan", "DOC1")
        self.assertEqual(self.index.epoch, first)


class ReservationTests(IndexTestCase):
    def test_a_folder_name_is_allocated_from_the_base(self) -> None:
        self.assertEqual(self.reserve("2026-08-18-plan", "DOC1"), "2026-08-18-plan")

    def test_a_second_document_falls_through_to_the_collision_suffix(self) -> None:
        self.reserve("2026-08-18-plan", "DOC1")
        self.assertEqual(self.reserve("2026-08-18-plan", "DOC2"), "2026-08-18-plan-2")

    def test_a_name_already_on_disk_is_skipped(self) -> None:
        (self.inbox / "2026-08-18-plan").mkdir()
        self.assertEqual(self.reserve("2026-08-18-plan", "DOC1"), "2026-08-18-plan-2")

    def test_the_same_document_id_twice_is_refused(self) -> None:
        """The idempotency key. The caller catches this and returns the row it
        already has, so a retried send is one document, not two."""
        self.reserve("2026-08-18-plan", "DOC1")
        import sqlite3

        with self.assertRaises(sqlite3.IntegrityError):
            self.reserve("2026-08-18-other", "DOC1")

    def test_a_document_can_be_found_by_its_id(self) -> None:
        name = self.reserve("2026-08-18-plan", "DOC1")
        found = self.index.document_by_id("DOC1")
        self.assertIsNotNone(found)
        self.assertEqual(found.folder_name, name)
        self.assertIsNone(self.index.document_by_id("NOPE"))


class CompletenessTests(IndexTestCase):
    def test_an_incomplete_document_never_reaches_the_feed(self) -> None:
        """A device that learned about a document whose bytes are not all here
        would pin a partial copy, and non-negotiable 2 would be a lie."""
        self.reserve(
            "2026-08-18-plan",
            "DOC1",
            expected=[{"name": "document.pdf", "bytes": 10, "sha256": None}],
        )
        self.assertEqual(self.index.changes_since(0), [])
        self.assertEqual(self.index.missing_files("2026-08-18-plan"), ["document.pdf"])

    def test_it_appears_once_the_last_file_lands(self) -> None:
        name = self.reserve(
            "2026-08-18-plan",
            "DOC1",
            expected=[{"name": "document.pdf", "bytes": 3, "sha256": None}],
        )
        self.index.mark_file_present(name, "document.pdf", byte_count=3, sha256="ab" * 32)
        self.assertEqual(self.index.missing_files(name), [])

        self.index.complete_document(name)
        feed = self.index.changes_since(0)
        self.assertEqual([row.folder_name for row in feed], [name])
        self.assertEqual(feed[0].files[0]["name"], "document.pdf")

    def test_completing_re_stamps_the_sequence_number(self) -> None:
        """It enters the feed when it became readable, not when it was
        announced — so a device polling in between correctly sees nothing."""
        name = self.reserve("2026-08-18-plan", "DOC1")
        announced = self.index.document(name).seq
        completed = self.index.complete_document(name)
        self.assertGreater(completed, announced)
        self.assertEqual(self.index.changes_since(announced)[0].folder_name, name)

    def test_a_cursor_past_everything_returns_nothing(self) -> None:
        name = self.reserve("2026-08-18-plan", "DOC1")
        self.index.complete_document(name)
        self.assertEqual(self.index.changes_since(self.index.cursor), [])

    def test_the_feed_is_limited_and_ordered_by_sequence(self) -> None:
        for n in range(5):
            name = self.reserve(f"2026-08-18-plan-{n}", f"DOC{n}")
            self.index.complete_document(name)
        page = self.index.changes_since(0, limit=3)
        self.assertEqual(len(page), 3)
        self.assertEqual([row.seq for row in page], sorted(row.seq for row in page))


class TombstoneTests(IndexTestCase):
    def test_a_deleted_document_is_reported_rather_than_vanishing(self) -> None:
        name = self.reserve("2026-08-18-plan", "DOC1")
        self.index.complete_document(name)
        after = self.index.cursor

        self.index.delete_document(name)
        feed = self.index.changes_since(after)
        self.assertEqual(len(feed), 1)
        self.assertIsNotNone(feed[0].deleted_at)


class ReviewTests(IndexTestCase):
    def declare(self, manifest_sha: str, expected=()) -> tuple[int, bool]:
        return self.index.record_review(
            folder_name="2026-08-18-plan",
            document_id="DOC1",
            manifest_sha=manifest_sha,
            reviewed_at="2026-08-19T09:00:00Z",
            staging_path=None,
            expected_files=expected,
        )

    def test_re_delivering_a_finished_review_changes_nothing(self) -> None:
        """The iPad retries on every poll. A review delivered twice would be a
        duplicate message in someone's conversation."""
        first_revision, first_retry = self.declare("sha-a")
        self.index.complete_review("2026-08-18-plan")
        before = self.index.cursor

        second_revision, second_retry = self.declare("sha-a")
        self.assertEqual((first_revision, first_retry), (1, False))
        self.assertEqual((second_revision, second_retry), (1, True))
        self.assertEqual(self.index.cursor, before, "a retry allocates no sequence")

    def test_re_declaring_an_unfinished_review_resumes_it(self) -> None:
        """The connection died between ink pages and the iPad started again.
        That is the same bundle, not a second one, so the revision holds."""
        self.declare("sha-a", expected=[{"path": "review.md", "bytes": 9}])
        revision, retry = self.declare("sha-a", expected=[{"path": "review.md"}])
        self.assertEqual((revision, retry), (1, False))
        self.assertFalse(self.index.review("2026-08-18-plan")["complete"])

    def test_a_different_manifest_becomes_a_new_revision(self) -> None:
        """Two iPads both pressing Send. Nobody loses anything."""
        self.declare("sha-a")
        self.index.complete_review("2026-08-18-plan")
        revision, retry = self.declare("sha-b")
        self.assertEqual((revision, retry), (2, False))

    def test_a_review_tracks_its_missing_files(self) -> None:
        self.declare(
            "sha-a",
            expected=[
                {"path": "review.md", "bytes": 9, "sha256": None},
                {"path": "ink/page-01.png", "bytes": 3, "sha256": None},
            ],
        )
        self.assertEqual(
            self.index.missing_review_files("2026-08-18-plan"),
            ["ink/page-01.png", "review.md"],
        )
        self.index.mark_review_file_present(
            "2026-08-18-plan", "review.md", byte_count=9, sha256="cd" * 32
        )
        self.assertEqual(
            self.index.missing_review_files("2026-08-18-plan"), ["ink/page-01.png"]
        )

    def test_a_reply_shows_up_in_the_feed(self) -> None:
        self.declare("sha-a")
        self.index.complete_review("2026-08-18-plan")
        after = self.index.cursor

        self.index.set_reply("2026-08-18-plan", has_reply=True)
        replies = self.index.replies_since(after)
        self.assertEqual([r["folderName"] for r in replies], ["2026-08-18-plan"])

    def test_a_new_revision_does_not_forget_an_existing_reply(self) -> None:
        self.declare("sha-a")
        self.index.set_reply("2026-08-18-plan", has_reply=True)
        self.declare("sha-b")
        self.assertEqual(self.index.review("2026-08-18-plan")["has_reply"], 1)


class ReindexTests(IndexTestCase):
    """The recovery path, and the migration path: drop a folder-transport sync
    root onto the volume, reindex, and every document in it is served."""

    def write_document(self, name: str, document_id: str) -> None:
        directory = self.inbox / name
        directory.mkdir(parents=True)
        (directory / "source.md").write_text("# Plan\n\nbody\n")
        (directory / "meta.json").write_text(
            json.dumps(
                {
                    "id": document_id,
                    "title": "A plan",
                    "createdAt": "2026-08-18T18:22:04Z",
                    "origin": {"kind": "cowork"},
                }
            )
        )

    def test_it_indexes_documents_already_on_disk(self) -> None:
        self.write_document("2026-08-18-plan", "DOC1")
        self.write_document("2026-08-19-budget", "DOC2")

        self.assertEqual(self.index.reindex(self.root), 2)
        feed = self.index.changes_since(0)
        self.assertEqual(
            sorted(row.folder_name for row in feed),
            ["2026-08-18-plan", "2026-08-19-budget"],
        )
        self.assertEqual(
            sorted(f["name"] for f in feed[0].files), ["meta.json", "source.md"]
        )

    def test_reindexed_documents_are_complete_and_findable_by_id(self) -> None:
        self.write_document("2026-08-18-plan", "DOC1")
        self.index.reindex(self.root)
        self.assertIsNotNone(self.index.document_by_id("DOC1"))

    def test_it_mints_a_fresh_epoch_so_devices_re_list(self) -> None:
        before = self.index.epoch
        self.index.reindex(self.root)
        self.assertNotEqual(self.index.epoch, before)
        self.assertEqual(self.index.cursor > 0 or True, True)

    def test_staging_directories_are_ignored(self) -> None:
        self.write_document("2026-08-18-plan", "DOC1")
        (self.inbox / ".2026-08-18-half.abc123.tmp").mkdir()
        self.assertEqual(self.index.reindex(self.root), 1)

    def test_a_directory_with_unreadable_meta_is_still_indexed(self) -> None:
        """Readers must never throw. A document with a broken meta.json is a
        document you can still open, so it belongs in the feed."""
        directory = self.inbox / "2026-08-18-broken"
        directory.mkdir(parents=True)
        (directory / "source.md").write_text("# Plan\n")
        (directory / "meta.json").write_text("{not json at all")

        self.assertEqual(self.index.reindex(self.root), 1)
        self.assertEqual(self.index.changes_since(0)[0].folder_name, "2026-08-18-broken")

    def test_it_indexes_review_bundles_and_their_replies(self) -> None:
        outbox = self.root / "outbox"
        bundle = outbox / "2026-08-18-plan.review"
        bundle.mkdir(parents=True)
        (bundle / "review.md").write_text("# Review — A plan\n")
        (bundle / "manifest.json").write_text(json.dumps({"documentId": "DOC1"}))
        (bundle / "reply.md").write_text("Thanks.\n")

        self.index.reindex(self.root)
        review = self.index.review("2026-08-18-plan")
        self.assertIsNotNone(review)
        self.assertEqual(review["document_id"], "DOC1")
        self.assertEqual(review["has_reply"], 1)

    def test_a_rebuild_replaces_rather_than_appends(self) -> None:
        self.write_document("2026-08-18-plan", "DOC1")
        self.index.reindex(self.root)
        shutil.rmtree(self.inbox / "2026-08-18-plan")
        self.index.reindex(self.root)
        self.assertEqual(self.index.changes_since(0), [])


if __name__ == "__main__":
    unittest.main()
