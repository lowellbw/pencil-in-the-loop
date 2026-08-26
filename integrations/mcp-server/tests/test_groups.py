"""Group names, and the report that lets a model reuse one.

The whole value of grouping is in the reuse: a model that invents "Machine
Learning Papers" beside an existing "ML Papers" splits one subject across two
sections the user has to merge by hand. So the tests here are mostly about when
two names are the same name, and about the report being good enough to judge a
subject from.

Standard library only, like every other suite here.
"""

from __future__ import annotations

import json
import unittest
from pathlib import Path
from tempfile import TemporaryDirectory

from pencil_in_the_loop_mcp import core


class GroupNameTests(unittest.TestCase):
    def test_whitespace_is_tidied(self) -> None:
        self.assertEqual(core.validate_group("  Attention   Papers\n"), "Attention Papers")

    def test_absent_or_blank_is_no_group_rather_than_an_error(self) -> None:
        for value in (None, "", "   "):
            self.assertIsNone(core.validate_group(value), repr(value))

    def test_a_non_string_is_refused(self) -> None:
        with self.assertRaises(core.ValidationError):
            core.validate_group(["Attention Papers"])

    def test_a_control_character_is_refused(self) -> None:
        with self.assertRaises(core.ValidationError):
            core.validate_group("Attention\x00Papers")

    def test_an_over_long_name_is_refused(self) -> None:
        with self.assertRaises(core.ValidationError):
            core.validate_group("a" * (core.MAX_GROUP_CHARS + 1))

    def test_a_name_with_nothing_to_match_on_is_refused(self) -> None:
        # It would never match itself, so every send would mint a fresh group.
        for value in ("!!!", "---", "🙂"):
            with self.assertRaises(core.ValidationError, msg=value):
                core.validate_group(value)


class GroupKeyTests(unittest.TestCase):
    def test_case_accents_and_punctuation_are_one_group(self) -> None:
        keys = {
            core.group_key(name)
            for name in ("Attention Papers", "attention papers", "Attention-Papers", "Áttention Papers")
        }
        self.assertEqual(len(keys), 1)

    def test_two_subjects_stay_two_groups(self) -> None:
        self.assertNotEqual(core.group_key("ML Papers"), core.group_key("Machine Learning Papers"))

    def test_a_non_latin_name_keeps_its_own_key(self) -> None:
        # The regression guard against reusing `slugify`, which strips to ASCII
        # and falls back to "untitled" — merging every such name into one group.
        keys = {core.group_key(name) for name in ("注意機構の論文", "Θεωρία παιγνίων", "日本語のみ")}
        self.assertEqual(len(keys), 3)
        self.assertNotIn("", keys)


class SummariseGroupsTests(unittest.TestCase):
    def rows(self):
        return [
            {"group": "Attention Papers", "title": "Attention Is All You Need", "createdAt": "2026-08-01T00:00:00Z"},
            {"group": "attention papers", "title": "FlashAttention-3", "createdAt": "2026-08-20T00:00:00Z"},
            {"group": "Q3 Planning", "title": "Roadmap draft", "createdAt": "2026-08-25T00:00:00Z"},
            {"group": None, "title": "Auth refactor plan", "createdAt": "2026-08-10T00:00:00Z"},
            {"group": "   ", "title": "Stray", "createdAt": "2026-08-11T00:00:00Z"},
        ]

    def test_variant_spellings_fold_into_one_group(self) -> None:
        groups, _ = core.summarise_groups(self.rows())
        names = [group["name"] for group in groups]
        self.assertEqual(sorted(names), ["Attention Papers", "Q3 Planning"])

    def test_the_display_name_is_the_oldest_spelling(self) -> None:
        groups, _ = core.summarise_groups(self.rows())
        attention = next(g for g in groups if g["documentCount"] == 2)
        self.assertEqual(
            attention["name"],
            "Attention Papers",
            "A group should not flip spelling because of one careless send.",
        )

    def test_groups_are_newest_used_first(self) -> None:
        groups, _ = core.summarise_groups(self.rows())
        self.assertEqual([g["name"] for g in groups], ["Q3 Planning", "Attention Papers"])

    def test_recent_titles_are_newest_first_and_capped(self) -> None:
        groups, _ = core.summarise_groups(self.rows(), recent_titles=1)
        attention = next(g for g in groups if g["documentCount"] == 2)
        self.assertEqual(attention["recentTitles"], ["FlashAttention-3"])

    def test_a_blank_group_counts_as_ungrouped(self) -> None:
        _, ungrouped = core.summarise_groups(self.rows())
        self.assertEqual(ungrouped, 2)

    def test_nothing_at_all_is_an_empty_list_not_an_error(self) -> None:
        self.assertEqual(core.summarise_groups([]), ([], 0))


class ScanInboxGroupsTests(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.root = Path(self._tmp.name) / "sync"

    def bundle(self, name: str, meta: object) -> Path:
        directory = self.root / "inbox" / name
        directory.mkdir(parents=True)
        if isinstance(meta, str):
            (directory / "meta.json").write_text(meta)
        else:
            (directory / "meta.json").write_text(json.dumps(meta))
        return directory

    def test_a_missing_inbox_is_empty_rather_than_an_error(self) -> None:
        self.assertEqual(core.scan_inbox_groups(self.root), ([], 0, False))

    def test_groups_are_read_from_every_bundle(self) -> None:
        self.bundle("2026-08-01-a", {"title": "A", "group": "Attention Papers", "createdAt": "2026-08-01T00:00:00Z"})
        self.bundle("2026-08-02-b", {"title": "B", "group": "Attention Papers", "createdAt": "2026-08-02T00:00:00Z"})
        self.bundle("2026-08-03-c", {"title": "C", "createdAt": "2026-08-03T00:00:00Z"})

        groups, ungrouped, truncated = core.scan_inbox_groups(self.root)

        self.assertEqual([g["name"] for g in groups], ["Attention Papers"])
        self.assertEqual(groups[0]["documentCount"], 2)
        self.assertEqual(ungrouped, 1)
        self.assertFalse(truncated)

    def test_an_unreadable_meta_is_skipped_rather_than_fatal(self) -> None:
        self.bundle("2026-08-01-a", {"title": "A", "group": "Attention Papers", "createdAt": "2026-08-01T00:00:00Z"})
        self.bundle("2026-08-02-broken", "{ not json")

        groups, _, _ = core.scan_inbox_groups(self.root)

        self.assertEqual([g["name"] for g in groups], ["Attention Papers"])

    def test_hidden_staging_directories_are_ignored(self) -> None:
        self.bundle(".2026-08-02-tmp", {"title": "Half", "group": "Ghost", "createdAt": "2026-08-02T00:00:00Z"})

        groups, _, _ = core.scan_inbox_groups(self.root)

        self.assertEqual(groups, [])

    def test_reading_the_groups_changes_nothing_on_disk(self) -> None:
        directory = self.bundle(
            "2026-08-01-a", {"title": "A", "group": "Attention Papers", "createdAt": "2026-08-01T00:00:00Z"}
        )
        before = (directory / "meta.json").read_text()

        core.scan_inbox_groups(self.root)

        self.assertEqual((directory / "meta.json").read_text(), before)
        self.assertEqual(sorted(p.name for p in (self.root / "inbox").iterdir()), ["2026-08-01-a"])


class WriteWithGroupTests(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.root = Path(self._tmp.name) / "sync"

    def write(self, **kwargs):
        kwargs.setdefault("content", "# Auth refactor plan\n\nA short paragraph.\n")
        return core.write_inbox_bundle(self.root, **kwargs)

    def test_a_group_lands_in_meta_json(self) -> None:
        result = self.write(group="  Attention   Papers ")
        meta = json.loads((Path(result["path"]) / "meta.json").read_text())

        self.assertEqual(meta["group"], "Attention Papers")
        self.assertEqual(result["group"], "Attention Papers")

    def test_no_group_writes_no_key_at_all(self) -> None:
        result = self.write()
        meta = json.loads((Path(result["path"]) / "meta.json").read_text())

        self.assertNotIn(
            "group",
            meta,
            "An explicit null would make every reader special-case it.",
        )
        self.assertIsNone(result["group"])

    def test_a_bad_group_is_refused_and_writes_nothing(self) -> None:
        with self.assertRaises(core.ValidationError):
            self.write(group="a" * 200)

        self.assertFalse((self.root / "inbox").exists())


if __name__ == "__main__":
    unittest.main()
