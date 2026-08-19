"""Tests for the file-contract layer. Standard library only."""

from __future__ import annotations

import json
import os
import unittest
from datetime import date, datetime, timezone
from pathlib import Path
from tempfile import TemporaryDirectory

from pencil_in_the_loop_mcp import core
from pencil_in_the_loop_mcp.config import ORIGIN_KINDS, RETURN_PATH_TYPES

FIXED = datetime(2026, 8, 18, 18, 22, 4, tzinfo=timezone.utc)


class IsolatedEnv(unittest.TestCase):
    """Every test runs with a clean environment and a private sync root."""

    def setUp(self) -> None:
        self._tmp = TemporaryDirectory()
        self.root = Path(self._tmp.name) / "sync"
        self.addCleanup(self._tmp.cleanup)

        self._saved = dict(os.environ)
        for key in list(os.environ):
            if key.startswith(("CLAUDE_", "CODEX_", "PENCIL_")):
                del os.environ[key]
        os.environ["PENCIL_CONFIG_DIR"] = str(Path(self._tmp.name) / "config")
        self.addCleanup(self._restore_env)

    def _restore_env(self) -> None:
        os.environ.clear()
        os.environ.update(self._saved)

    def visible_inbox(self) -> list[str]:
        inbox = self.root / "inbox"
        if not inbox.is_dir():
            return []
        return sorted(p.name for p in inbox.iterdir() if not p.name.startswith("."))

    def all_inbox(self) -> list[str]:
        inbox = self.root / "inbox"
        if not inbox.is_dir():
            return []
        return sorted(p.name for p in inbox.iterdir())


class SlugTests(unittest.TestCase):
    def test_lowercase_hyphenated_ascii(self) -> None:
        self.assertEqual(core.slugify("Auth refactor plan"), "auth-refactor-plan")
        self.assertEqual(core.slugify("  Q3   Platform  Planning "), "q3-platform-planning")

    def test_punctuation_collapses_to_single_hyphens(self) -> None:
        self.assertEqual(core.slugify("Auth: refactor -- plan!!"), "auth-refactor-plan")
        self.assertEqual(core.slugify("--leading and trailing--"), "leading-and-trailing")

    def test_accents_fold_to_ascii(self) -> None:
        self.assertEqual(core.slugify("Café Naïve Résumé"), "cafe-naive-resume")

    def test_non_latin_or_empty_becomes_untitled(self) -> None:
        for value in ("", "   ", "!!!", "日本語のみ", "🙂🙂"):
            self.assertEqual(core.slugify(value), "untitled", value)

    def test_long_titles_truncate_on_a_word_boundary(self) -> None:
        slug = core.slugify("alpha bravo charlie delta echo foxtrot golf hotel india juliet")
        self.assertLessEqual(len(slug), core.MAX_SLUG_CHARS)
        self.assertFalse(slug.endswith("-"))
        self.assertTrue(slug.startswith("alpha-bravo-charlie"))
        # never leaves a half word behind
        self.assertTrue(all(part for part in slug.split("-")))

    def test_bundle_name_carries_the_date_prefix(self) -> None:
        self.assertEqual(
            core.bundle_name("Auth refactor plan", date(2026, 8, 18)),
            "2026-08-18-auth-refactor-plan",
        )

    def test_candidate_names_are_base_then_2_then_3(self) -> None:
        gen = core.candidate_names("2026-08-18-plan")
        self.assertEqual(
            [next(gen) for _ in range(3)],
            ["2026-08-18-plan", "2026-08-18-plan-2", "2026-08-18-plan-3"],
        )


class ValidationTests(IsolatedEnv):
    def test_rejects_bad_content_without_creating_anything(self) -> None:
        bad = [None, 42, "", "   \n\t ", "has a \x00 null byte", "x" * 1 + "\udcff"]
        for value in bad:
            with self.assertRaises(core.ValidationError, msg=repr(value)):
                core.write_inbox_bundle(self.root, content=value)
        self.assertEqual(self.all_inbox(), [])

    def test_rejects_oversized_content(self) -> None:
        with self.assertRaises(core.ValidationError):
            core.write_inbox_bundle(
                self.root, content="a" * (core.MAX_CONTENT_BYTES + 1)
            )
        self.assertEqual(self.all_inbox(), [])

    def test_rejects_bad_tags(self) -> None:
        for tags in ("a-string", [1, 2], ["ok", None], ["x" * 200], list("abcdefghij") * 5):
            with self.assertRaises(core.ValidationError, msg=repr(tags)):
                core.write_inbox_bundle(self.root, content="# T\n\nbody", tags=tags)
        self.assertEqual(self.all_inbox(), [])

    def test_rejects_unknown_origin_kind(self) -> None:
        with self.assertRaises(ValueError):
            core.write_inbox_bundle(
                self.root, content="# T\n\nbody", origin_kind="pigeon"
            )
        self.assertEqual(self.all_inbox(), [])

    def test_title_falls_back_to_first_heading_then_first_line(self) -> None:
        self.assertEqual(core.derive_title("# Auth refactor\n\nbody"), "Auth refactor")
        self.assertEqual(core.derive_title("just a line\n\nmore"), "just a line")
        self.assertEqual(core.derive_title("\n\n"), "Untitled")

    def test_bundle_id_validation_blocks_traversal(self) -> None:
        for bad in ("../../etc/passwd", "/etc/passwd", "a/b", "", ".", "..", None, 3):
            with self.assertRaises(core.ValidationError, msg=repr(bad)):
                core.validate_bundle_id(bad)
        self.assertEqual(
            core.validate_bundle_id("2026-08-18-plan.review"), "2026-08-18-plan"
        )
        self.assertEqual(core.validate_bundle_id("2026-08-18-plan"), "2026-08-18-plan")


class WriteTests(IsolatedEnv):
    def write(self, **kwargs):
        kwargs.setdefault("content", "# Auth refactor plan\n\nA short paragraph.\n")
        kwargs.setdefault("now", FIXED)
        return core.write_inbox_bundle(self.root, **kwargs)

    def test_writes_source_and_meta(self) -> None:
        result = self.write()
        bundle = Path(result["path"])
        self.assertEqual(bundle.name, "2026-08-18-auth-refactor-plan")
        self.assertTrue((bundle / "source.md").is_file())
        self.assertTrue((bundle / "meta.json").is_file())
        self.assertIn("A short paragraph.", (bundle / "source.md").read_text())

    def test_adds_an_h1_only_when_missing(self) -> None:
        kept = Path(self.write()["path"]) / "source.md"
        self.assertTrue(kept.read_text().startswith("# Auth refactor plan"))
        added = Path(
            self.write(content="no heading here", title="Made up")["path"]
        ) / "source.md"
        self.assertTrue(added.read_text().startswith("# Made up\n\nno heading here"))

    def test_collisions_get_2_then_3(self) -> None:
        names = [self.write()["id"] for _ in range(3)]
        self.assertEqual(
            names,
            [
                "2026-08-18-auth-refactor-plan",
                "2026-08-18-auth-refactor-plan-2",
                "2026-08-18-auth-refactor-plan-3",
            ],
        )
        self.assertEqual(self.visible_inbox(), sorted(names))

    def test_meta_json_matches_the_docs_05_shape(self) -> None:
        os.environ["CLAUDE_SESSION_ID"] = "8f3c1d2b4a5e6f70"
        meta = json.loads(
            (Path(self.write(tags=["spec", "auth"])["path"]) / "meta.json").read_text()
        )
        self.assertEqual(
            set(meta) - {"tags", "pageCount"},
            {"id", "title", "createdAt", "origin", "sourceFormat"},
        )
        self.assertIsInstance(meta["id"], str)
        self.assertEqual(meta["title"], "Auth refactor plan")
        self.assertEqual(meta["createdAt"], "2026-08-18T18:22:04Z")
        self.assertEqual(meta["sourceFormat"], "markdown")
        self.assertEqual(meta["tags"], ["spec", "auth"])

        origin = meta["origin"]
        self.assertEqual(origin["kind"], "claude-code")
        self.assertIn(origin["kind"], ORIGIN_KINDS)
        self.assertEqual(origin["sessionId"], "8f3c1d2b4a5e6f70")
        self.assertIn(origin["returnPath"]["type"], RETURN_PATH_TYPES)
        self.assertEqual(origin["returnPath"]["type"], "cloud")
        self.assertIs(origin["returnPath"]["verified"], False)
        self.assertEqual(
            [c["type"] for c in origin["returnPath"]["candidates"]],
            ["cloud", "resume"],
        )

    def test_cloud_session_id_is_recorded_separately(self) -> None:
        """`claude --cloud` addresses the web session, not the local UUID."""
        os.environ["CLAUDE_CODE_SESSION_ID"] = "5a4c794c-9daa-564e-97a9-98040246"
        os.environ["CLAUDE_CODE_REMOTE_SESSION_ID"] = "cse_0134GYfPm1zZP9SXNzon"
        meta = json.loads((Path(self.write()["path"]) / "meta.json").read_text())
        path = meta["origin"]["returnPath"]
        self.assertEqual(meta["origin"]["sessionId"], "5a4c794c-9daa-564e-97a9-98040246")
        self.assertEqual(path["cloudSessionId"], "cse_0134GYfPm1zZP9SXNzon")
        cloud, resume = path["candidates"]
        self.assertEqual(cloud["sessionId"], "cse_0134GYfPm1zZP9SXNzon")
        self.assertEqual(resume["sessionId"], "5a4c794c-9daa-564e-97a9-98040246")

    def test_no_session_id_means_return_path_none(self) -> None:
        meta = json.loads((Path(self.write()["path"]) / "meta.json").read_text())
        self.assertNotIn("sessionId", meta["origin"])
        self.assertEqual(meta["origin"]["returnPath"]["type"], "none")

    def test_codex_origin_kind_uses_codex_resume(self) -> None:
        meta = json.loads(
            (
                Path(
                    self.write(origin_kind="codex", session_id="abc123def456")["path"]
                )
                / "meta.json"
            ).read_text()
        )
        self.assertEqual(meta["origin"]["kind"], "codex")
        self.assertEqual(
            meta["origin"]["returnPath"]["candidates"][0]["command"],
            ["codex", "resume", "abc123def456"],
        )

    def test_explicit_session_id_beats_the_environment(self) -> None:
        os.environ["CLAUDE_SESSION_ID"] = "from-the-environment"
        meta = json.loads(
            (Path(self.write(session_id="from-the-argument")["path"]) / "meta.json")
            .read_text()
        )
        self.assertEqual(meta["origin"]["sessionId"], "from-the-argument")
        self.assertEqual(
            meta["origin"]["returnPath"]["sessionIdSource"], "tool-argument"
        )

    def test_session_file_is_read_when_the_environment_is_empty(self) -> None:
        config = Path(os.environ["PENCIL_CONFIG_DIR"])
        config.mkdir(parents=True)
        (config / "session.json").write_text(
            json.dumps({"session_id": "hook-supplied-id", "cwd": "/Users/x/proj"})
        )
        meta = json.loads((Path(self.write()["path"]) / "meta.json").read_text())
        self.assertEqual(meta["origin"]["sessionId"], "hook-supplied-id")
        self.assertEqual(
            meta["origin"]["returnPath"]["sessionIdSource"], "session-file"
        )
        self.assertEqual(meta["origin"]["returnPath"]["cwd"], "/Users/x/proj")


class AtomicityTests(IsolatedEnv):
    def test_the_final_directory_never_appears_partially_built(self) -> None:
        """A watcher polling the inbox must never see an incomplete bundle."""
        seen: list[list[str]] = []
        real_write = core._write_file

        def spy(path: Path, text: str) -> None:
            real_write(path, text)
            inbox = self.root / "inbox"
            seen.append(
                sorted(p.name for p in inbox.iterdir() if not p.name.startswith("."))
            )

        core._write_file = spy
        try:
            result = core.write_inbox_bundle(
                self.root, content="# Plan\n\nbody", now=FIXED
            )
        finally:
            core._write_file = real_write

        self.assertEqual(len(seen), 2)
        for snapshot in seen:
            self.assertEqual(snapshot, [], "a partial bundle was visible in inbox/")
        self.assertEqual(self.visible_inbox(), [result["id"]])

    def test_a_failure_mid_write_leaves_no_trace(self) -> None:
        real_write = core._write_file
        calls = {"n": 0}

        def flaky(path: Path, text: str) -> None:
            calls["n"] += 1
            if calls["n"] == 2:
                raise OSError("disk went away")
            real_write(path, text)

        core._write_file = flaky
        try:
            with self.assertRaises(OSError):
                core.write_inbox_bundle(self.root, content="# Plan\n\nbody", now=FIXED)
        finally:
            core._write_file = real_write

        self.assertEqual(self.all_inbox(), [], "a temp directory was left behind")

    def test_temp_directory_is_a_hidden_sibling_inside_inbox(self) -> None:
        captured: list[Path] = []
        real_write = core._write_file

        def spy(path: Path, text: str) -> None:
            captured.append(path)
            real_write(path, text)

        core._write_file = spy
        try:
            core.write_inbox_bundle(self.root, content="# Plan\n\nbody", now=FIXED)
        finally:
            core._write_file = real_write

        tmp_dir = captured[0].parent
        self.assertEqual(tmp_dir.parent, self.root / "inbox")
        self.assertTrue(tmp_dir.name.startswith("."))
        self.assertTrue(tmp_dir.name.endswith(".tmp"))


class MetaSchemaTests(IsolatedEnv):
    """Validate meta.json against contracts/schema/meta.schema.json if present."""

    def test_against_the_shared_schema_when_it_exists(self) -> None:
        repo_root = Path(__file__).resolve().parents[3]
        schema_path = repo_root / "contracts" / "schema" / "meta.schema.json"
        if not schema_path.is_file():
            self.skipTest(
                "contracts/schema/meta.schema.json not present; meta.json is "
                "checked against the docs/05 example in WriteTests instead"
            )
        try:
            import jsonschema  # type: ignore
        except ImportError:
            self.skipTest("jsonschema not installed")
        meta = json.loads(
            (
                Path(
                    core.write_inbox_bundle(
                        self.root,
                        content="# Auth refactor plan\n\nbody",
                        session_id="8f3c1d2b4a5e",
                        now=FIXED,
                    )["path"]
                )
                / "meta.json"
            ).read_text()
        )
        jsonschema.validate(meta, json.loads(schema_path.read_text()))


if __name__ == "__main__":
    unittest.main()
