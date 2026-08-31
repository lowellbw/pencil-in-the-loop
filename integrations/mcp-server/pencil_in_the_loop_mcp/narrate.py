"""Turn a document into something you can listen to.

Two stages, and the first is where the product lives.

**Stage one writes a script.** Not the document read aloud — a version of it
made for the ear: every section covered in the document's own order, the
argument and the numbers kept, the apparatus dropped. Two hosts, because a
handover at a genuine turn in the argument is easier to follow than forty
minutes of one voice, and because it is what makes this listenable rather than
merely audible.

**Stage two speaks it.** Per turn, with the neighbouring turns passed as
`previous_text` / `next_text` so the joins carry prosody rather than sounding
spliced — that parameter pair is why this can chunk a long script at all.

The failure this feature would actually have is quiet: a narration that sounds
fluent and has silently dropped the third section. That is why the prompt says
*cover every section* first and why the first test asserts heading coverage.

Standard library only, like everything else here. Keys come from the
environment and never reach the iPad.
"""

from __future__ import annotations

import json
import os
import re
from dataclasses import dataclass
from typing import Any

from .transcribe import TranscriptionError, TranscriptionUnconfigured, _multipart, _post

# How long the audio should be, as a share of how long the document takes to
# read. All three cover the whole document; they differ in how much detail
# survives, not in what gets skipped.
DEPTHS = {"brief": 0.25, "standard": 0.5, "deep": 0.75}
DEFAULT_DEPTH = "standard"

# Reading is faster than listening. Both numbers are conventional and only ever
# used to turn a word count into a target, so precision would be false.
READING_WORDS_PER_MINUTE = 220
SPEAKING_WORDS_PER_MINUTE = 150

# A document this long is a book, and a narration of it is not the feature.
MAX_SOURCE_CHARS = 400_000

# Per-request ceiling for the speech model. `eleven_multilingual_v2` takes
# 10,000 and is documented as the most stable on long-form; a turn should never
# come close, and one that does is split.
MAX_TURN_CHARS = 4_000

#: How many times the script may be asked for again when it drops sections.
#: A backstop, not the usual stopping point — the loop ends as soon as a pass
#: stops improving coverage, which on real documents is what happens first.
MAX_REPAIRS = 3

HOST, GUEST = "host", "guest"


class NarrationError(Exception):
    """No narration was made. There is still a document to read."""


class NarrationUnconfigured(NarrationError):
    """No key is set. Distinguished so the relay can say so once, and not retry."""


@dataclass(frozen=True)
class Turn:
    """One speaker's stretch of the script."""

    speaker: str
    text: str


@dataclass(frozen=True)
class Narration:
    """What came back, and enough about it to say so."""

    audio: bytes
    turns: list[Turn]
    minutes: float
    script_model: str
    voice_model: str
    provider: str

    """Headings from the document the script never mentions.

    Empty is the expected answer. This is the one failure worth measuring
    rather than hoping about: a narration that sounds fluent and has quietly
    dropped a section is indistinguishable from a good one until you go looking
    for what is not there.
    """
    missed_sections: list[str]

    def as_dict(self) -> dict[str, Any]:
        return {
            "minutes": round(self.minutes, 1),
            "turns": len(self.turns),
            "bytes": len(self.audio),
            "scriptModel": self.script_model,
            "voiceModel": self.voice_model,
            "provider": self.provider,
            "missedSections": self.missed_sections,
        }


# ------------------------------------------------------------------- config


def voice_provider() -> str | None:
    """Which speech provider the environment selects, or None."""
    named = (os.environ.get("PENCIL_TTS_PROVIDER") or "").strip().lower()
    if named:
        return named
    if os.environ.get("ELEVENLABS_API_KEY") or os.environ.get("ELEVEN_API_KEY"):
        return "elevenlabs"
    if os.environ.get("OPENAI_API_KEY"):
        return "openai"
    return None


def is_configured() -> bool:
    """Whether a narration can be made at all: a script model and a voice."""
    return bool(os.environ.get("OPENAI_API_KEY")) and voice_provider() is not None


# -------------------------------------------------------------------- entry


def narrate(
    markdown: str,
    *,
    title: str = "",
    depth: str = DEFAULT_DEPTH,
    hosts: int = 2,
    timeout: float = 120.0,
) -> Narration:
    """Script the document, then speak it.

    - Raises: ``NarrationUnconfigured`` when no key is set, ``NarrationError``
      for anything else. Both mean the same thing to the caller: there is no
      audio, and the document is unaffected.
    """
    body = (markdown or "").strip()
    if not body:
        raise NarrationError("nothing to narrate")
    if len(body) > MAX_SOURCE_CHARS:
        raise NarrationError(f"document is longer than {MAX_SOURCE_CHARS} characters")
    if depth not in DEPTHS:
        raise NarrationError(f"depth must be one of {sorted(DEPTHS)}")
    if not os.environ.get("OPENAI_API_KEY"):
        raise NarrationUnconfigured("OPENAI_API_KEY is not set; it writes the script")

    turns, script_model = write_script(
        body, title=title, depth=depth, hosts=hosts, timeout=timeout
    )
    if not turns:
        raise NarrationError("the script came back empty")

    audio, voice_model, provider = speak(turns, timeout=timeout)
    words = sum(len(turn.text.split()) for turn in turns)
    return Narration(
        audio=audio,
        turns=turns,
        minutes=words / SPEAKING_WORDS_PER_MINUTE,
        script_model=script_model,
        voice_model=voice_model,
        provider=provider,
        missed_sections=missing_headings(body, turns),
    )


def headings(markdown: str) -> list[str]:
    """Every ATX heading in the document, in order."""
    found: list[str] = []
    for line in (markdown or "").splitlines():
        match = re.match(r"^#{1,6}\s+(.+?)\s*#*$", line.strip())
        if match:
            text = " ".join(match.group(1).split())
            if text:
                found.append(text)
    return found


def missing_headings(markdown: str, turns: list[Turn]) -> list[str]:
    """Which of the document's headings the script never touches.

    Deliberately generous about what counts as covered: the script is *meant*
    to paraphrase, so this asks whether the heading's distinctive words show up
    anywhere in the spoken text, not whether the heading is quoted. A heading of
    nothing but common words cannot be checked this way and is not reported —
    a false alarm on every "Introduction" would train the reader to ignore this.
    """
    spoken = " ".join(turn.text for turn in turns).casefold()
    spoken_words = set(re.findall(r"[^\W_]+", spoken, flags=re.UNICODE))
    missed: list[str] = []
    for heading in headings(markdown):
        words = {
            word
            for word in re.findall(r"[^\W_]+", heading.casefold(), flags=re.UNICODE)
            if len(word) > 3 and word not in COMMON_WORDS
        }
        if not words:
            continue
        if not (words & spoken_words):
            missed.append(heading)
    return missed


COMMON_WORDS = frozenset(
    {
        "this", "that", "with", "from", "have", "what", "when", "where", "which",
        "there", "their", "about", "into", "over", "under", "some", "more", "most",
        "than", "then", "them", "they", "were", "been", "being", "does", "done",
        "introduction", "conclusion", "background", "overview", "summary", "notes",
        "appendix", "references", "method", "methods", "methodology", "results",
        "discussion", "section", "part", "chapter",
    }
)


# ------------------------------------------------------------------- script


INSTRUCTIONS = """\
You are turning a document into a spoken piece for one listener — the person who \
wrote or commissioned it — to hear instead of reading it.

This is not a summary and not a reading. It is the document remade for the ear.

Rules, in order of how much they matter:

1. COVER EVERY SECTION, in the document's own order. Never silently drop one. \
If a section is thin, say so briefly and move on; do not skip it.
2. KEEP what carries the argument: names, numbers, dates, citations, the \
claims and the reasoning between them. A listener should be able to act on \
this without opening the document.
3. DROP the apparatus: footnote markers, table gridlines, reference lists, URLs, \
figure captions that only mean something visually. Where a table matters, say \
what it shows in a sentence.
4. OPEN with a hook of no more than two sentences: what this document is for \
and what is at stake in it. No throat-clearing, no "in this episode".
5. HAND OFF between speakers at genuine turns in the argument — a new section, \
a counterpoint, a shift in evidence. Not every paragraph, and never mid-thought.
6. INVENT NOTHING. No facts not in the document, no opinions it does not hold, \
no invented agreement or disagreement between the speakers. No "great \
question", no "absolutely", no filler.
7. SPEAK PLAINLY. Short sentences. Say numbers as a person would read them \
aloud. Expand an acronym the first time and then use it.

Return JSON and nothing else: {"turns": [{"speaker": "host"|"guest", "text": "..."}]}
"""


def write_script(
    markdown: str,
    *,
    title: str = "",
    depth: str = DEFAULT_DEPTH,
    hosts: int = 2,
    timeout: float = 120.0,
) -> tuple[list[Turn], str]:
    """Ask a model for the spoken version. Returns the turns and the model used."""
    model = os.environ.get("PENCIL_NARRATION_SCRIPT_MODEL") or "gpt-4o"
    target = target_words(markdown, depth)

    voices = (
        "Two speakers, host and guest, alternating at real turns in the argument."
        if hosts >= 2
        else "One speaker throughout. Use \"host\" for every turn."
    )
    prompt = (
        f"{INSTRUCTIONS}\n\n{voices}\n\n"
        f"Aim for about {target} words in total — that is roughly "
        f"{round(target / SPEAKING_WORDS_PER_MINUTE)} minutes spoken. Treat it as a "
        f"target, not a limit to pad to: covering every section matters more."
    )
    heading = f"Document title: {title}\n\n" if title else ""

    body = json.dumps(
        {
            "model": model,
            "temperature": 0.4,
            "response_format": {"type": "json_object"},
            "messages": [
                {"role": "system", "content": prompt},
                {"role": "user", "content": heading + markdown},
            ],
        }
    ).encode("utf-8")

    try:
        response = _post(
            "https://api.openai.com/v1/chat/completions",
            body,
            {
                "Authorization": f"Bearer {os.environ['OPENAI_API_KEY']}",
                "Content-Type": "application/json",
            },
            timeout,
        )
        content = response["choices"][0]["message"]["content"]
        parsed = json.loads(content)
    except (TranscriptionError, KeyError, IndexError, TypeError, ValueError) as error:
        raise NarrationError(f"could not write the script: {error}") from error

    turns = parse_turns(parsed, hosts=hosts)

    # Repair while it is still helping, and stop the moment it is not. The
    # first draft of a long document reliably drops sections — measured on a
    # real 4,700-word paper it dropped fourteen of forty headings at `standard`
    # and came in at half the requested length.
    #
    # This was one pass, on the reasoning that a second would be throwing good
    # credits after bad. The measurement said otherwise: one pass took fourteen
    # missing down to nine, which is a pass that was still working when it was
    # cut off. So it repeats while coverage strictly improves, and `MAX_REPAIRS`
    # is a backstop rather than the usual stopping point — a pass that gains
    # nothing ends it, because that is the real signal that asking again has
    # stopped paying.
    #
    # All of it happens before a single character is spoken. A script call is
    # cheap next to speaking thirty turns, which is what makes iterating here
    # the right place to spend.
    missed = missing_headings(markdown, turns)
    for _ in range(MAX_REPAIRS):
        if not missed:
            break
        revised = repair_script(
            markdown,
            turns,
            missed,
            title=title,
            model=model,
            target=target,
            hosts=hosts,
            timeout=timeout,
        )
        still_missing = missing_headings(markdown, revised)
        if len(still_missing) >= len(missed):
            break
        turns, missed = revised, still_missing

    return turns, model


def repair_script(
    markdown: str,
    turns: list[Turn],
    missed: list[str],
    *,
    title: str = "",
    model: str,
    target: int,
    hosts: int = 2,
    timeout: float = 120.0,
) -> list[Turn]:
    """Ask for the script again, naming what it left out.

    Returns the revised turns, or **the ones passed in** when the model fails or
    comes back with nothing. It never raises: a narration missing two sections is
    worth far more than no narration at all, which is why a failed repair is a
    no-op rather than an error.

    Whether the revision is actually an improvement is the caller's judgement —
    `write_script` keeps it only if it covers more, and stops repeating the
    moment one does not.
    """
    spoken = sum(len(turn.text.split()) for turn in turns)
    script = json.dumps(
        {"turns": [{"speaker": turn.speaker, "text": turn.text} for turn in turns]}
    )
    listed = "\n".join(f"- {heading}" for heading in missed[:60])
    voices = (
        "Two speakers, host and guest."
        if hosts >= 2
        else "One speaker throughout. Use \"host\" for every turn."
    )
    prompt = (
        f"{INSTRUCTIONS}\n\n{voices}\n\n"
        "You wrote the script below from the document that follows it. It leaves "
        "out these sections entirely:\n"
        f"{listed}\n\n"
        "Rewrite it so every one of them is covered, in the document's own order. "
        "Keep what is already good — reuse the wording of the turns that work. "
        f"The current script runs about {spoken} words; the target is {target}, so "
        "there is room, and you should use it rather than compressing what is "
        "already there. Return the COMPLETE revised script, not just the "
        "additions."
    )
    heading = f"Document title: {title}\n\n" if title else ""

    body = json.dumps(
        {
            "model": model,
            "temperature": 0.4,
            "response_format": {"type": "json_object"},
            "messages": [
                {"role": "system", "content": prompt},
                {"role": "user", "content": f"{heading}{markdown}"},
                {"role": "assistant", "content": script},
                {"role": "user", "content": "Now the complete revised script."},
            ],
        }
    ).encode("utf-8")

    try:
        response = _post(
            "https://api.openai.com/v1/chat/completions",
            body,
            {
                "Authorization": f"Bearer {os.environ['OPENAI_API_KEY']}",
                "Content-Type": "application/json",
            },
            timeout,
        )
        revised = parse_turns(
            json.loads(response["choices"][0]["message"]["content"]), hosts=hosts
        )
    except (TranscriptionError, KeyError, IndexError, TypeError, ValueError):
        return turns

    return revised or turns


def parse_turns(parsed: Any, *, hosts: int = 2) -> list[Turn]:
    """Turn the model's JSON into turns, dropping anything unusable.

    Lenient on purpose: a stray key or an unknown speaker should cost a turn's
    attribution, never the whole narration.
    """
    raw = parsed.get("turns") if isinstance(parsed, dict) else parsed
    if not isinstance(raw, list):
        return []
    turns: list[Turn] = []
    for entry in raw:
        if not isinstance(entry, dict):
            continue
        text = " ".join(str(entry.get("text") or "").split())
        if not text:
            continue
        speaker = str(entry.get("speaker") or HOST).strip().lower()
        if hosts < 2 or speaker not in (HOST, GUEST):
            speaker = HOST
        for piece in split_long(text):
            turns.append(Turn(speaker=speaker, text=piece))
    return turns


def split_long(text: str, limit: int = MAX_TURN_CHARS) -> list[str]:
    """Split an over-long turn on sentence boundaries.

    A turn should never approach the model's per-request ceiling, but a script
    that rambles must not fail the whole narration for it.
    """
    if len(text) <= limit:
        return [text]
    pieces: list[str] = []
    current = ""
    for sentence in re.split(r"(?<=[.!?])\s+", text):
        if current and len(current) + 1 + len(sentence) > limit:
            pieces.append(current)
            current = sentence
        else:
            current = f"{current} {sentence}".strip()
    if current:
        pieces.append(current)
    return pieces


def target_words(markdown: str, depth: str) -> int:
    """How many spoken words this depth asks for."""
    words = len(markdown.split())
    reading_minutes = words / READING_WORDS_PER_MINUTE
    return max(200, round(reading_minutes * DEPTHS[depth] * SPEAKING_WORDS_PER_MINUTE))


# -------------------------------------------------------------------- speech


def speak(turns: list[Turn], *, timeout: float = 120.0) -> tuple[bytes, str, str]:
    """Speak every turn and join them. Returns the audio, the model, the provider."""
    provider = voice_provider()
    if provider is None:
        raise NarrationUnconfigured(
            "no speech key is set; set ELEVENLABS_API_KEY or OPENAI_API_KEY"
        )

    chunks: list[bytes] = []
    for index, turn in enumerate(turns):
        previous = turns[index - 1].text if index > 0 else ""
        following = turns[index + 1].text if index + 1 < len(turns) else ""
        if provider in ("elevenlabs", "eleven"):
            audio, model = _elevenlabs_turn(turn, previous, following, timeout)
        elif provider == "openai":
            audio, model = _openai_turn(turn, timeout)
        else:
            raise NarrationError(f"unknown speech provider {provider!r}")
        chunks.append(audio)

    if not chunks:
        raise NarrationError("no audio was produced")
    # MP3 frames concatenate. Deliberately not ffmpeg: the relay boots with
    # nothing installed but Starlette, and this is a joint players tolerate.
    return b"".join(chunks), model, provider


def _voice_for(speaker: str) -> str:
    if speaker == GUEST:
        return (
            os.environ.get("PENCIL_TTS_GUEST_VOICE")
            # ElevenLabs' stock "Charlie" and "Alice" — replaceable by config,
            # named here so a fresh relay makes sound without being told to.
            or "IKne3meq5aSn9XLyUdCD"
        )
    return os.environ.get("PENCIL_TTS_HOST_VOICE") or "Xb7hH8MSUJpSbSDYk0k2"


def _elevenlabs_turn(
    turn: Turn, previous: str, following: str, timeout: float
) -> tuple[bytes, str]:
    key = os.environ.get("ELEVENLABS_API_KEY") or os.environ.get("ELEVEN_API_KEY")
    if not key:
        raise NarrationUnconfigured("ELEVENLABS_API_KEY is not set")
    model = os.environ.get("PENCIL_TTS_MODEL") or "eleven_multilingual_v2"
    voice = _voice_for(turn.speaker)

    body = json.dumps(
        {
            "text": turn.text,
            "model_id": model,
            # The reason a long script can be chunked at all: the model is told
            # what came before and after, so the joins carry prosody instead of
            # sounding spliced.
            "previous_text": previous,
            "next_text": following,
        }
    ).encode("utf-8")

    audio = _post_bytes(
        f"https://api.elevenlabs.io/v1/text-to-speech/{voice}?output_format=mp3_44100_64",
        body,
        {"xi-api-key": key, "Content-Type": "application/json"},
        timeout,
    )
    return audio, model


def _openai_turn(turn: Turn, timeout: float) -> tuple[bytes, str]:
    key = os.environ.get("OPENAI_API_KEY")
    if not key:
        raise NarrationUnconfigured("OPENAI_API_KEY is not set")
    model = os.environ.get("PENCIL_TTS_MODEL") or "gpt-4o-mini-tts"
    voice = _voice_for(turn.speaker)
    # OpenAI has no stitching parameters, so the joins are worse than
    # ElevenLabs'. It is here because it is 30× cheaper and the key is already
    # set; the note rates its long-form expressiveness lower, and that is the
    # trade being made.
    body = json.dumps(
        {
            "model": model,
            "voice": voice if voice in OPENAI_VOICES else ("ballad" if turn.speaker == GUEST else "ash"),
            "input": turn.text,
            "response_format": "mp3",
            "instructions": "Read as one half of a two-person discussion of a document: measured, interested, never breathless.",
        }
    ).encode("utf-8")
    audio = _post_bytes(
        "https://api.openai.com/v1/audio/speech",
        body,
        {"Authorization": f"Bearer {key}", "Content-Type": "application/json"},
        timeout,
    )
    return audio, model


OPENAI_VOICES = frozenset(
    {"alloy", "ash", "ballad", "coral", "echo", "fable", "nova", "onyx", "sage", "shimmer"}
)


def _post_bytes(url: str, payload: bytes, headers: dict[str, str], timeout: float) -> bytes:
    """`_post`, for an endpoint that answers with audio rather than JSON."""
    import urllib.error
    import urllib.request

    request = urllib.request.Request(url, data=payload, headers=headers, method="POST")
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            return response.read()
    except urllib.error.HTTPError as error:
        detail = ""
        try:
            detail = error.read().decode("utf-8", "replace")[:200]
        except Exception:  # pragma: no cover - the error body is a courtesy
            detail = ""
        raise NarrationError(f"speech provider returned {error.code}: {detail}") from error
    except (urllib.error.URLError, TimeoutError, OSError) as error:
        raise NarrationError(f"speech provider unreachable: {error}") from error
