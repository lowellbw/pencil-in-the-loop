"""The relay's HTTP surface: the same sync root, reachable from anywhere.

**The wire format is the file format.** `meta.json`, `review.json` and
`manifest.json` are stored byte-verbatim and served back as they are, so this
module specifies only envelopes, cursors and status codes —
`docs/05-file-contracts.md` remains the contract, and nothing here forks it.

Two shapes worth understanding before editing:

**Declare, then upload.** A document or a review announces its files first and
uploads them one at a time. That is why the staging directory has to outlive
the request that created it. It gives resumability on a bad connection, keeps a
100MB PDF off the heap, and needs no multipart parser on either side — the iPad
has no third-party dependencies and would have to hand-roll boundaries.

**Handlers that touch the filesystem are plain `def`, not `async def`.**
Starlette runs sync handlers in a threadpool; `core.py` is blocking stdlib I/O,
and putting it inside an `async def` would stall every concurrent poll on one
document's fsync. Only the streaming upload and download handlers are `async`,
because those genuinely do want the event loop.
"""

from __future__ import annotations

import hmac
import io
import json
import tarfile
from contextlib import asynccontextmanager
from pathlib import Path
from typing import Any, Awaitable, Callable

from starlette.applications import Starlette
from starlette.datastructures import Headers
from starlette.middleware import Middleware
from starlette.middleware.base import BaseHTTPMiddleware
from starlette.requests import Request
from starlette.responses import (
    FileResponse,
    JSONResponse,
    RedirectResponse,
    Response,
    StreamingResponse,
)
from starlette.concurrency import run_in_threadpool
from starlette.routing import Mount, Route

from .. import cleanup
from .. import core
from .. import transcribe
from . import files as relay_files
from .db import Index

CHANGES_PAGE_LIMIT = 100


class ApiError(Exception):
    """An error with a code the client switches on and a sentence for a person.

    The code is the contract; the message is for a log or a status line. The
    iPad maps codes onto states it already models — `.folderUnavailable` for
    anything retryable, `.outboxWriteFailed` for anything that is our fault and
    will not fix itself.
    """

    def __init__(self, status: int, code: str, message: str) -> None:
        super().__init__(message)
        self.status = status
        self.code = code
        self.message = message

    def response(self) -> JSONResponse:
        return JSONResponse(
            {"error": self.code, "message": self.message}, status_code=self.status
        )


def json_error(status: int, code: str, message: str) -> ApiError:
    return ApiError(status, code, message)


# ------------------------------------------------------------------- helpers


def _require_token(request: Request, expected: str) -> None:
    """Bearer auth, compared in constant time.

    A single shared secret, because there is one identity. If a second person
    ever uses this, tokens become per-user and bundle ids become unguessable in
    the *same* change — a `get_review` that can read another tenant's review is
    the classic confused deputy, and it is much cheaper to prevent than to find.
    """
    header = request.headers.get("authorization", "")
    scheme, _, value = header.partition(" ")
    if scheme.lower() != "bearer" or not value:
        raise ApiError(401, "unauthorized", "A bearer token is required.")
    if not hmac.compare_digest(value, expected):
        raise ApiError(401, "unauthorized", "That token is not valid for this relay.")


def _declared_length(headers: Headers, limit: int, what: str) -> int:
    """The size gate, applied before a single byte is read off the socket.

    A container with 512MB of RAM cannot afford to learn a body is too large by
    receiving it.
    """
    raw = headers.get("content-length")
    if raw is None:
        raise ApiError(411, "length_required", f"{what} must declare Content-Length.")
    try:
        length = int(raw)
    except ValueError as error:
        raise ApiError(400, "bad_length", f"Content-Length is not a number.") from error
    if length < 0 or length > limit:
        raise ApiError(
            413,
            "too_large",
            f"{what} is {length} bytes, over the {limit} byte limit.",
        )
    return length


def _check_room(root: Path, length: int) -> None:
    if not relay_files.has_room_for(root, length):
        raise ApiError(
            507,
            "insufficient_storage",
            "The relay's volume is nearly full. Nothing was written.",
        )


async def _json_body(request: Request) -> dict[str, Any]:
    _declared_length(request.headers, relay_files.MAX_JSON_BODY_BYTES, "The body")
    raw = await request.body()
    try:
        parsed = json.loads(raw)
    except ValueError as error:
        raise ApiError(400, "bad_json", "The body is not valid JSON.") from error
    if not isinstance(parsed, dict):
        raise ApiError(400, "bad_json", "The body must be a JSON object.")
    return parsed


def _folder(request: Request) -> str:
    try:
        return relay_files.bundle_id(request.path_params["folderName"])
    except core.ValidationError as error:
        raise ApiError(400, "bad_folder_name", str(error)) from error


# ------------------------------------------------------------------ the app


def create_app(
    *,
    sync_root: Path,
    index: Index,
    device_token: str,
    mcp_app: Any = None,
    mcp_token: str | None = None,
) -> Starlette:
    """Build the relay.

    - Parameter mcp_app: an ASGI app to mount at `/mcp`, so the MCP server and
      this API are one deployment over one storage layer. Optional so the API
      can be built and tested without the MCP SDK installed.
    """
    root = Path(sync_root)
    inbox = root / "inbox"
    outbox = root / "outbox"
    root.mkdir(parents=True, exist_ok=True)

    # ------------------------------------------------------------- documents

    def post_document(request: Request) -> Response:
        body = request.state.body
        expected = body.get("expectedFiles") or []
        if not isinstance(expected, list):
            raise ApiError(400, "bad_request", "expectedFiles must be an array.")

        # Two shapes of document, and the difference is whether there is any
        # markdown. A PDF arrives as `document.pdf` and a title, with no
        # source.md — which docs/05 has always allowed and nothing could
        # previously produce.
        source_md: str | None = None
        try:
            if body.get("content") is None and body.get("sourceFormat") == "pdf":
                base, meta = core.prepare_pdf_bundle(
                    title=body.get("title"),
                    tags=body.get("tags"),
                    group=body.get("group"),
                    origin_kind=body.get("originKind"),
                    session_id=body.get("sessionId"),
                    thread_title=body.get("threadTitle"),
                    source_url=body.get("sourceURL"),
                    document_id=body.get("documentId"),
                )
            else:
                base, meta, source_md = core.prepare_inbox_bundle(
                    content=body.get("content"),
                    title=body.get("title"),
                    tags=body.get("tags"),
                    group=body.get("group"),
                    origin_kind=body.get("originKind"),
                    session_id=body.get("sessionId"),
                    thread_title=body.get("threadTitle"),
                    document_id=body.get("documentId"),
                )
        except core.ValidationError as error:
            raise ApiError(400, "invalid_input", str(error)) from error

        # A trigger id fires a turn into someone's conversation, so it does not
        # belong on a server — and it has no meaning here anyway, because the
        # return path over the relay is the MCP connection.
        meta = relay_files.strip_return_path_secrets(meta)

        existing = index.document_by_id(meta["id"])
        if existing is not None:
            return JSONResponse(
                {
                    "folderName": existing.folder_name,
                    "documentId": existing.document_id,
                    "seq": existing.seq,
                    "complete": existing.complete,
                    "missingFiles": index.missing_files(existing.folder_name),
                    "idempotent": True,
                },
                status_code=200,
            )

        declared: list[dict[str, Any]] = []
        for entry in expected:
            if not isinstance(entry, dict):
                raise ApiError(400, "bad_request", "Each expectedFile is an object.")
            try:
                name = relay_files.validate_document_file(entry.get("name"))
                size = relay_files.check_declared_size(name, entry.get("bytes"))
            except relay_files.FileRejected as error:
                raise ApiError(400, "bad_file", str(error)) from error
            if name in ("meta.json", "source.md"):
                continue  # written below; declaring them changes nothing
            declared.append({"name": name, "bytes": size, "sha256": entry.get("sha256")})

        staging = core.stage_bundle(inbox, base)
        try:
            if source_md is not None:
                core.write_file(staging / "source.md", source_md)
            core.write_file(
                staging / "meta.json",
                json.dumps(meta, indent=2, ensure_ascii=False) + "\n",
            )
            # Size and hash are recorded for the files written here too, not
            # just the uploaded ones. The iPad verifies every download against
            # what the feed advertised, and a null hash would quietly turn that
            # check off for exactly the files every document has.
            names = ["meta.json"] if source_md is None else ["source.md", "meta.json"]
            written = [
                {
                    "name": name,
                    "present": True,
                    "bytes": (staging / name).stat().st_size,
                    "sha256": relay_files.sha256_of(staging / name),
                }
                for name in names
            ]
            folder_name = index.reserve_document(
                base=base,
                document_id=meta["id"],
                title=meta.get("title"),
                created_at=meta.get("createdAt"),
                origin_kind=(meta.get("origin") or {}).get("kind"),
                staging_path=staging,
                expected_files=written + declared,
                inbox=inbox,
            )
        except Exception:
            core.discard_bundle(staging)
            raise

        missing = index.missing_files(folder_name)
        if not missing:
            relay_files.commit_to(staging, inbox / folder_name)
            index.complete_document(folder_name)

        return JSONResponse(
            {
                "folderName": folder_name,
                "documentId": meta["id"],
                "title": meta["title"],
                "createdAt": meta["createdAt"],
                "origin": meta["origin"],
                "seq": index.document(folder_name).seq,
                "complete": not missing,
                "missingFiles": missing,
            },
            status_code=201,
        )

    async def put_document_file(request: Request) -> Response:
        folder_name = _folder(request)
        try:
            name = relay_files.validate_document_file(request.path_params["name"])
        except relay_files.FileRejected as error:
            raise ApiError(400, "bad_file", str(error)) from error

        row = index.document(folder_name)
        if row is None:
            raise ApiError(404, "not_found", f"No document named {folder_name}.")

        length = _declared_length(
            request.headers, relay_files.max_bytes_for(name), name
        )
        _check_room(root, length)

        staging = index.staging_path(folder_name)
        directory = staging if staging is not None else (inbox / folder_name)
        if not directory.is_dir():
            raise ApiError(404, "not_found", f"No document named {folder_name}.")

        written, digest = await relay_files.write_stream_async(
            request.stream(), directory / name
        )
        if written != length:
            raise ApiError(
                400,
                "short_body",
                f"{name}: declared {length} bytes, received {written}.",
            )
        index.mark_file_present(
            folder_name, name, byte_count=written, sha256=digest
        )

        missing = index.missing_files(folder_name)
        if not missing and staging is not None:
            relay_files.commit_to(staging, inbox / folder_name)
            index.complete_document(folder_name)

        return JSONResponse(
            {"complete": not missing, "missingFiles": missing, "sha256": digest}
        )

    # ----------------------------------------------------------- groups
    #
    # Which group each document should be filed under, as one map the device
    # adopts on its next poll. This is what lets a sender file a document it
    # sent last week, which `group` in meta.json cannot: that is read once, at
    # ingest, and a document already in the library never sees it again.
    #
    # The device still decides. It files a document that has no group and never
    # overrides one the reader chose by hand — the same rule, in the same words,
    # as `DocumentGrouping.adoptGroupName`.

    def get_groups(request: Request) -> Response:
        return JSONResponse({"assignments": core.read_group_map(root)})

    async def put_groups(request: Request) -> Response:
        body = await _json_body(request)
        assignments = body.get("assignments")
        if not isinstance(assignments, dict):
            raise ApiError(400, "invalid_input", "assignments must be an object.")
        for folder, group in assignments.items():
            if not isinstance(folder, str) or not isinstance(group, str):
                raise ApiError(400, "invalid_input", "assignments must map strings to strings.")
            try:
                relay_files.bundle_id(folder)
            except core.ValidationError as error:
                raise ApiError(400, "bad_folder_name", str(error)) from error
        merged = core.write_group_map(root, assignments)
        return JSONResponse({"assignments": merged, "count": len(merged)})

    # ------------------------------------------------------------ clips
    #
    # A voice comment is transcribed on the iPad first, so there is always text
    # (notes/pencil-loop-cloud-dictation.md). These two routes exist to make a
    # better one from the same audio, using a model that can be told what the
    # document is about. Everything here is an upgrade: every failure path
    # leaves the iPad's draft standing, which is why none of them is loud.
    #
    # Declare-then-upload, like documents, and for a different reason: the
    # keyterm list is up to a hundred phrases and does not belong in a URL.

    async def post_clip(request: Request) -> Response:
        body = await _json_body(request)
        try:
            clip_id = relay_files.clip_id(body.get("clipId"))
        except core.ValidationError as error:
            raise ApiError(400, "bad_clip_id", str(error)) from error

        keyterms = body.get("keyterms") or []
        if not isinstance(keyterms, list):
            raise ApiError(400, "invalid_input", "keyterms must be a list of strings.")
        language = body.get("language") or "en-GB"
        if not isinstance(language, str):
            raise ApiError(400, "invalid_input", "language must be a string.")

        clips = root / relay_files.CLIPS_DIRECTORY
        clips.mkdir(parents=True, exist_ok=True)
        core.write_file(
            clips / f"{clip_id}.json",
            json.dumps(
                {"clipId": clip_id, "language": language, "keyterms": keyterms},
                ensure_ascii=False,
            ),
        )
        return JSONResponse({"clipId": clip_id}, status_code=201)

    async def put_clip_audio(request: Request) -> Response:
        try:
            clip_id = relay_files.clip_id(request.path_params["clipId"])
        except core.ValidationError as error:
            raise ApiError(400, "bad_clip_id", str(error)) from error

        clips = root / relay_files.CLIPS_DIRECTORY
        declared = clips / f"{clip_id}.json"
        if not declared.is_file():
            raise ApiError(404, "not_found", f"No clip declared as {clip_id}.")

        length = _declared_length(request.headers, transcribe.MAX_AUDIO_BYTES, "The clip")
        _check_room(root, length)
        audio = await request.body()
        if len(audio) != length:
            raise ApiError(
                400,
                "short_body",
                f"the clip declared {length} bytes, received {len(audio)}.",
            )

        meta = core.read_json_file(declared) or {}

        # Blocking, on purpose, and safe: Starlette runs the provider call in a
        # worker thread, the iPad is draining a background queue and is not
        # waiting on a person, and one request per comment is not a load. It
        # also means no job store and nothing to poll.
        try:
            result = await run_in_threadpool(
                transcribe.transcribe,
                audio,
                keyterms=meta.get("keyterms") or [],
                language=meta.get("language") or "en-GB",
            )
        except transcribe.TranscriptionUnconfigured as error:
            declared.unlink(missing_ok=True)
            raise ApiError(501, "not_configured", str(error)) from error
        except transcribe.TranscriptionError as error:
            # Left declared so a retry can re-upload without re-declaring.
            raise ApiError(502, "provider_failed", str(error)) from error

        # Stage 3: correct the transcript against the document's own words. It
        # never raises and never returns something worse than the ASR gave —
        # a refused cleanup is the raw text, with a reason — so it is not
        # wrapped in a try. See cleanup.polish.
        polished = await run_in_threadpool(
            cleanup.polish,
            result.text,
            keyterms=meta.get("keyterms") or [],
        )

        declared.unlink(missing_ok=True)
        return JSONResponse({"ok": True, **result.as_dict(), **polished.as_dict()})

    def get_changes(request: Request) -> Response:
        try:
            since = int(request.query_params.get("since", "0"))
        except ValueError as error:
            raise ApiError(400, "bad_cursor", "since must be an integer.") from error

        # Take in anything written straight to the volume since the last poll —
        # the MCP tools write bundles the same way the folder transport does,
        # and without this they would be invisible to every device.
        index.reconcile(root)

        rows = index.changes_since(since, CHANGES_PAGE_LIMIT)
        replies = index.replies_since(since)
        cursor = max(
            [since]
            + [row.seq for row in rows]
            + [reply["seq"] for reply in replies]
        )
        payload = {
            "epoch": index.epoch,
            "cursor": cursor,
            "hasMore": len(rows) == CHANGES_PAGE_LIMIT,
            "documents": [row.as_feed_entry() for row in rows],
            "replies": replies,
        }
        etag = f'W/"{index.epoch}:{cursor}"'
        if request.headers.get("if-none-match") == etag:
            return Response(status_code=304, headers={"ETag": etag})
        return JSONResponse(payload, headers={"ETag": etag})

    def get_document_file(request: Request) -> Response:
        folder_name = _folder(request)
        try:
            name = relay_files.validate_document_file(request.path_params["name"])
        except relay_files.FileRejected as error:
            raise ApiError(400, "bad_file", str(error)) from error

        path = inbox / folder_name / name
        if not path.is_file():
            raise ApiError(404, "not_found", f"{folder_name}/{name} is not here.")
        return FileResponse(
            path,
            headers={"ETag": f'"{relay_files.sha256_of(path)}"'},
        )

    def delete_document(request: Request) -> Response:
        folder_name = _folder(request)
        if index.document(folder_name) is None:
            raise ApiError(404, "not_found", f"No document named {folder_name}.")
        import shutil as _shutil

        _shutil.rmtree(inbox / folder_name, ignore_errors=True)
        seq = index.delete_document(folder_name)
        return JSONResponse({"folderName": folder_name, "seq": seq})

    # --------------------------------------------------------------- reviews

    def post_review(request: Request) -> Response:
        folder_name = _folder(request)
        body = request.state.body

        manifest = body.get("manifest")
        try:
            entries = relay_files.manifest_entries(manifest)
        except relay_files.FileRejected as error:
            raise ApiError(400, "bad_manifest", str(error)) from error

        manifest_bytes = json.dumps(manifest, sort_keys=True).encode()
        import hashlib as _hashlib

        manifest_sha = _hashlib.sha256(manifest_bytes).hexdigest()

        # The iPad's outbox queue retries on every poll, so a re-delivery of a
        # bundle that already landed must change nothing at all.
        previous = index.review(folder_name)
        if (
            previous
            and previous["manifest_sha"] == manifest_sha
            and previous["complete"]
        ):
            return JSONResponse(
                {
                    "folderName": folder_name,
                    "revision": int(previous["revision"]),
                    "idempotent": True,
                    "complete": True,
                    "missingFiles": [],
                },
                status_code=200,
            )

        # A re-declared bundle that never finished starts its upload again, so
        # any half-filled staging directory from the last attempt is dropped.
        stale = index.review_staging_path(folder_name)
        if stale is not None:
            core.discard_bundle(stale)

        staging = core.stage_bundle(outbox, f"{folder_name}.review")
        try:
            # **Only manifest.json is written here, and only because it is the
            # one file the manifest does not hash.**
            #
            # Every other file arrives as raw bytes through PUT. The server
            # writing them from JSON was a 422 on every review that carried a
            # review.json: the device hashes what *it* wrote — sorted keys,
            # its own spacing — and `json.dumps` here produced different bytes
            # for the same object, so verification could not pass. A parts list
            # is only worth having if the parts are the ones that were counted.
            core.write_file(
                staging / "manifest.json",
                json.dumps(manifest, indent=2, ensure_ascii=False) + "\n",
            )
        except Exception:
            core.discard_bundle(staging)
            raise

        revision, _ = index.record_review(
            folder_name=folder_name,
            document_id=manifest.get("documentId"),
            manifest_sha=manifest_sha,
            reviewed_at=manifest.get("createdAt"),
            staging_path=staging,
            expected_files=entries,
        )
        missing = index.missing_review_files(folder_name)
        if not missing:
            _finish_review(folder_name, staging, entries)

        return JSONResponse(
            {
                "folderName": folder_name,
                "revision": revision,
                "complete": not missing,
                "missingFiles": missing,
            },
            status_code=201,
        )

    def _finish_review(
        folder_name: str, staging: Path, entries: list[dict[str, Any]]
    ) -> None:
        """Verify against the manifest, then land the bundle with one rename.

        This is where `manifest.json` earns its place: the parts list is checked
        before anything becomes visible, so a bundle is complete or absent and
        never partially readable. The folder transport could not promise that —
        `docs/05` notes the rename guarantee "does not survive the sync hop".
        """
        try:
            relay_files.verify_against_manifest(staging, entries)
        except relay_files.FileRejected as error:
            raise ApiError(422, "manifest_mismatch", str(error)) from error

        target = outbox / f"{folder_name}.review"
        if target.exists():
            revisions = outbox / ".revisions"
            revisions.mkdir(parents=True, exist_ok=True)
            row = index.review(folder_name) or {}
            previous = int(row.get("revision", 1))
            target.rename(revisions / f"{folder_name}.review.{previous - 1 or 1}")
        relay_files.commit_to(staging, target)
        index.complete_review(folder_name)

    async def put_review_file(request: Request) -> Response:
        folder_name = _folder(request)
        try:
            name = relay_files.validate_review_file(request.path_params["path"])
        except relay_files.FileRejected as error:
            raise ApiError(400, "bad_file", str(error)) from error

        staging = index.review_staging_path(folder_name)
        if staging is None or not staging.is_dir():
            raise ApiError(
                404, "not_found", f"No review bundle in flight for {folder_name}."
            )

        length = _declared_length(
            request.headers, relay_files.MAX_OTHER_FILE_BYTES, name
        )
        _check_room(root, length)

        written, digest = await relay_files.write_stream_async(
            request.stream(), staging / name
        )
        index.mark_review_file_present(
            folder_name, name, byte_count=written, sha256=digest
        )

        entries = relay_files.manifest_entries(
            core.read_json_file(staging / "manifest.json")
        )
        missing = index.missing_review_files(folder_name)
        if not missing:
            _finish_review(folder_name, staging, entries)
        return JSONResponse({"complete": not missing, "missingFiles": missing})

    def get_reviews(request: Request) -> Response:
        return JSONResponse(
            {"ok": True, "reviews": core.list_review_bundles(root)}
        )

    def get_review(request: Request) -> Response:
        folder_name = _folder(request)
        try:
            return JSONResponse(core.read_review(root, folder_name))
        except FileNotFoundError as error:
            raise ApiError(404, "not_found", str(error)) from error

    def get_review_file(request: Request) -> Response:
        folder_name = _folder(request)
        try:
            name = relay_files.validate_review_file(request.path_params["path"])
        except relay_files.FileRejected as error:
            raise ApiError(400, "bad_file", str(error)) from error
        path = outbox / f"{folder_name}.review" / name
        if not path.is_file():
            raise ApiError(404, "not_found", f"{folder_name}/{name} is not here.")
        return FileResponse(path)

    async def put_reply(request: Request) -> Response:
        folder_name = _folder(request)
        bundle = outbox / f"{folder_name}.review"
        if not bundle.is_dir():
            raise ApiError(404, "not_found", f"No review bundle for {folder_name}.")
        length = _declared_length(
            request.headers, relay_files.MAX_OTHER_FILE_BYTES, "reply.md"
        )
        _check_room(root, length)
        written, _ = await relay_files.write_stream_async(
            request.stream(), bundle / "reply.md"
        )
        seq = index.set_reply(folder_name, has_reply=True)
        return JSONResponse({"folderName": folder_name, "bytes": written, "seq": seq})

    # ------------------------------------------------------------------- ops

    def healthz(request: Request) -> Response:
        try:
            free = relay_files.free_bytes(root)
        except OSError:
            free = -1
        return JSONResponse(
            {
                "ok": True,
                "epoch": index.epoch,
                "cursor": index.cursor,
                "bytesFree": free,
            }
        )

    def export_tar(request: Request) -> Response:
        """The whole sync root as a tarball.

        The single endpoint that makes "one Railway volume is the only copy" not
        a frightening sentence, and it is also the migration path: untar it into
        a Dropbox folder and the folder transport picks up exactly where the
        relay left off.
        """

        def stream() -> Any:
            buffer = io.BytesIO()
            with tarfile.open(fileobj=buffer, mode="w") as archive:
                for directory in (inbox, outbox):
                    if directory.is_dir():
                        archive.add(directory, arcname=directory.name)
            buffer.seek(0)
            yield buffer.read()

        return StreamingResponse(
            stream(),
            media_type="application/x-tar",
            headers={"Content-Disposition": 'attachment; filename="pencil-loop.tar"'},
        )

    # ---------------------------------------------------------------- wiring

    routes = [
        Route("/healthz", healthz, methods=["GET"]),
        Route("/v1/export.tar", export_tar, methods=["GET"]),
        Route("/v1/changes", get_changes, methods=["GET"]),
        Route("/v1/documents", post_document, methods=["POST"]),
        Route("/v1/groups", get_groups, methods=["GET"]),
        Route("/v1/groups", put_groups, methods=["PUT"]),
        Route("/v1/clips", post_clip, methods=["POST"]),
        Route("/v1/clips/{clipId}/audio", put_clip_audio, methods=["PUT"]),
        Route("/v1/documents/{folderName}", delete_document, methods=["DELETE"]),
        Route(
            "/v1/documents/{folderName}/files/{name}",
            put_document_file,
            methods=["PUT"],
        ),
        Route(
            "/v1/documents/{folderName}/files/{name}",
            get_document_file,
            methods=["GET"],
        ),
        Route("/v1/documents/{folderName}/review", post_review, methods=["POST"]),
        Route("/v1/reviews", get_reviews, methods=["GET"]),
        Route("/v1/reviews/{folderName}", get_review, methods=["GET"]),
        Route("/v1/reviews/{folderName}/reply", put_reply, methods=["PUT"]),
        Route(
            "/v1/reviews/{folderName}/files/{path:path}",
            put_review_file,
            methods=["PUT"],
        ),
        Route(
            "/v1/reviews/{folderName}/files/{path:path}",
            get_review_file,
            methods=["GET"],
        ),
    ]

    capability_prefix = f"/mcp/{mcp_token}" if (mcp_app and mcp_token) else None

    if mcp_app is not None:
        if capability_prefix:
            # Claude Desktop's custom-connector UI takes a URL, not a static
            # header, so the secret has to live in the path there. Weaker than a
            # header — it lands in the connector config and in any access log
            # that records paths, which is why uvicorn's access log is off — and
            # accepted deliberately for one person's tool rather than building
            # an OAuth provider to avoid it.
            #
            # A Mount only matches when something follows its prefix, so the
            # bare URL needs a redirect of its own. Without it, pasting the URL
            # exactly as given would 404 — and that is the URL a person is
            # handed.
            routes.append(
                Route(
                    capability_prefix,
                    lambda request: RedirectResponse(
                        f"{capability_prefix}/", status_code=307
                    ),
                    methods=["GET", "POST", "DELETE"],
                )
            )
            routes.append(Mount(capability_prefix, app=mcp_app))
        routes.append(Mount("/mcp", app=mcp_app))

    async def guard(
        request: Request, call_next: Callable[..., Awaitable[Response]]
    ) -> Response:
        """Auth, body parsing and error shaping, in one place.

        Bodies are read here rather than in each handler because the handlers
        that touch the filesystem are plain `def` functions running in a
        threadpool, and a sync function cannot await a request body.
        """
        path = request.url.path
        try:
            if path.startswith("/v1/"):
                _require_token(request, device_token)
                if request.method == "POST":
                    request.state.body = await _json_body(request)
            elif path.startswith("/mcp"):
                # The capability URL carries the secret in the path, so a
                # request that already matched it is authenticated by having
                # found it. Every other /mcp request must present the token as
                # a header — Claude Code can, and the endpoint would otherwise
                # be wide open, which is a much worse failure than an awkward
                # URL.
                if not (capability_prefix and path.startswith(capability_prefix)):
                    if not mcp_token:
                        raise ApiError(404, "not_found", "No MCP endpoint here.")
                    _require_token(request, mcp_token)
            return await call_next(request)
        except ApiError as error:
            return error.response()

    @asynccontextmanager
    async def lifespan(_: Starlette):
        """Run the mounted MCP app's lifespan alongside ours.

        Starlette does not propagate lifespan into a mounted sub-app, and the
        MCP streamable-HTTP transport starts its session task group there — so
        without this every MCP request fails with "Task group is not
        initialized", at runtime, on a route that looks correctly wired.
        """
        if mcp_app is None:
            yield
            return
        async with mcp_app.router.lifespan_context(mcp_app):
            yield

    app = Starlette(
        lifespan=lifespan,
        routes=routes,
        middleware=[Middleware(BaseHTTPMiddleware, dispatch=guard)],
        # An ApiError raised inside an endpoint is shaped here; the middleware
        # above catches the ones raised before routing (auth, body parsing).
        exception_handlers={ApiError: lambda request, error: error.response()},
    )
    app.state.index = index
    app.state.sync_root = root
    return app
