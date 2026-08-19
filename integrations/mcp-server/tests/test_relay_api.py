"""The relay's HTTP surface.

Skips cleanly when Starlette is absent, exactly as the MCP tool tests skip when
the MCP SDK is absent — the contract layer must stay testable with nothing
installed.

The tests that matter most are the ones about *when* a document becomes
visible. A device that learns about a document whose bytes are not all here
would pin a partial copy, and non-negotiable 2 would be a lie.
"""

from __future__ import annotations

import hashlib
import json
import shutil
import tempfile
import unittest
from pathlib import Path

try:
    from starlette.testclient import TestClient
except ImportError:  # pragma: no cover - exercised on a bare interpreter
    TestClient = None

from pencil_in_the_loop_mcp.relay.db import Index

TOKEN = "test-device-token"


def sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


@unittest.skipIf(TestClient is None, "starlette is not installed")
class RelayApiTestCase(unittest.TestCase):
    def setUp(self) -> None:
        from pencil_in_the_loop_mcp.relay.app import create_app

        self.root = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.root, ignore_errors=True)
        self.index = Index(self.root / "index.sqlite3")
        self.addCleanup(self.index.close)
        self.app = create_app(
            sync_root=self.root, index=self.index, device_token=TOKEN
        )
        self.client = TestClient(self.app)
        self.auth = {"Authorization": f"Bearer {TOKEN}"}

    def send(self, content: str = "# Auth refactor plan\n\nBody.", **extra):
        return self.client.post(
            "/v1/documents", json={"content": content, **extra}, headers=self.auth
        )


class AuthTests(RelayApiTestCase):
    def test_health_needs_no_token(self) -> None:
        response = self.client.get("/healthz")
        self.assertEqual(response.status_code, 200)
        self.assertTrue(response.json()["ok"])

    def test_everything_under_v1_needs_one(self) -> None:
        for method, path in (
            ("get", "/v1/changes"),
            ("get", "/v1/reviews"),
            ("post", "/v1/documents"),
        ):
            response = getattr(self.client, method)(path)
            self.assertEqual(response.status_code, 401, path)
            self.assertEqual(response.json()["error"], "unauthorized")

    def test_a_wrong_token_is_refused(self) -> None:
        response = self.client.get(
            "/v1/changes", headers={"Authorization": "Bearer nope"}
        )
        self.assertEqual(response.status_code, 401)

    def test_a_malformed_scheme_is_refused(self) -> None:
        for header in ("", "Bearer", f"Basic {TOKEN}", TOKEN):
            response = self.client.get(
                "/v1/changes", headers={"Authorization": header}
            )
            self.assertEqual(response.status_code, 401, header)


class SendDocumentTests(RelayApiTestCase):
    def test_a_markdown_document_lands_complete(self) -> None:
        response = self.send()
        self.assertEqual(response.status_code, 201)
        body = response.json()
        self.assertEqual(body["folderName"], self.today_plan())
        self.assertTrue(body["complete"])
        self.assertEqual(body["missingFiles"], [])

        directory = self.root / "inbox" / body["folderName"]
        self.assertTrue((directory / "source.md").is_file())
        self.assertTrue((directory / "meta.json").is_file())

    def today_plan(self) -> str:
        from datetime import date

        return f"{date.today().isoformat()}-auth-refactor-plan"

    def test_the_same_document_id_twice_is_one_document(self) -> None:
        first = self.send(documentId="FIXEDID1")
        second = self.send(documentId="FIXEDID1")
        self.assertEqual(first.status_code, 201)
        self.assertEqual(second.status_code, 200)
        self.assertTrue(second.json()["idempotent"])
        self.assertEqual(first.json()["folderName"], second.json()["folderName"])

    def test_two_sends_are_two_documents_with_a_collision_suffix(self) -> None:
        first = self.send()
        second = self.send()
        self.assertNotEqual(first.json()["folderName"], second.json()["folderName"])
        self.assertTrue(second.json()["folderName"].endswith("-2"))

    def test_invalid_content_is_refused_and_writes_nothing(self) -> None:
        response = self.client.post(
            "/v1/documents", json={"content": "   "}, headers=self.auth
        )
        self.assertEqual(response.status_code, 400)
        self.assertEqual(response.json()["error"], "invalid_input")
        self.assertEqual(list((self.root / "inbox").glob("*")), [])

    def test_the_feed_advertises_a_size_and_hash_for_every_file(self) -> None:
        """The iPad verifies each download against what the feed said. A null
        hash would turn that check off for the two files every document has."""
        self.send()
        feed = self.client.get("/v1/changes", headers=self.auth).json()
        directory = self.root / "inbox" / feed["documents"][0]["folderName"]
        for entry in feed["documents"][0]["files"]:
            body = (directory / entry["name"]).read_bytes()
            self.assertEqual(entry["bytes"], len(body), entry["name"])
            self.assertEqual(entry["sha256"], sha(body), entry["name"])

    def test_a_trigger_id_never_reaches_the_disk(self) -> None:
        """A trigger id fires a turn into someone's conversation. It is closer
        to a credential than to metadata."""
        response = self.send(sessionId="sess_abcdef", originKind="claude-code")
        directory = self.root / "inbox" / response.json()["folderName"]
        stored = (directory / "meta.json").read_text()
        self.assertNotIn("triggerId", stored)
        self.assertIn("list_reviews", stored)


class DeclaredUploadTests(RelayApiTestCase):
    """Declare, then upload. The document must stay invisible until the last
    byte lands."""

    def declare(self, pdf: bytes):
        return self.send(
            expectedFiles=[
                {"name": "document.pdf", "bytes": len(pdf), "sha256": sha(pdf)}
            ]
        )

    def test_a_document_awaiting_a_file_is_not_in_the_feed(self) -> None:
        pdf = b"%PDF-1.7 fake"
        response = self.declare(pdf)
        self.assertEqual(response.status_code, 201)
        self.assertFalse(response.json()["complete"])
        self.assertEqual(response.json()["missingFiles"], ["document.pdf"])

        feed = self.client.get("/v1/changes", headers=self.auth).json()
        self.assertEqual(feed["documents"], [])

    def test_it_appears_the_moment_the_last_file_lands(self) -> None:
        pdf = b"%PDF-1.7 fake"
        folder = self.declare(pdf).json()["folderName"]

        upload = self.client.put(
            f"/v1/documents/{folder}/files/document.pdf",
            content=pdf,
            headers=self.auth,
        )
        self.assertEqual(upload.status_code, 200)
        self.assertTrue(upload.json()["complete"])
        self.assertEqual(upload.json()["sha256"], sha(pdf))

        feed = self.client.get("/v1/changes", headers=self.auth).json()
        self.assertEqual([d["folderName"] for d in feed["documents"]], [folder])
        names = sorted(f["name"] for f in feed["documents"][0]["files"])
        self.assertEqual(names, ["document.pdf", "meta.json", "source.md"])

    def test_the_bytes_come_back_exactly(self) -> None:
        pdf = b"%PDF-1.7 " + bytes(range(256)) * 40
        folder = self.declare(pdf).json()["folderName"]
        self.client.put(
            f"/v1/documents/{folder}/files/document.pdf",
            content=pdf,
            headers=self.auth,
        )
        got = self.client.get(
            f"/v1/documents/{folder}/files/document.pdf", headers=self.auth
        )
        self.assertEqual(got.status_code, 200)
        self.assertEqual(got.content, pdf)
        self.assertEqual(got.headers["etag"], f'"{sha(pdf)}"')

    def test_a_file_outside_the_contract_is_refused(self) -> None:
        folder = self.send().json()["folderName"]
        for name in ("notes.txt", "..%2Fmeta.json"):
            response = self.client.put(
                f"/v1/documents/{folder}/files/{name}",
                content=b"x",
                headers=self.auth,
            )
            self.assertIn(response.status_code, (400, 404), name)

    def test_an_oversized_declaration_is_refused(self) -> None:
        response = self.send(
            expectedFiles=[
                {"name": "document.pdf", "bytes": 500 * 1024 * 1024, "sha256": None}
            ]
        )
        self.assertEqual(response.status_code, 400)


class ChangesFeedTests(RelayApiTestCase):
    def test_the_cursor_only_returns_what_is_new(self) -> None:
        self.send(content="# One\n\nBody.")
        first = self.client.get("/v1/changes", headers=self.auth).json()
        self.assertEqual(len(first["documents"]), 1)

        empty = self.client.get(
            f"/v1/changes?since={first['cursor']}", headers=self.auth
        ).json()
        self.assertEqual(empty["documents"], [])

        self.send(content="# Two\n\nBody.")
        second = self.client.get(
            f"/v1/changes?since={first['cursor']}", headers=self.auth
        ).json()
        self.assertEqual(len(second["documents"]), 1)
        self.assertEqual(second["documents"][0]["title"], "Two")

    def test_an_unchanged_feed_answers_304(self) -> None:
        """An idle 15s poll should cost almost nothing."""
        response = self.client.get("/v1/changes", headers=self.auth)
        etag = response.headers["etag"]
        again = self.client.get(
            "/v1/changes", headers={**self.auth, "If-None-Match": etag}
        )
        self.assertEqual(again.status_code, 304)

    def test_the_epoch_tells_a_device_to_start_over(self) -> None:
        self.send()
        before = self.client.get("/v1/changes", headers=self.auth).json()["epoch"]
        self.index.reindex(self.root)
        after = self.client.get("/v1/changes", headers=self.auth).json()["epoch"]
        self.assertNotEqual(before, after)

    def test_a_bad_cursor_is_refused_rather_than_silently_zero(self) -> None:
        response = self.client.get("/v1/changes?since=soon", headers=self.auth)
        self.assertEqual(response.status_code, 400)


class ReviewTests(RelayApiTestCase):
    def bundle(self, folder: str, ink: bytes | None = None):
        review_md = "# Review — Auth refactor plan\n\n### 1 — a note\n"
        entries = [
            {
                "path": "review.md",
                "bytes": len(review_md.encode()),
                "sha256": sha(review_md.encode()),
            }
        ]
        if ink is not None:
            entries.append(
                {"path": "ink/page-01.png", "bytes": len(ink), "sha256": sha(ink)}
            )
        manifest = {
            "version": 1,
            "documentId": "DOC1",
            "reviewFolder": f"{folder}.review",
            "createdAt": "2026-08-19T09:00:00Z",
            "files": entries,
        }
        return manifest, review_md

    def test_a_review_with_no_ink_lands_immediately(self) -> None:
        folder = self.send().json()["folderName"]
        manifest, review_md = self.bundle(folder)
        response = self.client.post(
            f"/v1/documents/{folder}/review",
            json={"manifest": manifest, "reviewMarkdown": review_md},
            headers=self.auth,
        )
        self.assertEqual(response.status_code, 201)
        self.assertTrue(response.json()["complete"])
        self.assertTrue(
            (self.root / "outbox" / f"{folder}.review" / "review.md").is_file()
        )

    def test_an_ink_page_is_uploaded_after_the_declaration(self) -> None:
        folder = self.send().json()["folderName"]
        ink = b"\x89PNG\r\n\x1a\n" + b"pixels"
        manifest, review_md = self.bundle(folder, ink=ink)

        declared = self.client.post(
            f"/v1/documents/{folder}/review",
            json={"manifest": manifest, "reviewMarkdown": review_md},
            headers=self.auth,
        )
        self.assertEqual(declared.status_code, 201)
        self.assertFalse(declared.json()["complete"])
        self.assertFalse((self.root / "outbox" / f"{folder}.review").exists())

        uploaded = self.client.put(
            f"/v1/reviews/{folder}/files/ink/page-01.png",
            content=ink,
            headers=self.auth,
        )
        self.assertEqual(uploaded.status_code, 200)
        self.assertTrue(uploaded.json()["complete"])
        self.assertTrue(
            (self.root / "outbox" / f"{folder}.review" / "ink" / "page-01.png").is_file()
        )

    def test_the_same_bundle_twice_is_one_review(self) -> None:
        folder = self.send().json()["folderName"]
        manifest, review_md = self.bundle(folder)
        payload = {"manifest": manifest, "reviewMarkdown": review_md}
        first = self.client.post(
            f"/v1/documents/{folder}/review", json=payload, headers=self.auth
        )
        second = self.client.post(
            f"/v1/documents/{folder}/review", json=payload, headers=self.auth
        )
        self.assertEqual(first.status_code, 201)
        self.assertEqual(second.status_code, 200)
        self.assertTrue(second.json()["idempotent"])
        self.assertEqual(second.json()["revision"], 1)

    def test_ink_that_does_not_match_the_manifest_is_refused(self) -> None:
        folder = self.send().json()["folderName"]
        ink = b"\x89PNG real"
        manifest, review_md = self.bundle(folder, ink=ink)
        self.client.post(
            f"/v1/documents/{folder}/review",
            json={"manifest": manifest, "reviewMarkdown": review_md},
            headers=self.auth,
        )
        response = self.client.put(
            f"/v1/reviews/{folder}/files/ink/page-01.png",
            content=b"different bytes entirely",
            headers=self.auth,
        )
        self.assertEqual(response.status_code, 422)
        self.assertEqual(response.json()["error"], "manifest_mismatch")
        self.assertFalse((self.root / "outbox" / f"{folder}.review").exists())

    def test_a_manifest_without_review_markdown_is_refused(self) -> None:
        folder = self.send().json()["folderName"]
        response = self.client.post(
            f"/v1/documents/{folder}/review",
            json={"manifest": {"files": [{"path": "review.json"}]},
                  "reviewMarkdown": "x"},
            headers=self.auth,
        )
        self.assertEqual(response.status_code, 400)

    def test_reviews_can_be_listed_and_read_back(self) -> None:
        folder = self.send().json()["folderName"]
        manifest, review_md = self.bundle(folder)
        self.client.post(
            f"/v1/documents/{folder}/review",
            json={"manifest": manifest, "reviewMarkdown": review_md},
            headers=self.auth,
        )
        listed = self.client.get("/v1/reviews", headers=self.auth).json()
        self.assertEqual([r["id"] for r in listed["reviews"]], [folder])

        read = self.client.get(f"/v1/reviews/{folder}", headers=self.auth).json()
        self.assertIn("Auth refactor plan", read["reviewMarkdown"])

    def test_a_reply_is_written_and_appears_in_the_feed(self) -> None:
        folder = self.send().json()["folderName"]
        manifest, review_md = self.bundle(folder)
        self.client.post(
            f"/v1/documents/{folder}/review",
            json={"manifest": manifest, "reviewMarkdown": review_md},
            headers=self.auth,
        )
        before = self.client.get("/v1/changes", headers=self.auth).json()["cursor"]

        reply = self.client.put(
            f"/v1/reviews/{folder}/reply",
            content=b"Thanks - I have made those changes.\n",
            headers={**self.auth, "Content-Type": "text/markdown"},
        )
        self.assertEqual(reply.status_code, 200)
        self.assertTrue(
            (self.root / "outbox" / f"{folder}.review" / "reply.md").is_file()
        )

        feed = self.client.get(f"/v1/changes?since={before}", headers=self.auth).json()
        self.assertEqual([r["folderName"] for r in feed["replies"]], [folder])

    def test_a_review_path_cannot_escape_the_outbox(self) -> None:
        folder = self.send().json()["folderName"]
        for path in ("../../etc/passwd", "ink/../../x.png", "notes.txt"):
            response = self.client.put(
                f"/v1/reviews/{folder}/files/{path}", content=b"x", headers=self.auth
            )
            self.assertIn(response.status_code, (400, 404), path)


class OpsTests(RelayApiTestCase):
    def test_export_returns_a_tarball_of_the_sync_root(self) -> None:
        import io
        import tarfile

        self.send()
        response = self.client.get("/v1/export.tar", headers=self.auth)
        self.assertEqual(response.status_code, 200)
        with tarfile.open(fileobj=io.BytesIO(response.content)) as archive:
            names = archive.getnames()
        self.assertTrue(any(name.endswith("meta.json") for name in names), names)

    def test_a_deleted_document_becomes_a_tombstone(self) -> None:
        folder = self.send().json()["folderName"]
        before = self.client.get("/v1/changes", headers=self.auth).json()["cursor"]

        response = self.client.delete(
            f"/v1/documents/{folder}", headers=self.auth
        )
        self.assertEqual(response.status_code, 200)
        self.assertFalse((self.root / "inbox" / folder).exists())

        feed = self.client.get(f"/v1/changes?since={before}", headers=self.auth).json()
        self.assertEqual(len(feed["documents"]), 1)
        self.assertIsNotNone(feed["documents"][0]["deletedAt"])


if __name__ == "__main__":
    unittest.main()
