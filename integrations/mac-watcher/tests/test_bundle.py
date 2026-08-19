"""Bundle discovery, completeness, the settle delay, and return-path resolution."""

from __future__ import annotations

import json

from pencil_watcher import bundle as bundle_mod
from pencil_watcher.bundle import SettleTracker, load_bundle
from tests.helpers import REVIEW_MD, FakeClock, TempDirTestCase, make_config, write_bundle, write_meta


class DiscoveryTests(TempDirTestCase):
    def test_finds_review_directories_only(self) -> None:
        config = make_config(self.root)
        write_bundle(config, "2026-08-18-a")
        (config.outbox / "2026-08-18-b.review.tmp").mkdir()
        (config.outbox / "not-a-bundle").mkdir()
        (config.outbox / "stray.md").write_text("x", encoding="utf-8")
        found = [p.name for p in bundle_mod.discover(config.outbox)]
        self.assertEqual(found, ["2026-08-18-a.review"])

    def test_missing_outbox_is_not_an_error(self) -> None:
        self.assertEqual(bundle_mod.discover(self.root / "nope"), [])

    def test_slug_strips_the_review_suffix(self) -> None:
        config = make_config(self.root)
        path = write_bundle(config, "2026-08-18-auth-refactor-plan")
        item = load_bundle(path, config.sync_root)
        self.assertEqual(item.slug, "2026-08-18-auth-refactor-plan")
        self.assertEqual(item.rel_path, "outbox/2026-08-18-auth-refactor-plan.review")

    def test_title_comes_from_the_review_heading(self) -> None:
        config = make_config(self.root)
        item = load_bundle(write_bundle(config), config.sync_root)
        self.assertEqual(item.title(), "Auth refactor plan")

    def test_content_hash_changes_when_a_file_changes(self) -> None:
        config = make_config(self.root)
        path = write_bundle(config)
        first = load_bundle(path, config.sync_root).content_hash
        (path / "review.md").write_text(REVIEW_MD + "\nmore\n", encoding="utf-8")
        second = load_bundle(path, config.sync_root).content_hash
        self.assertNotEqual(first, second)


class CompletenessTests(TempDirTestCase):
    def test_missing_manifest_is_incomplete(self) -> None:
        config = make_config(self.root)
        path = config.outbox / "a.review"
        path.mkdir(parents=True)
        (path / "review.md").write_text("x", encoding="utf-8")
        self.assertIn("manifest", bundle_mod.incompleteness_reason(path) or "")

    def test_half_written_manifest_is_incomplete(self) -> None:
        config = make_config(self.root)
        path = config.outbox / "a.review"
        path.mkdir(parents=True)
        (path / "review.md").write_text("x", encoding="utf-8")
        (path / "manifest.json").write_text('{"version": 1, "fil', encoding="utf-8")
        self.assertIn("not parseable", bundle_mod.incompleteness_reason(path) or "")

    def test_manifest_listing_absent_files_is_incomplete(self) -> None:
        config = make_config(self.root)
        path = write_bundle(config, manifest={"files": ["review.md", "manifest.json", "ink/page-01.png"]})
        self.assertIn("ink/page-01.png", bundle_mod.incompleteness_reason(path) or "")

    def test_complete_false_is_respected(self) -> None:
        config = make_config(self.root)
        path = write_bundle(config, manifest={"files": ["review.md"], "complete": False})
        self.assertIn("complete=false", bundle_mod.incompleteness_reason(path) or "")

    def test_manifest_without_a_file_list_still_needs_review_md(self) -> None:
        config = make_config(self.root)
        path = write_bundle(config, manifest={"version": 1})
        self.assertIsNone(bundle_mod.incompleteness_reason(path))
        (path / "review.md").unlink()
        self.assertIn("review.md", bundle_mod.incompleteness_reason(path) or "")

    def test_object_style_file_entries_are_understood(self) -> None:
        config = make_config(self.root)
        path = write_bundle(config, manifest={"files": [{"path": "review.md"}, {"path": "ink/page-01.png"}]})
        self.assertIn("ink/page-01.png", bundle_mod.incompleteness_reason(path) or "")


class SettleTests(TempDirTestCase):
    def test_progressively_written_bundle_is_only_ready_once_it_stops_changing(self) -> None:
        """The file-provider case: the directory appears, then the files trickle in."""
        config = make_config(self.root)
        clock = FakeClock()
        tracker = SettleTracker(settle_seconds=5.0, clock=clock)

        path = config.outbox / "2026-08-18-a.review"
        path.mkdir(parents=True)

        # 1. empty directory
        ready, reason = tracker.check(path)
        self.assertFalse(ready)
        self.assertIn("manifest", reason)

        # 2. review.md lands, manifest still absent
        (path / "review.md").write_text(REVIEW_MD, encoding="utf-8")
        self.assertFalse(tracker.check(path)[0])

        # 3. manifest arrives half-written
        (path / "manifest.json").write_text('{"files": ["review.md", "in', encoding="utf-8")
        ready, reason = tracker.check(path)
        self.assertFalse(ready)
        self.assertIn("not parseable", reason)

        # 4. manifest completes, but names a PNG that has not synced yet
        (path / "manifest.json").write_text(
            json.dumps({"files": ["review.md", "manifest.json", "ink/page-01.png"]}), encoding="utf-8"
        )
        ready, reason = tracker.check(path)
        self.assertFalse(ready)
        self.assertIn("ink/page-01.png", reason)

        # 5. the PNG arrives — complete, but not yet settled
        (path / "ink").mkdir()
        (path / "ink" / "page-01.png").write_bytes(b"\x89PNG" + b"0" * 32)
        ready, reason = tracker.check(path)
        self.assertFalse(ready)
        self.assertIn("settle", reason)

        # 6. still inside the settle window
        clock.advance(4)
        self.assertFalse(tracker.check(path)[0])

        # 7. settle window elapsed and nothing changed
        clock.advance(2)
        ready, reason = tracker.check(path)
        self.assertTrue(ready, reason)

    def test_a_file_growing_during_the_settle_window_restarts_the_clock(self) -> None:
        config = make_config(self.root)
        clock = FakeClock()
        tracker = SettleTracker(settle_seconds=5.0, clock=clock)
        path = write_bundle(config, ink=["ink/page-01.png"])

        self.assertFalse(tracker.check(path)[0])  # first sighting
        clock.advance(4)
        # the PNG is still being downloaded and grows
        (path / "ink" / "page-01.png").write_bytes(b"\x89PNG" + b"0" * 4096)
        self.assertFalse(tracker.check(path)[0])
        clock.advance(4)
        self.assertFalse(tracker.check(path)[0], "settle window must have restarted")
        clock.advance(2)
        self.assertTrue(tracker.check(path)[0])

    def test_zero_settle_still_requires_two_looks(self) -> None:
        config = make_config(self.root)
        clock = FakeClock()
        tracker = SettleTracker(settle_seconds=0.0, clock=clock)
        path = write_bundle(config)
        self.assertFalse(tracker.check(path)[0])
        self.assertTrue(tracker.check(path)[0])


class ReturnPathTests(TempDirTestCase):
    def resolve(self, origin=None, **kwargs):
        config = make_config(self.root)
        path = write_bundle(config, **kwargs.pop("bundle_kwargs", {}))
        if origin is not None:
            write_meta(config, origin=origin)
        elif kwargs.get("write_meta_without_origin"):
            write_meta(config)
        item = load_bundle(path, config.sync_root)
        return bundle_mod.resolve_return_path(item, config.inbox)

    def test_poke(self) -> None:
        rp = self.resolve({"kind": "cowork", "sessionId": "8f3c", "returnPath": {"type": "poke", "triggerId": "trig_1"}})
        self.assertEqual(rp.type, "poke")
        self.assertEqual(rp.trigger_id, "trig_1")
        self.assertEqual(rp.kind, "cowork")

    def test_checkin(self) -> None:
        rp = self.resolve({"kind": "cowork", "returnPath": {"type": "checkin"}})
        self.assertEqual(rp.type, "checkin")

    def test_cloud(self) -> None:
        rp = self.resolve({"kind": "claude-code", "sessionId": "abc", "returnPath": {"type": "cloud"}})
        self.assertEqual(rp.type, "cloud")
        self.assertEqual(rp.session_id, "abc")

    def test_resume(self) -> None:
        rp = self.resolve({"kind": "claude-code", "returnPath": {"type": "resume", "sessionId": "sess-9"}})
        self.assertEqual(rp.session_id, "sess-9")

    def test_explicit_none(self) -> None:
        rp = self.resolve({"kind": "share", "returnPath": {"type": "none"}})
        self.assertEqual(rp.type, "none")

    def test_no_meta_at_all_resolves_to_none(self) -> None:
        rp = self.resolve(None)
        self.assertEqual(rp.type, "none")

    def test_meta_without_origin_resolves_to_none(self) -> None:
        rp = self.resolve(None, write_meta_without_origin=True)
        self.assertEqual(rp.type, "none")

    def test_manifest_origin_wins_over_meta(self) -> None:
        config = make_config(self.root)
        path = write_bundle(
            config,
            manifest={
                "files": ["review.md"],
                "origin": {"kind": "cowork", "returnPath": {"type": "poke", "triggerId": "from-manifest"}},
            },
        )
        write_meta(config, origin={"kind": "cowork", "returnPath": {"type": "checkin"}})
        rp = bundle_mod.resolve_return_path(load_bundle(path, config.sync_root), config.inbox)
        self.assertEqual(rp.trigger_id, "from-manifest")

    def test_falls_back_to_documentId_when_the_inbox_folder_was_renamed(self) -> None:
        config = make_config(self.root)
        path = write_bundle(config, "2026-08-18-auth-refactor-plan")
        write_meta(config, "2026-08-17-auth-refactor-plan-v1", origin={"kind": "codex", "returnPath": {"type": "resume", "sessionId": "cx-1"}})
        rp = bundle_mod.resolve_return_path(load_bundle(path, config.sync_root), config.inbox)
        self.assertEqual(rp.kind, "codex")
        self.assertEqual(rp.session_id, "cx-1")
        self.assertIn("documentId", rp.source)
