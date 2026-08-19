"""The relay's file rules.

`{name}` and `{folderName}` arrive from the network here, where in the folder
transport they came from a directory listing. `tests/test_core.py` already
proves `validate_bundle_id` blocks traversal; these are the same class of test
moved to the new door, plus the manifest verification that makes
`manifest.json` a completeness signal rather than a file nobody reads.
"""

from __future__ import annotations

import hashlib
import json
import shutil
import tempfile
import unittest
from pathlib import Path

from pencil_in_the_loop_mcp import core
from pencil_in_the_loop_mcp.relay import files


def sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


class DocumentFileNameTests(unittest.TestCase):
    def test_the_four_contract_names_are_accepted(self) -> None:
        for name in ("meta.json", "source.md", "document.pdf", "sourcemap.json"):
            self.assertEqual(files.validate_document_file(name), name)

    def test_everything_else_is_refused(self) -> None:
        for name in (
            "review.md",
            "notes.txt",
            "",
            None,
            42,
            "META.JSON",
            "meta.json ",
        ):
            with self.assertRaises(files.FileRejected):
                files.validate_document_file(name)

    def test_traversal_cannot_dress_up_as_a_contract_name(self) -> None:
        """There is deliberately no normalisation step: a name that needs
        normalising is not one of the four."""
        for name in (
            "../meta.json",
            "../../etc/passwd",
            "ink/../meta.json",
            "/meta.json",
            "sub/meta.json",
            "meta.json/../../x",
        ):
            with self.assertRaises(files.FileRejected):
                files.validate_document_file(name)


class ReviewFileNameTests(unittest.TestCase):
    def test_the_bundle_names_and_ink_pages_are_accepted(self) -> None:
        for name in (
            "review.md",
            "review.json",
            "manifest.json",
            "reply.md",
            "ink/page-01.png",
            "ink/page-123.png",
        ):
            self.assertEqual(files.validate_review_file(name), name)

    def test_ink_paths_outside_the_contract_shape_are_refused(self) -> None:
        for name in (
            "ink/page-1.png",  # the contract zero-pads to at least two
            "ink/page-01.PNG",
            "ink/page-01.png/x",
            "ink/../review.md",
            "ink/nested/page-01.png",
            "../ink/page-01.png",
            "ink/page-01.jpg",
        ):
            with self.assertRaises(files.FileRejected):
                files.validate_review_file(name)


class BundleIdTests(unittest.TestCase):
    def test_it_refuses_to_escape_the_sync_root(self) -> None:
        for value in ("../secrets", "a/b", "..", ".hidden", "", "a\\b", "x\x00y"):
            with self.assertRaises(core.ValidationError):
                files.bundle_id(value)

    def test_whatever_it_returns_is_a_single_safe_path_component(self) -> None:
        """The invariant that matters, rather than a list of inputs.

        A leading or trailing slash is stripped rather than refused — the
        tolerance exists for `2026-08-18-plan/`, and `/etc` therefore normalises
        to `etc`. That is safe because what comes back must still match the
        bundle-name pattern, so it can only ever name something directly inside
        the outbox; `core.read_review` then re-asserts containment anyway. It is
        worth pinning down, because "it strips slashes" reads alarming until you
        check what survives the pattern.
        """
        for value in ("2026-08-18-plan", "/2026-08-18-plan", "2026-08-18-plan/"):
            result = files.bundle_id(value)
            self.assertEqual(result, "2026-08-18-plan")
            self.assertEqual(Path(result).name, result)
            self.assertEqual(len(Path(result).parts), 1)

    def test_a_review_suffix_is_tolerated(self) -> None:
        self.assertEqual(
            files.bundle_id("2026-08-18-plan.review"), "2026-08-18-plan"
        )


class SizeGateTests(unittest.TestCase):
    def test_a_pdf_gets_the_larger_allowance(self) -> None:
        self.assertEqual(files.max_bytes_for("document.pdf"), files.MAX_DOCUMENT_PDF_BYTES)
        self.assertEqual(files.max_bytes_for("source.md"), files.MAX_OTHER_FILE_BYTES)

    def test_an_oversized_declaration_is_refused_before_any_body_arrives(self) -> None:
        with self.assertRaises(files.FileRejected):
            files.check_declared_size("document.pdf", files.MAX_DOCUMENT_PDF_BYTES + 1)
        with self.assertRaises(files.FileRejected):
            files.check_declared_size("source.md", files.MAX_OTHER_FILE_BYTES + 1)

    def test_a_size_that_is_not_a_whole_number_is_refused(self) -> None:
        for value in ("100", 1.5, True, None, -1):
            with self.assertRaises(files.FileRejected):
                files.check_declared_size("source.md", value)


class WriteStreamTests(unittest.TestCase):
    def setUp(self) -> None:
        self.root = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.root, ignore_errors=True)

    def test_it_reports_the_size_and_hash_it_actually_wrote(self) -> None:
        body = b"a quick brown fox" * 1000
        written, digest = files.write_stream(
            [body[:500], body[500:]], self.root / "document.pdf"
        )
        self.assertEqual(written, len(body))
        self.assertEqual(digest, sha(body))
        self.assertEqual((self.root / "document.pdf").read_bytes(), body)

    def test_it_creates_the_intermediate_directory_for_an_ink_page(self) -> None:
        files.write_stream([b"png"], self.root / "ink" / "page-01.png")
        self.assertTrue((self.root / "ink" / "page-01.png").is_file())

    def test_empty_chunks_are_skipped_rather_than_written(self) -> None:
        written, digest = files.write_stream(
            [b"", b"one", b"", b"two", b""], self.root / "source.md"
        )
        self.assertEqual(written, 6)
        self.assertEqual(digest, sha(b"onetwo"))


class ManifestTests(unittest.TestCase):
    def setUp(self) -> None:
        self.root = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.root, ignore_errors=True)

    def manifest(self, **overrides: object) -> dict:
        body = b"# Review\n"
        (self.root / "review.md").write_bytes(body)
        base = {
            "files": [
                {"path": "review.md", "bytes": len(body), "sha256": sha(body)},
            ]
        }
        base.update(overrides)
        return base

    def test_a_well_formed_manifest_verifies(self) -> None:
        entries = files.manifest_entries(self.manifest())
        files.verify_against_manifest(self.root, entries)

    def test_a_manifest_that_is_not_an_object_is_refused(self) -> None:
        for value in (None, [], "review.md", 7):
            with self.assertRaises(files.FileRejected):
                files.manifest_entries(value)

    def test_a_manifest_must_list_review_markdown(self) -> None:
        with self.assertRaises(files.FileRejected):
            files.manifest_entries({"files": [{"path": "review.json"}]})

    def test_a_manifest_must_not_list_itself(self) -> None:
        with self.assertRaises(files.FileRejected):
            files.manifest_entries(
                {"files": [{"path": "review.md"}, {"path": "manifest.json"}]}
            )

    def test_a_duplicate_path_is_refused(self) -> None:
        with self.assertRaises(files.FileRejected):
            files.manifest_entries(
                {"files": [{"path": "review.md"}, {"path": "review.md"}]}
            )

    def test_a_manifest_path_outside_the_contract_is_refused(self) -> None:
        with self.assertRaises(files.FileRejected):
            files.manifest_entries(
                {"files": [{"path": "review.md"}, {"path": "../../etc/passwd"}]}
            )

    def test_a_malformed_hash_is_refused(self) -> None:
        with self.assertRaises(files.FileRejected):
            files.manifest_entries(
                {"files": [{"path": "review.md", "sha256": "not-a-hash"}]}
            )

    def test_a_missing_file_fails_verification_by_name(self) -> None:
        entries = files.manifest_entries(
            {"files": [{"path": "review.md"}, {"path": "ink/page-01.png"}]}
        )
        (self.root / "review.md").write_bytes(b"# Review\n")
        with self.assertRaises(files.FileRejected) as caught:
            files.verify_against_manifest(self.root, entries)
        self.assertIn("ink/page-01.png", str(caught.exception))

    def test_a_short_upload_fails_verification(self) -> None:
        entries = files.manifest_entries(self.manifest())
        (self.root / "review.md").write_bytes(b"# Rev")  # truncated
        with self.assertRaises(files.FileRejected):
            files.verify_against_manifest(self.root, entries)

    def test_the_right_size_with_the_wrong_bytes_still_fails(self) -> None:
        """Size alone would pass this. The hash is why it is in the contract."""
        entries = files.manifest_entries(self.manifest())
        (self.root / "review.md").write_bytes(b"# Rewiew\n")
        with self.assertRaises(files.FileRejected) as caught:
            files.verify_against_manifest(self.root, entries)
        self.assertIn("sha256", str(caught.exception))


class ReturnPathSecretTests(unittest.TestCase):
    """A triggerId fires a turn into someone's conversation. It is closer to a
    credential than to metadata and must not sit on a server."""

    def test_a_trigger_id_is_removed(self) -> None:
        meta = {
            "id": "ABC",
            "origin": {
                "kind": "claude-code",
                "sessionId": "sess_123456",
                "returnPath": {"type": "poke", "triggerId": "trig_secret"},
            },
        }
        cleaned = files.strip_return_path_secrets(meta)
        self.assertNotIn("triggerId", json.dumps(cleaned))
        self.assertEqual(cleaned["origin"]["returnPath"]["type"], "none")
        self.assertIn("list_reviews", cleaned["origin"]["returnPath"]["detail"])

    def test_the_session_id_is_kept(self) -> None:
        """A label, behind a token, on a single-tenant server. It is what lets
        a reply find the conversation it belongs to."""
        meta = {
            "origin": {
                "kind": "claude-code",
                "sessionId": "sess_123456",
                "returnPath": {"type": "cloud", "sessionId": "sess_123456"},
            }
        }
        cleaned = files.strip_return_path_secrets(meta)
        self.assertEqual(cleaned["origin"]["sessionId"], "sess_123456")

    def test_the_original_is_not_mutated(self) -> None:
        meta = {"origin": {"returnPath": {"type": "poke", "triggerId": "trig_x"}}}
        files.strip_return_path_secrets(meta)
        self.assertEqual(meta["origin"]["returnPath"]["triggerId"], "trig_x")

    def test_meta_with_nothing_to_strip_is_returned_as_is(self) -> None:
        for meta in ({}, {"origin": {}}, {"origin": {"returnPath": {"type": "none"}}}):
            self.assertEqual(files.strip_return_path_secrets(meta), meta)


if __name__ == "__main__":
    unittest.main()
