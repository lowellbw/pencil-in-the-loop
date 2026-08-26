"""Cloud speech-to-text, behind one interface.

The iPad's on-device transcript is a draft. This makes a better one from the
same audio, using a model that can be *told* what the document is about --
which is the whole point, per notes/pencil-loop-cloud-dictation.md: the words
that matter most in a review comment are names, statutes, acronyms and the
author's own coinages, and those are exactly the words a context-free model
gets wrong.

Providers churn and the interface should not, so everything below is
``transcribe(audio, keyterms, language) -> Transcript``. Standard library only,
like the rest of this package: a dependency that must be installed for the
relay to boot is a relay that does not boot.

The API key is read from the environment and never travels through the iPad.
"""

from __future__ import annotations

import json
import os
import urllib.error
import urllib.parse
import urllib.request
import uuid
from dataclasses import dataclass
from typing import Any

# Deepgram takes at most 100 keyterms; ElevenLabs is more generous. Ranked
# lists are truncated rather than rejected, so the most useful terms survive --
# which is why the caller ranks them (VoiceClip.keyterms).
MAX_KEYTERMS = 100

# A margin comment is seconds long. A minute of FLAC is comfortably under this,
# and anything larger is a bug rather than a comment.
MAX_AUDIO_BYTES = 25 * 1024 * 1024

DEFAULT_TIMEOUT_SECONDS = 60


class TranscriptionError(Exception):
    """The upgrade did not happen. The draft stands."""


class TranscriptionUnconfigured(TranscriptionError):
    """No provider key is set. Distinguished so the relay can say so once."""


@dataclass(frozen=True)
class Transcript:
    """What a provider gave back."""

    text: str
    model: str
    provider: str

    def as_dict(self) -> dict[str, Any]:
        return {"text": self.text, "model": self.model, "provider": self.provider}


def configured_provider() -> str | None:
    """Which provider the environment selects, or None.

    ``PENCIL_STT_PROVIDER`` wins when set; otherwise whichever key is present.
    Deepgram first: Nova-3 is the cheapest of the serious options, keyterm
    capable, and the design note's designated fallback -- which is the one we
    have a key for.
    """
    named = (os.environ.get("PENCIL_STT_PROVIDER") or "").strip().lower()
    if named:
        return named or None
    if os.environ.get("DEEPGRAM_API_KEY"):
        return "deepgram"
    if os.environ.get("ELEVENLABS_API_KEY") or os.environ.get("ELEVEN_API_KEY"):
        return "elevenlabs"
    if os.environ.get("OPENAI_API_KEY"):
        return "openai"
    return None


def transcribe(
    audio: bytes,
    *,
    keyterms: list[str] | None = None,
    language: str = "en-GB",
    timeout: float = DEFAULT_TIMEOUT_SECONDS,
) -> Transcript:
    """Turn one clip into text, with the document's vocabulary in hand.

    - Raises: ``TranscriptionUnconfigured`` when no key is set, and
      ``TranscriptionError`` for anything else. Both mean the same thing to the
      caller: keep the draft.
    """
    if not audio:
        raise TranscriptionError("no audio")
    if len(audio) > MAX_AUDIO_BYTES:
        raise TranscriptionError(f"clip is larger than {MAX_AUDIO_BYTES} bytes")

    provider = configured_provider()
    terms = _clean_keyterms(keyterms)
    if provider == "deepgram":
        return _deepgram(audio, terms, language, timeout)
    if provider in ("elevenlabs", "eleven"):
        return _elevenlabs(audio, terms, language, timeout)
    if provider == "openai":
        return _openai(audio, terms, language, timeout)
    if provider is None:
        raise TranscriptionUnconfigured(
            "no speech-to-text key is set; set DEEPGRAM_API_KEY or ELEVENLABS_API_KEY"
        )
    raise TranscriptionError(f"unknown provider {provider!r}")


def _clean_keyterms(keyterms: list[str] | None) -> list[str]:
    if not keyterms:
        return []
    cleaned: list[str] = []
    for term in keyterms:
        if not isinstance(term, str):
            continue
        value = " ".join(term.split())
        # Providers cap phrase length; a "term" that is a sentence is a term
        # that was extracted wrong.
        if value and len(value.split()) <= 6 and value not in cleaned:
            cleaned.append(value)
    return cleaned[:MAX_KEYTERMS]


# ------------------------------------------------------------------ Deepgram


def _deepgram(audio: bytes, keyterms: list[str], language: str, timeout: float) -> Transcript:
    key = os.environ.get("DEEPGRAM_API_KEY")
    if not key:
        raise TranscriptionUnconfigured("DEEPGRAM_API_KEY is not set")
    model = os.environ.get("PENCIL_STT_MODEL") or "nova-3"

    query = [
        ("model", model),
        ("language", language),
        ("punctuate", "true"),
        ("smart_format", "true"),
    ]
    # Nova-3's keyterm prompting. Repeated parameter, one per phrase.
    query.extend(("keyterm", term) for term in keyterms)
    url = "https://api.deepgram.com/v1/listen?" + urllib.parse.urlencode(query)

    body = _post(
        url,
        audio,
        {"Authorization": f"Token {key}", "Content-Type": "audio/flac"},
        timeout,
    )
    try:
        alternatives = body["results"]["channels"][0]["alternatives"]
        text = (alternatives[0].get("transcript") or "").strip()
    except (KeyError, IndexError, TypeError) as error:
        raise TranscriptionError(f"unexpected Deepgram response: {error}") from error
    if not text:
        raise TranscriptionError("Deepgram returned no text")
    return Transcript(text=text, model=model, provider="deepgram")


# ---------------------------------------------------------------- ElevenLabs


def _elevenlabs(audio: bytes, keyterms: list[str], language: str, timeout: float) -> Transcript:
    key = os.environ.get("ELEVENLABS_API_KEY") or os.environ.get("ELEVEN_API_KEY")
    if not key:
        raise TranscriptionUnconfigured("ELEVENLABS_API_KEY is not set")
    model = os.environ.get("PENCIL_STT_MODEL") or "scribe_v2"

    fields = {"model_id": model, "language_code": language.split("-")[0]}
    if keyterms:
        fields["keyterms"] = json.dumps(keyterms)
    payload, content_type = _multipart(fields, "file", "clip.flac", "audio/flac", audio)

    body = _post(
        "https://api.elevenlabs.io/v1/speech-to-text",
        payload,
        {"xi-api-key": key, "Content-Type": content_type},
        timeout,
    )
    text = (body.get("text") or "").strip()
    if not text:
        raise TranscriptionError("ElevenLabs returned no text")
    return Transcript(text=text, model=model, provider="elevenlabs")


# -------------------------------------------------------------------- OpenAI


def _openai(audio: bytes, keyterms: list[str], language: str, timeout: float) -> Transcript:
    """gpt-4o-transcribe, biased with a freeform prompt.

    Ranked third of the three on purpose, and the note says why: no keyterm API,
    only a freeform ``prompt``, and a knowledge cutoff that hurts on exactly the
    recent names a policy comment is full of. It is here because a key is here,
    and because a provider you can actually run beats one you cannot.

    The prompt is the documented way to bias this model. It is a hint about
    spelling, not an instruction — the model is transcribing audio, and anything
    that reads as a command belongs in a cleanup pass instead.
    """
    key = os.environ.get("OPENAI_API_KEY")
    if not key:
        raise TranscriptionUnconfigured("OPENAI_API_KEY is not set")
    model = os.environ.get("PENCIL_STT_MODEL") or "gpt-4o-transcribe"

    fields = {"model": model, "language": language.split("-")[0], "response_format": "json"}
    if keyterms:
        # Comma-separated is the shape OpenAI's own guidance uses for spelling
        # hints. Capped well under the prompt limit by MAX_KEYTERMS.
        fields["prompt"] = "Terms that may appear: " + ", ".join(keyterms) + "."
    payload, content_type = _multipart(fields, "file", "clip.flac", "audio/flac", audio)

    body = _post(
        "https://api.openai.com/v1/audio/transcriptions",
        payload,
        {"Authorization": f"Bearer {key}", "Content-Type": content_type},
        timeout,
    )
    text = (body.get("text") or "").strip()
    if not text:
        raise TranscriptionError("OpenAI returned no text")
    return Transcript(text=text, model=model, provider="openai")


# --------------------------------------------------------------------- HTTP


def _post(url: str, payload: bytes, headers: dict[str, str], timeout: float) -> dict[str, Any]:
    request = urllib.request.Request(url, data=payload, headers=headers, method="POST")
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            raw = response.read()
    except urllib.error.HTTPError as error:
        detail = ""
        try:
            detail = error.read().decode("utf-8", "replace")[:200]
        except Exception:  # pragma: no cover - the error body is a courtesy
            detail = ""
        raise TranscriptionError(f"provider returned {error.code}: {detail}") from error
    except (urllib.error.URLError, TimeoutError, OSError) as error:
        # Unreachable, timed out, DNS, a captive portal lying about the
        # network -- all the same to the caller, which retries later.
        raise TranscriptionError(f"provider unreachable: {error}") from error
    try:
        return json.loads(raw)
    except ValueError as error:
        raise TranscriptionError("provider returned something that is not JSON") from error


def _multipart(
    fields: dict[str, str],
    file_field: str,
    filename: str,
    file_type: str,
    file_bytes: bytes,
) -> tuple[bytes, str]:
    """One multipart/form-data body, by hand.

    By hand because the alternative is a dependency, and this package's whole
    posture is that the relay boots with nothing installed but Starlette.
    """
    boundary = "----pencil-loop-" + uuid.uuid4().hex
    parts: list[bytes] = []
    for name, value in fields.items():
        parts.append(f"--{boundary}\r\n".encode())
        parts.append(f'Content-Disposition: form-data; name="{name}"\r\n\r\n'.encode())
        parts.append(value.encode("utf-8") + b"\r\n")
    parts.append(f"--{boundary}\r\n".encode())
    parts.append(
        f'Content-Disposition: form-data; name="{file_field}"; filename="{filename}"\r\n'.encode()
    )
    parts.append(f"Content-Type: {file_type}\r\n\r\n".encode())
    parts.append(file_bytes + b"\r\n")
    parts.append(f"--{boundary}--\r\n".encode())
    return b"".join(parts), f"multipart/form-data; boundary={boundary}"
