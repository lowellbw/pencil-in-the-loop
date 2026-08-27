"""The second pass: correct a transcript, do not rewrite it.

Stage 3 of notes/pencil-loop-cloud-dictation.md. An ASR model hears sounds; it
does not know that "their" should have been "there", that a hesitation is not a
sentence boundary, or that the acronym it spelled out is a term the document
uses forty times. A cheap LLM with the document's own vocabulary in hand fixes
all three, and the note is blunt that this is where the remaining gain is.

It is also where the danger is, and the whole module is shaped around that. The
failure mode is an over-eager model that "improves" a review comment into
something the reader did not say -- which is worse than a garbled one, because
a garbled comment is obviously garbled and a fluent wrong one is not. So:

* the prompt forbids rephrasing, tightening, and adding, in those words;
* the result is measured against the input and **thrown away if it changed too
  much** -- the note's edit-distance guard rail;
* every failure returns the raw transcript unchanged.

Nothing here can make the transcript worse than the ASR left it. That is the
property to preserve if this file is ever edited.
"""

from __future__ import annotations

import difflib
import json
import os
import re
from dataclasses import dataclass
from typing import Any

from .transcribe import TranscriptionError, _post

# Above this share of the *output* unaccounted for by the input, the cleanup is
# refused and the raw text stands.
#
# The note specifies 25% of tokens *changed*, and measuring it that way turned
# out to be wrong in a way only a real clip showed: a comment containing "strike
# that" scored exactly 25% for doing precisely what it was told, because
# executing the command deletes a whole clause. A guard that fires on correct
# behaviour trains you to raise it until it fires on nothing.
#
# So this measures **invention, not change**. Words the speaker retracted are
# meant to disappear; words appearing in the output with nothing in the input to
# account for them are the actual danger, and the note names it — "content with
# no acoustic basis. Should be zero." Deletion is free, substitution and
# insertion are not.
MAX_INVENTED_TOKEN_RATIO = 0.25

# Below this many tokens the ratio is meaningless -- one word changed in a
# four-word comment is 25% and probably correct.
MIN_TOKENS_FOR_RATIO = 12

INSTRUCTIONS = """\
You are correcting a transcript of a spoken review comment. It was dictated by \
someone annotating a document, and it will be read back later out of context.

Do exactly this and nothing else:
- Fix misheard proper nouns, acronyms and technical terms, using the supplied \
terms as ground truth for spelling and capitalisation.
- Resolve homophones by context (their/there, principal/principle).
- Apply sentence punctuation, capitalisation and paragraph breaks.
- Remove fillers and false starts ("um", "uh", a restarted clause). Keep \
hedges: "I think this is wrong" and "this is wrong" are different comments.
- Execute spoken commands: "strike that" deletes the clause before it, "new \
paragraph" becomes a break.
- If a passage is genuinely unintelligible, write [unclear] rather than \
guessing at it.

Change nothing else. Do not rephrase, do not tighten, do not improve the \
wording, do not change the tone, do not add anything that was not said. The \
speaker's own words are the point.

Reply with the corrected text and nothing else -- no preamble, no quotes, no \
explanation."""


@dataclass(frozen=True)
class Cleaned:
    """What the second pass produced, and whether it was allowed to stand."""

    text: str
    raw: str
    model: str | None
    applied: bool
    changed_ratio: float
    reason: str | None = None

    def as_dict(self) -> dict[str, Any]:
        return {
            "text": self.text,
            "raw": self.raw,
            "cleanupModel": self.model,
            "cleanupApplied": self.applied,
            "inventedRatio": round(self.changed_ratio, 3),
            "cleanupSkipped": self.reason,
        }


def is_configured() -> bool:
    """Whether a cleanup pass can run at all."""
    if (os.environ.get("PENCIL_CLEANUP") or "").strip().lower() in ("0", "off", "false"):
        return False
    return bool(os.environ.get("OPENAI_API_KEY"))


def polish(raw: str, *, keyterms: list[str] | None = None, timeout: float = 30.0) -> Cleaned:
    """Correct one transcript, or return it untouched.

    **Never raises.** Every path that cannot produce a confidently-better
    version returns the raw text with ``applied`` false and a reason, because
    the caller's alternative is not "try harder" -- it is "show the reader
    something they did not say".

    Only the term list is sent, never the document's prose. The note flags this
    as the larger disclosure of the two: audio is one comment, a paragraph of
    context is the document itself. A term list leaks far less and does most of
    the work.
    """
    text = (raw or "").strip()
    if not text:
        return Cleaned(text=raw, raw=raw, model=None, applied=False, changed_ratio=0.0,
                       reason="nothing to correct")
    if not is_configured():
        return Cleaned(text=raw, raw=raw, model=None, applied=False, changed_ratio=0.0,
                       reason="no cleanup key configured")

    model = os.environ.get("PENCIL_CLEANUP_MODEL") or "gpt-4o-mini"
    prompt = INSTRUCTIONS
    terms = [t for t in (keyterms or []) if isinstance(t, str) and t.strip()]
    if terms:
        prompt += "\n\nTerms used in this document:\n" + ", ".join(terms[:100])

    body = json.dumps(
        {
            "model": model,
            "temperature": 0,
            "messages": [
                {"role": "system", "content": prompt},
                {"role": "user", "content": text},
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
        candidate = (response["choices"][0]["message"]["content"] or "").strip()
    except (TranscriptionError, KeyError, IndexError, TypeError) as error:
        return Cleaned(text=raw, raw=raw, model=model, applied=False, changed_ratio=0.0,
                       reason=f"cleanup failed: {error}")

    if not candidate:
        return Cleaned(text=raw, raw=raw, model=model, applied=False, changed_ratio=0.0,
                       reason="cleanup returned nothing")

    ratio = invented_ratio(text, candidate)
    tokens = len(_tokens(text))
    if tokens >= MIN_TOKENS_FOR_RATIO and ratio > MAX_INVENTED_TOKEN_RATIO:
        # The guard rail. Either the model rewrote the comment, or the audio was
        # bad enough that it invented one. Both look like this from here, and
        # both are answered the same way.
        return Cleaned(text=raw, raw=raw, model=model, applied=False, changed_ratio=ratio,
                       reason=f"{ratio:.0%} of the words had nothing behind them; keeping the raw transcript")

    return Cleaned(text=candidate, raw=raw, model=model, applied=True, changed_ratio=ratio)


def invented_ratio(before: str, after: str) -> float:
    """Share of the output with nothing in the input to account for it.

    Asymmetric on purpose. Dropping words is what the cleanup is asked to do --
    fillers, false starts, a clause the speaker struck -- so deletions cost
    nothing here. What is measured is the other direction: tokens that appear in
    the corrected text without a match in the transcript. A rewrite scores high,
    a retraction scores zero, and a handful of respelled proper nouns scores a
    little.

    Case and punctuation are ignored, because applying them is the job.
    """
    left, right = _tokens(before), _tokens(after)
    if not right:
        return 0.0
    matcher = difflib.SequenceMatcher(a=left, b=right, autojunk=False)
    matched = sum(block.size for block in matcher.get_matching_blocks())
    return max(0.0, 1.0 - (matched / len(right)))


_WORD_RE = re.compile(r"[^\W_]+", re.UNICODE)


def _tokens(text: str) -> list[str]:
    return [word.casefold() for word in _WORD_RE.findall(text or "")]
