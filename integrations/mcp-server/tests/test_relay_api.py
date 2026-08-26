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

    def test_a_group_is_carried_into_the_written_meta_json(self) -> None:
        response = self.send(group="  Attention   Papers ")
        self.assertEqual(response.status_code, 201)

        directory = self.root / "inbox" / response.json()["folderName"]
        meta = json.loads((directory / "meta.json").read_text())
        self.assertEqual(
            meta["group"],
            "Attention Papers",
            "The relay stores the bytes; the group rides inside meta.json like everything else.",
        )

    def test_a_bad_group_is_refused_and_writes_nothing(self) -> None:
        response = self.send(group="a" * 200)

        self.assertEqual(response.status_code, 400)
        self.assertEqual(response.json()["error"], "invalid_input")
        self.assertFalse((self.root / "inbox").exists())

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


class ReconciliationTests(RelayApiTestCase):
    """A bundle written straight to the volume must reach the feed.

    This is not a corner case: it is the primary path. The MCP tools write with
    `core.write_inbox_bundle`, exactly as the folder transport does, and they do
    not know the index exists. Without reconciliation a document sent from
    Claude lands on disk and no device ever sees it.
    """

    def write_bundle_directly(self, name: str, title: str) -> None:
        from pencil_in_the_loop_mcp import core

        core.write_inbox_bundle(self.root, content=f"# {title}\n\nBody.\n")

    def test_a_bundle_written_by_a_tool_reaches_the_feed(self) -> None:
        self.write_bundle_directly("2026-08-19-written-directly", "Written directly")

        feed = self.client.get("/v1/changes", headers=self.auth).json()
        titles = [d["title"] for d in feed["documents"]]
        self.assertIn("Written directly", titles)

    def test_it_carries_a_size_and_hash_so_a_device_can_verify(self) -> None:
        self.write_bundle_directly("2026-08-19-written-directly", "Written directly")
        feed = self.client.get("/v1/changes", headers=self.auth).json()
        directory = self.root / "inbox" / feed["documents"][0]["folderName"]

        for entry in feed["documents"][0]["files"]:
            body = (directory / entry["name"]).read_bytes()
            self.assertEqual(entry["bytes"], len(body), entry["name"])
            self.assertEqual(entry["sha256"], sha(body), entry["name"])

    def test_reconciling_twice_does_not_duplicate_it(self) -> None:
        self.write_bundle_directly("2026-08-19-written-directly", "Written directly")
        first = self.client.get("/v1/changes", headers=self.auth).json()
        second = self.client.get("/v1/changes", headers=self.auth).json()
        self.assertEqual(len(first["documents"]), len(second["documents"]))

    def test_it_is_downloadable_like_any_other(self) -> None:
        self.write_bundle_directly("2026-08-19-written-directly", "Written directly")
        feed = self.client.get("/v1/changes", headers=self.auth).json()
        folder = feed["documents"][0]["folderName"]

        got = self.client.get(
            f"/v1/documents/{folder}/files/source.md", headers=self.auth
        )
        self.assertEqual(got.status_code, 200)
        self.assertIn("Written directly", got.text)

    def test_a_half_written_staging_directory_is_ignored(self) -> None:
        """Dot-prefixed staging is what every watcher already skips."""
        staging = self.root / "inbox" / ".2026-08-19-half.abc123.tmp"
        staging.mkdir(parents=True)
        (staging / "source.md").write_text("# Half\n")

        feed = self.client.get("/v1/changes", headers=self.auth).json()
        self.assertEqual(feed["documents"], [])


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

    def deliver(self, folder: str):
        """Declare and upload, which is what sending a review now means."""
        manifest, review_md = self.bundle(folder)
        declared = self.client.post(
            f"/v1/documents/{folder}/review",
            json={"manifest": manifest},
            headers=self.auth,
        )
        self.client.put(
            f"/v1/reviews/{folder}/files/review.md",
            content=review_md.encode(),
            headers=self.auth,
        )
        return declared

    def test_a_review_lands_once_its_declared_files_are_uploaded(self) -> None:
        """Declared, then uploaded — including review.md.

        The server writes only manifest.json, because it is the one file the
        manifest does not hash. Everything else must arrive as the exact bytes
        the device hashed, or verification cannot pass.
        """
        folder = self.send().json()["folderName"]
        manifest, review_md = self.bundle(folder)
        declared = self.client.post(
            f"/v1/documents/{folder}/review",
            json={"manifest": manifest},
            headers=self.auth,
        )
        self.assertEqual(declared.status_code, 201)
        self.assertFalse(declared.json()["complete"])

        uploaded = self.client.put(
            f"/v1/reviews/{folder}/files/review.md",
            content=review_md.encode(),
            headers=self.auth,
        )
        self.assertEqual(uploaded.status_code, 200)
        self.assertTrue(uploaded.json()["complete"])
        self.assertTrue(
            (self.root / "outbox" / f"{folder}.review" / "review.md").is_file()
        )

    def test_bytes_the_server_re_encoded_would_fail_verification(self) -> None:
        """The 422 this shape exists to prevent.

        A device hashes what it wrote. `json.dumps` of the same object — other
        key order, other spacing — is different bytes, so a server that writes
        review.json itself can never satisfy the manifest it was given.
        """
        import json as _json

        folder = self.send().json()["folderName"]
        review_json = {"documentId": "DOC1", "comments": [], "inkPages": []}
        device_bytes = _json.dumps(review_json, sort_keys=True, indent=2).encode()
        server_bytes = _json.dumps(review_json, indent=2, ensure_ascii=False).encode()
        self.assertNotEqual(
            sha(device_bytes),
            sha(server_bytes),
            "if these ever match, this whole upload shape is unnecessary",
        )

    def test_an_ink_page_is_uploaded_after_the_declaration(self) -> None:
        folder = self.send().json()["folderName"]
        ink = b"\x89PNG\r\n\x1a\n" + b"pixels"
        manifest, review_md = self.bundle(folder, ink=ink)

        declared = self.client.post(
            f"/v1/documents/{folder}/review",
            json={"manifest": manifest},
            headers=self.auth,
        )
        self.assertEqual(declared.status_code, 201)
        self.assertFalse(declared.json()["complete"])
        self.assertFalse((self.root / "outbox" / f"{folder}.review").exists())

        self.client.put(
            f"/v1/reviews/{folder}/files/review.md",
            content=review_md.encode(),
            headers=self.auth,
        )
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
        first = self.deliver(folder)
        manifest, _ = self.bundle(folder)
        second = self.client.post(
            f"/v1/documents/{folder}/review",
            json={"manifest": manifest},
            headers=self.auth,
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
            json={"manifest": manifest},
            headers=self.auth,
        )
        self.client.put(
            f"/v1/reviews/{folder}/files/review.md",
            content=review_md.encode(),
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
            json={"manifest": {"files": [{"path": "review.json"}]}},
            headers=self.auth,
        )
        self.assertEqual(response.status_code, 400)

    def test_reviews_can_be_listed_and_read_back(self) -> None:
        folder = self.send().json()["folderName"]
        self.deliver(folder)
        listed = self.client.get("/v1/reviews", headers=self.auth).json()
        self.assertEqual([r["id"] for r in listed["reviews"]], [folder])

        read = self.client.get(f"/v1/reviews/{folder}", headers=self.auth).json()
        self.assertIn("Auth refactor plan", read["reviewMarkdown"])

    def test_a_reply_is_written_and_appears_in_the_feed(self) -> None:
        folder = self.send().json()["folderName"]
        self.deliver(folder)
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


@unittest.skipIf(TestClient is None, "starlette is not installed")
class McpMountTests(unittest.TestCase):
    """The MCP endpoint's auth.

    This is a regression test for a real hole: the guard originally only
    covered `/v1/`, so mounting the MCP app left every tool callable by
    anyone who knew the URL. A stub ASGI app stands in for the SDK, because
    what is being tested is the guard, not the protocol.
    """

    def setUp(self) -> None:
        from starlette.responses import PlainTextResponse
        from pencil_in_the_loop_mcp.relay.app import create_app

        self.root = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.root, ignore_errors=True)
        self.index = Index(self.root / "index.sqlite3")
        self.addCleanup(self.index.close)

        async def stub(scope, receive, send):
            await PlainTextResponse("mcp reached")(scope, receive, send)

        self.client = TestClient(
            create_app(
                sync_root=self.root,
                index=self.index,
                device_token=TOKEN,
                mcp_app=stub,
                mcp_token="mcp-secret",
            )
        )

    def test_the_endpoint_is_not_open_to_anyone_who_knows_the_url(self) -> None:
        self.assertEqual(self.client.get("/mcp/").status_code, 401)
        self.assertEqual(
            self.client.get(
                "/mcp/", headers={"Authorization": "Bearer wrong"}
            ).status_code,
            401,
        )

    def test_the_device_token_does_not_open_the_mcp_endpoint(self) -> None:
        """Two secrets, so revoking one does not revoke the other."""
        response = self.client.get(
            "/mcp/", headers={"Authorization": f"Bearer {TOKEN}"}
        )
        self.assertEqual(response.status_code, 401)

    def test_the_mcp_token_in_a_header_is_accepted(self) -> None:
        response = self.client.get(
            "/mcp/", headers={"Authorization": "Bearer mcp-secret"}
        )
        self.assertEqual(response.status_code, 200)
        self.assertIn("mcp reached", response.text)

    def test_the_capability_url_authenticates_by_being_known(self) -> None:
        response = self.client.get("/mcp/mcp-secret/")
        self.assertEqual(response.status_code, 200)

    def test_a_wrong_capability_url_is_refused(self) -> None:
        response = self.client.get("/mcp/not-the-secret/")
        self.assertEqual(response.status_code, 401)

    def test_the_bare_capability_url_redirects_rather_than_404s(self) -> None:
        """It is the URL a person is handed, so pasting it exactly must work."""
        response = self.client.get("/mcp/mcp-secret", follow_redirects=False)
        self.assertEqual(response.status_code, 307)
        self.assertTrue(response.headers["location"].endswith("/mcp/mcp-secret/"))

    def test_no_mcp_endpoint_exists_when_no_token_is_configured(self) -> None:
        from pencil_in_the_loop_mcp.relay.app import create_app

        client = TestClient(
            create_app(sync_root=self.root, index=self.index, device_token=TOKEN)
        )
        self.assertEqual(client.get("/mcp/").status_code, 404)


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



@unittest.skipIf(TestClient is None, "starlette is not installed")
class ClipTests(RelayApiTestCase):
    """Upgrading a voice comment's transcript.

    Everything here is an upgrade over text the iPad already has, so the
    behaviour that matters most is what happens when it does not work: the
    draft must survive every failure path, and a retry must not need the
    keyterms sent again.
    """

    def setUp(self) -> None:
        super().setUp()
        from pencil_in_the_loop_mcp import transcribe

        self.transcribe = transcribe
        self.calls: list[dict] = []
        self._real = transcribe.transcribe

        def fake(audio, *, keyterms=None, language="en-GB", timeout=None):
            self.calls.append(
                {"audio": audio, "keyterms": keyterms, "language": language}
            )
            return transcribe.Transcript(
                text="Ofgem's RIIO-3 framework doesn't cover this.",
                model="nova-3",
                provider="deepgram",
            )

        transcribe.transcribe = fake
        self.addCleanup(setattr, transcribe, "transcribe", self._real)

    CLIP = "6C4F8E2A-0000-4000-8000-000000000001"

    def declare(self, clip_id=None, **extra):
        payload = {"clipId": clip_id or self.CLIP, **extra}
        return self.client.post("/v1/clips", json=payload, headers=self.auth)

    def upload(self, clip_id=None, audio=b"fLaC-not-really"):
        return self.client.put(
            f"/v1/clips/{clip_id or self.CLIP}/audio",
            content=audio,
            headers={**self.auth, "Content-Type": "audio/flac"},
        )

    def test_a_clip_is_declared_then_uploaded_and_comes_back_as_text(self) -> None:
        self.assertEqual(self.declare(keyterms=["Ofgem", "RIIO-3"]).status_code, 201)

        response = self.upload()

        self.assertEqual(response.status_code, 200)
        body = response.json()
        self.assertTrue(body["ok"])
        self.assertEqual(body["text"], "Ofgem's RIIO-3 framework doesn't cover this.")
        self.assertEqual(body["provider"], "deepgram")

    def test_the_documents_own_words_reach_the_provider(self) -> None:
        self.declare(keyterms=["Ofgem", "RIIO-3"], language="en-GB")

        self.upload()

        self.assertEqual(self.calls[0]["keyterms"], ["Ofgem", "RIIO-3"])
        self.assertEqual(
            self.calls[0]["language"],
            "en-GB",
            "Telling the model what the document is about is the whole point of the feature.",
        )

    def test_uploading_a_clip_nobody_declared_is_a_404(self) -> None:
        self.assertEqual(self.upload().status_code, 404)

    def test_a_clip_id_that_is_not_a_uuid_is_refused(self) -> None:
        self.assertEqual(self.declare(clip_id="../../etc/passwd").status_code, 400)

    def test_clips_need_the_device_token(self) -> None:
        self.assertEqual(self.client.post("/v1/clips", json={"clipId": self.CLIP}).status_code, 401)
        self.assertEqual(
            self.client.put(f"/v1/clips/{self.CLIP}/audio", content=b"x").status_code, 401
        )

    def test_no_provider_key_says_so_rather_than_failing_quietly(self) -> None:
        def unconfigured(audio, **kwargs):
            raise self.transcribe.TranscriptionUnconfigured("DEEPGRAM_API_KEY is not set")

        self.transcribe.transcribe = unconfigured
        self.declare()

        response = self.upload()

        self.assertEqual(response.status_code, 501)
        self.assertEqual(response.json()["error"], "not_configured")

    def test_a_provider_failure_keeps_the_declaration_so_a_retry_is_cheap(self) -> None:
        def failing(audio, **kwargs):
            raise self.transcribe.TranscriptionError("provider unreachable")

        self.transcribe.transcribe = failing
        self.declare(keyterms=["Ofgem"])

        self.assertEqual(self.upload().status_code, 502)

        # The keyterms were sent once and must not have to be sent again.
        self.transcribe.transcribe = lambda audio, **kw: self.transcribe.Transcript(
            text="second time", model="nova-3", provider="deepgram"
        )
        retry = self.upload()
        self.assertEqual(retry.status_code, 200)
        self.assertEqual(retry.json()["text"], "second time")

    def test_a_clip_never_appears_in_the_change_feed(self) -> None:
        self.declare()
        self.upload()

        feed = self.client.get("/v1/changes?since=0", headers=self.auth).json()

        self.assertEqual(
            feed.get("documents", []),
            [],
            "A clip is not a document; the feed is what the iPad pulls documents from.",
        )

if __name__ == "__main__":
    unittest.main()
