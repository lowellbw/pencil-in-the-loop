#!/usr/bin/env python3
"""Tests for send_to_reader.py. Standard library only.

    python3 scripts/test_send_to_reader.py -v
"""

from __future__ import annotations

import contextlib
import io
import json
import os
import re
import shutil
import sys
import tempfile
import unittest
from datetime import datetime
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent))

import send_to_reader as str_mod  # noqa: E402

REPO_ROOT = Path(__file__).resolve().parents[3]
SCHEMA_PATH = REPO_ROOT / "contracts" / "schema" / "meta.schema.json"


def visible_entries(folder: Path) -> list[str]:
    """Everything a watcher would notice — dotfiles are staging, and ignored."""
    return sorted(p.name for p in folder.iterdir() if not p.name.startswith("."))


class ReaderFolderCase(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = Path(tempfile.mkdtemp(prefix="pencil-loop-test-"))
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.folder = self.tmp / "reader"
        (self.folder / "inbox").mkdir(parents=True)
        (self.folder / "outbox").mkdir(parents=True)
        self.inbox = self.folder / "inbox"
        self.config = self.tmp / "config.json"
        self.config.write_text(json.dumps({"syncRoot": str(self.folder), "version": 1}))

    def send(self, **kwargs):
        params = dict(
            title="Auth refactor plan",
            markdown="# Auth refactor plan\n\nOne idea per paragraph.\n",
            config_path=self.config,
            session_id="8f3c1d",
            thread_title="Q3 platform planning",
            return_path="checkin",
        )
        params.update(kwargs)
        return str_mod.send(**params)


class TestSlugify(unittest.TestCase):
    def test_basic(self):
        self.assertEqual(str_mod.slugify("Auth refactor plan"), "auth-refactor-plan")

    def test_lowercases_and_strips_punctuation(self):
        self.assertEqual(str_mod.slugify("  --Hello, World!!  "), "hello-world")

    def test_transliterates_to_ascii(self):
        self.assertEqual(str_mod.slugify("Café Über Naïve"), "cafe-uber-naive")

    def test_collapses_runs_of_separators(self):
        self.assertEqual(str_mod.slugify("a   /  b __ c"), "a-b-c")

    def test_keeps_digits(self):
        self.assertEqual(str_mod.slugify("Q3 2026 plan"), "q3-2026-plan")

    def test_empty_and_unsluggable_fall_back(self):
        for value in ("", "   ", "!!!", "日本語", None):
            self.assertEqual(str_mod.slugify(value), "document")

    def test_truncates_at_a_word_boundary_without_trailing_hyphen(self):
        title = "a plan for the migration of the authentication subsystem to the new service"
        slug = str_mod.slugify(title)
        self.assertLessEqual(len(slug), str_mod.MAX_SLUG_LENGTH)
        self.assertFalse(slug.startswith("-"))
        self.assertFalse(slug.endswith("-"))
        self.assertTrue(title.lower().startswith(slug.split("-")[0]))
        self.assertIn(slug, str_mod.slugify(title, max_length=200))

    def test_is_always_lowercase_ascii_hyphenated(self):
        for value in ("Ünïcødé Title", "MIXED Case 42", "trailing---"):
            self.assertRegex(str_mod.slugify(value), r"^[a-z0-9]+(-[a-z0-9]+)*$")


class TestAllocateBundleName(ReaderFolderCase):
    def test_first_name_has_no_suffix(self):
        name = str_mod.allocate_bundle_name(self.inbox, "2026-08-18", "auth-refactor-plan")
        self.assertEqual(name, "2026-08-18-auth-refactor-plan")

    def test_collisions_get_numeric_suffixes(self):
        (self.inbox / "2026-08-18-plan").mkdir()
        self.assertEqual(
            str_mod.allocate_bundle_name(self.inbox, "2026-08-18", "plan"),
            "2026-08-18-plan-2",
        )
        (self.inbox / "2026-08-18-plan-2").mkdir()
        self.assertEqual(
            str_mod.allocate_bundle_name(self.inbox, "2026-08-18", "plan"),
            "2026-08-18-plan-3",
        )

    def test_same_slug_on_a_different_day_does_not_collide(self):
        (self.inbox / "2026-08-18-plan").mkdir()
        self.assertEqual(
            str_mod.allocate_bundle_name(self.inbox, "2026-08-19", "plan"),
            "2026-08-19-plan",
        )

    def test_send_twice_produces_two_bundles(self):
        first = self.send(date="2026-08-18")
        second = self.send(date="2026-08-18")
        third = self.send(date="2026-08-18")
        self.assertEqual(first["bundle"], "2026-08-18-auth-refactor-plan")
        self.assertEqual(second["bundle"], "2026-08-18-auth-refactor-plan-2")
        self.assertEqual(third["bundle"], "2026-08-18-auth-refactor-plan-3")
        self.assertEqual(len(visible_entries(self.inbox)), 3)


class TestFolderValidation(ReaderFolderCase):
    def test_valid_folder_reports_no_problems(self):
        self.assertEqual(str_mod.validate_reader_folder(self.folder), [])

    def test_missing_folder(self):
        problems = str_mod.validate_reader_folder(self.tmp / "nope")
        self.assertEqual(len(problems), 1)
        self.assertIn("does not exist", problems[0])

    def test_missing_inbox_and_outbox_are_both_reported(self):
        bare = self.tmp / "bare"
        bare.mkdir()
        problems = str_mod.validate_reader_folder(bare)
        self.assertEqual(len(problems), 2)
        self.assertTrue(any("inbox" in p for p in problems))
        self.assertTrue(any("outbox" in p for p in problems))

    def test_send_refuses_a_folder_without_inbox_outbox(self):
        bare = self.tmp / "bare"
        bare.mkdir()
        with self.assertRaises(str_mod.ReaderFolderError) as ctx:
            self.send(folder=bare)
        self.assertIn("inbox", str(ctx.exception))

    def test_unconfigured_folder_raises_with_instructions(self):
        empty_config = self.tmp / "empty.json"
        empty_config.write_text("{}")
        with mock.patch.dict(os.environ, {}, clear=False):
            os.environ.pop("PENCIL_LOOP_READER_FOLDER", None)
            with self.assertRaises(str_mod.ReaderFolderError) as ctx:
                str_mod.resolve_reader_folder(None, empty_config)
        self.assertIn("--set-folder", str(ctx.exception))

    def test_explicit_folder_beats_config(self):
        other = self.tmp / "other"
        self.assertEqual(
            str_mod.resolve_reader_folder(other, self.config), other
        )

    def test_env_var_beats_config(self):
        for key in str_mod.ENV_KEYS:
            with mock.patch.dict(os.environ, {key: str(self.tmp / "fromenv")}, clear=False):
                for other in str_mod.ENV_KEYS:
                    if other != key:
                        os.environ.pop(other, None)
                self.assertEqual(
                    str_mod.resolve_reader_folder(None, self.config), self.tmp / "fromenv"
                )

    def test_legacy_config_keys_are_accepted(self):
        for key in str_mod.SYNC_ROOT_KEYS:
            config = self.tmp / f"{key}.json"
            config.write_text(json.dumps({key: str(self.folder)}))
            with mock.patch.dict(os.environ, {}, clear=False):
                for env_key in str_mod.ENV_KEYS:
                    os.environ.pop(env_key, None)
                self.assertEqual(
                    str_mod.resolve_reader_folder(None, config), self.folder, key
                )


class TestAtomicity(ReaderFolderCase):
    def test_nothing_visible_in_inbox_until_the_rename(self):
        seen: list[list[str]] = []
        real_rename = os.rename

        def spy(src, dst):
            seen.append(visible_entries(self.inbox))
            return real_rename(src, dst)

        with mock.patch.object(str_mod.os, "rename", side_effect=spy):
            result = self.send(date="2026-08-18")

        self.assertEqual(seen, [[]], "inbox held a visible entry before the rename")
        self.assertEqual(visible_entries(self.inbox), [result["bundle"]])

    def test_staging_directory_is_hidden_and_a_sibling_of_the_bundle(self):
        staged: list[Path] = []
        real_mkdir = Path.mkdir

        def spy(self_path, *args, **kwargs):
            staged.append(Path(self_path))
            return real_mkdir(self_path, *args, **kwargs)

        with mock.patch.object(Path, "mkdir", autospec=True, side_effect=spy):
            self.send(date="2026-08-18")

        staging = [p for p in staged if p.name.startswith(".") and p.name.endswith(".tmp")]
        self.assertTrue(staging, "no dot-prefixed staging directory was created")
        self.assertEqual(staging[0].parent, self.inbox)

    def test_a_failure_mid_write_leaves_no_trace(self):
        with self.assertRaises(TypeError):
            str_mod._write_bundle_atomically(
                self.inbox,
                "2026-08-18-broken",
                {"source.md": b"fine", "meta.json": "not bytes"},
            )
        self.assertEqual(visible_entries(self.inbox), [])
        self.assertEqual(list(self.inbox.iterdir()), [], "staging directory was left behind")

    def test_bundle_is_complete_the_moment_it_appears(self):
        result = self.send(date="2026-08-18")
        bundle = Path(result["path"])
        self.assertEqual(
            sorted(p.name for p in bundle.iterdir()), ["meta.json", "source.md"]
        )
        self.assertTrue(bundle.joinpath("source.md").read_text().endswith("\n"))

    def test_dry_run_writes_nothing(self):
        result = self.send(dry_run=True, date="2026-08-18")
        self.assertTrue(result["dryRun"])
        self.assertEqual(result["bundle"], "2026-08-18-auth-refactor-plan")
        self.assertEqual(list(self.inbox.iterdir()), [])


class TestPdfSource(ReaderFolderCase):
    def test_a_pdf_source_is_written_as_document_pdf(self):
        pdf = self.tmp / "paper.pdf"
        pdf.write_bytes(b"%PDF-1.7\n/Type /Page \n/Type /Page \n%%EOF\n")
        result = self.send(markdown=None, pdf_path=pdf, title="A paper", date="2026-08-18")
        bundle = Path(result["path"])
        self.assertEqual(
            sorted(p.name for p in bundle.iterdir()), ["document.pdf", "meta.json"]
        )
        meta = json.loads((bundle / "meta.json").read_text())
        self.assertEqual(meta["sourceFormat"], "pdf")

    def test_markdown_and_pdf_are_mutually_exclusive(self):
        with self.assertRaises(ValueError):
            self.send(markdown=None, pdf_path=None)


class TestMetaContract(ReaderFolderCase):
    """meta.json must match docs/05-file-contracts.md."""

    def meta_from_send(self, **kwargs) -> dict:
        result = self.send(**kwargs)
        return json.loads((Path(result["path"]) / "meta.json").read_text())

    def test_required_fields_and_types(self):
        meta = self.meta_from_send(date="2026-08-18")
        self.assertIsInstance(meta["id"], str)
        self.assertTrue(meta["id"])
        self.assertEqual(meta["title"], "Auth refactor plan")
        self.assertEqual(meta["sourceFormat"], "markdown")
        self.assertIsInstance(meta["origin"], dict)

    def test_created_at_is_utc_iso8601_with_a_z(self):
        meta = self.meta_from_send(date="2026-08-18")
        self.assertRegex(meta["createdAt"], r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$")
        parsed = datetime.strptime(meta["createdAt"], "%Y-%m-%dT%H:%M:%SZ")
        self.assertIsInstance(parsed, datetime)

    def test_origin_records_cowork_session_thread_and_return_path(self):
        meta = self.meta_from_send(date="2026-08-18")
        origin = meta["origin"]
        self.assertEqual(origin["kind"], "cowork")
        self.assertEqual(origin["sessionId"], "8f3c1d")
        self.assertEqual(origin["threadTitle"], "Q3 platform planning")
        self.assertEqual(origin["returnPath"], {"type": "checkin"})

    def test_poke_return_path_carries_the_trigger_id(self):
        meta = self.meta_from_send(
            date="2026-08-18", return_path="poke", trigger_id="trig_abc123"
        )
        self.assertEqual(
            meta["origin"]["returnPath"], {"type": "poke", "triggerId": "trig_abc123"}
        )

    def test_enums_are_enforced(self):
        with self.assertRaises(ValueError):
            str_mod.build_meta(title="x", source_format="markdown", origin_kind="slack")
        with self.assertRaises(ValueError):
            str_mod.build_meta(
                title="x", source_format="markdown", return_path="carrier-pigeon"
            )
        with self.assertRaises(ValueError):
            str_mod.build_meta(title="x", source_format="rtf")

    def test_all_documented_enum_values_are_accepted(self):
        for kind in str_mod.ORIGIN_KINDS:
            for path_type in str_mod.RETURN_PATH_TYPES:
                meta = str_mod.build_meta(
                    title="x",
                    source_format="markdown",
                    origin_kind=kind,
                    return_path=path_type,
                )
                self.assertEqual(meta["origin"]["kind"], kind)
                self.assertEqual(meta["origin"]["returnPath"]["type"], path_type)

    def test_origin_is_optional_below_kind(self):
        meta = str_mod.build_meta(title="x", source_format="markdown", return_path=None)
        self.assertEqual(meta["origin"], {"kind": "cowork"})
        self.assertNotIn("sessionId", meta["origin"])

    def test_meta_is_json_serialisable_and_key_ordered_like_the_contract(self):
        meta = self.meta_from_send(date="2026-08-18")
        self.assertEqual(
            list(meta),
            ["id", "title", "createdAt", "origin", "sourceFormat"],
        )

    def test_bundle_name_matches_the_documented_pattern(self):
        result = self.send(date="2026-08-18")
        self.assertRegex(result["bundle"], r"^\d{4}-\d{2}-\d{2}-[a-z0-9]+(-[a-z0-9]+)*$")


# --------------------------------------------------------------------------
# Optional: validate against contracts/schema/meta.schema.json when it exists.
# A very small subset of JSON Schema — enough for this contract, no dependency.
# --------------------------------------------------------------------------


def validate_against_schema(instance, schema, path="meta") -> list[str]:
    errors: list[str] = []
    types = {
        "object": dict,
        "array": list,
        "string": str,
        "integer": int,
        "number": (int, float),
        "boolean": bool,
        "null": type(None),
    }

    expected = schema.get("type")
    if expected:
        expected_list = expected if isinstance(expected, list) else [expected]
        if not any(isinstance(instance, types[t]) for t in expected_list if t in types):
            errors.append(f"{path}: expected type {expected}, got {type(instance).__name__}")
            return errors

    if "enum" in schema and instance not in schema["enum"]:
        errors.append(f"{path}: {instance!r} not in {schema['enum']}")

    if "pattern" in schema and isinstance(instance, str):
        if not re.search(schema["pattern"], instance):
            errors.append(f"{path}: {instance!r} does not match {schema['pattern']}")

    if isinstance(instance, dict):
        for key in schema.get("required", []):
            if key not in instance:
                errors.append(f"{path}: missing required property {key!r}")
        properties = schema.get("properties", {})
        for key, value in instance.items():
            if key in properties:
                errors.extend(validate_against_schema(value, properties[key], f"{path}.{key}"))
            elif schema.get("additionalProperties") is False:
                errors.append(f"{path}: unexpected property {key!r}")

    if isinstance(instance, list) and "items" in schema:
        for index, value in enumerate(instance):
            errors.extend(validate_against_schema(value, schema["items"], f"{path}[{index}]"))

    return errors


class TestAgainstPublishedSchema(ReaderFolderCase):
    @unittest.skipUnless(
        SCHEMA_PATH.exists(), f"{SCHEMA_PATH} not present; validated against docs/05 example"
    )
    def test_meta_validates_against_the_schema(self):
        schema = json.loads(SCHEMA_PATH.read_text())
        for kwargs in (
            {"date": "2026-08-18"},
            {"date": "2026-08-18", "return_path": "poke", "trigger_id": "trig_abc"},
            {"date": "2026-08-18", "return_path": None, "session_id": None,
             "thread_title": None},
        ):
            result = self.send(**kwargs)
            meta = json.loads((Path(result["path"]) / "meta.json").read_text())
            errors = validate_against_schema(meta, schema)
            self.assertEqual(errors, [], f"{kwargs} produced {errors}")


class TestSchemaValidatorItself(unittest.TestCase):
    """The mini-validator is only trustworthy if it can fail."""

    SCHEMA = {
        "type": "object",
        "required": ["id", "title"],
        "properties": {
            "id": {"type": "string"},
            "title": {"type": "string"},
            "origin": {
                "type": "object",
                "properties": {"kind": {"enum": ["cowork", "manual"]}},
            },
        },
    }

    def test_accepts_valid(self):
        instance = {"id": "A", "title": "T", "origin": {"kind": "cowork"}}
        self.assertEqual(validate_against_schema(instance, self.SCHEMA), [])

    def test_reports_missing_required(self):
        self.assertTrue(validate_against_schema({"id": "A"}, self.SCHEMA))

    def test_reports_bad_enum_and_type(self):
        instance = {"id": 1, "title": "T", "origin": {"kind": "slack"}}
        errors = validate_against_schema(instance, self.SCHEMA)
        self.assertEqual(len(errors), 2, errors)


class TestCli(ReaderFolderCase):
    @staticmethod
    def run_cli(argv: list[str]) -> int:
        """Run the CLI with its JSON output captured, so test output stays readable."""
        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            return str_mod.main(argv)

    def test_check_reports_ok_for_a_valid_folder(self):
        code = self.run_cli(["--check", "--folder", str(self.folder)])
        self.assertEqual(code, 0)

    def test_check_fails_for_a_folder_without_inbox(self):
        bare = self.tmp / "bare"
        bare.mkdir()
        self.assertEqual(self.run_cli(["--check", "--folder", str(bare)]), 1)

    def test_stdin_send(self):
        with mock.patch.object(sys, "stdin", io.StringIO("# Hi\n\nBody.\n")):
            code = self.run_cli(
                [
                    "--title", "Hello there",
                    "--stdin",
                    "--folder", str(self.folder),
                    "--config", str(self.config),
                    "--date", "2026-08-18",
                    "--session-id", "abc",
                ]
            )
        self.assertEqual(code, 0)
        self.assertEqual(visible_entries(self.inbox), ["2026-08-18-hello-there"])

    def test_source_file_send(self):
        source = self.tmp / "plan.md"
        source.write_text("# Plan\n\nBody.\n")
        code = self.run_cli(
            [
                "--title", "The plan",
                "--source", str(source),
                "--folder", str(self.folder),
                "--config", str(self.config),
                "--date", "2026-08-18",
            ]
        )
        self.assertEqual(code, 0)
        self.assertEqual(visible_entries(self.inbox), ["2026-08-18-the-plan"])

    def test_requires_exactly_one_source(self):
        self.assertEqual(
            self.run_cli(["--title", "x", "--folder", str(self.folder)]), 2
        )

    def test_set_folder_records_the_path_in_the_config(self):
        config = self.tmp / "fresh.json"
        code = self.run_cli(["--set-folder", str(self.folder), "--config", str(config)])
        self.assertEqual(code, 0)
        self.assertEqual(json.loads(config.read_text())["syncRoot"], str(self.folder))
        self.assertEqual(str_mod.resolve_reader_folder(None, config), self.folder)

    def test_set_folder_still_records_but_fails_on_a_bad_folder(self):
        bare = self.tmp / "bare"
        bare.mkdir()
        config = self.tmp / "fresh.json"
        self.assertEqual(
            self.run_cli(["--set-folder", str(bare), "--config", str(config)]), 1
        )
        self.assertEqual(json.loads(config.read_text())["syncRoot"], str(bare))

    def test_dry_run_via_cli_writes_nothing(self):
        source = self.tmp / "plan.md"
        source.write_text("# Plan\n")
        code = self.run_cli(
            [
                "--title", "The plan",
                "--source", str(source),
                "--folder", str(self.folder),
                "--config", str(self.config),
                "--dry-run",
            ]
        )
        self.assertEqual(code, 0)
        self.assertEqual(list(self.inbox.iterdir()), [])


if __name__ == "__main__":
    unittest.main(verbosity=2)
