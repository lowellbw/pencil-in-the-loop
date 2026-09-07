"""Cloud speech-to-text: the request each provider actually accepts.

No network. ``_post`` is stubbed and what is asserted is the body that would
have gone out -- because the failure this guards against was one of shape, not
of transcription: ElevenLabs was sent its keyterms as one JSON-encoded field,
read them as a single keyword full of brackets, and refused every request that
carried the document's vocabulary, which was every request.
"""

from __future__ import annotations

import os
import unittest
from unittest import mock

from pencil_in_the_loop_mcp import transcribe


class ElevenLabsKeytermTests(unittest.TestCase):
    """What survives the trim is what the API will take."""

    def test_reserved_characters_are_removed_not_refused(self) -> None:
        self.assertEqual(
            transcribe.elevenlabs_keyterms(["RIIO-3", "[draft]", "a<b>", "back\\slash"]),
            ["RIIO-3", "draft", "ab", "backslash"],
        )

    def test_a_term_that_is_a_sentence_is_dropped(self) -> None:
        six_words = "the price control for the next period"
        self.assertEqual(transcribe.elevenlabs_keyterms([six_words, "Ofgem"]), ["Ofgem"])

    def test_a_term_at_the_length_limit_is_dropped(self) -> None:
        long = "x" * transcribe.ELEVENLABS_KEYTERM_MAX_CHARS
        short = "x" * (transcribe.ELEVENLABS_KEYTERM_MAX_CHARS - 1)
        self.assertEqual(transcribe.elevenlabs_keyterms([long, short]), [short])

    def test_whitespace_is_normalised_and_duplicates_collapse(self) -> None:
        self.assertEqual(
            transcribe.elevenlabs_keyterms(["price  control", "price control", "  "]),
            ["price control"],
        )

    def test_order_is_the_callers_and_the_cap_keeps_the_first(self) -> None:
        terms = [f"term{i}" for i in range(transcribe.MAX_KEYTERMS + 20)]
        kept = transcribe.elevenlabs_keyterms(terms)
        self.assertEqual(len(kept), transcribe.MAX_KEYTERMS)
        self.assertEqual(kept[:3], ["term0", "term1", "term2"])


class ElevenLabsRequestTests(unittest.TestCase):
    """The body that goes out."""

    def _send(self, keyterms: list[str]) -> tuple[bytes, dict[str, str], transcribe.Transcript]:
        captured: dict[str, object] = {}

        def fake_post(url, payload, headers, timeout):
            captured["url"] = url
            captured["payload"] = payload
            captured["headers"] = headers
            return {"text": "Ofgem's RIIO-3 price control."}

        with mock.patch.dict(os.environ, {"ELEVENLABS_API_KEY": "key"}, clear=True), mock.patch.object(
            transcribe, "_post", fake_post
        ):
            result = transcribe._elevenlabs(b"fLaC", keyterms, "en-GB", 5)
        return captured["payload"], captured["headers"], result  # type: ignore[return-value]

    def test_each_keyterm_is_its_own_form_field(self) -> None:
        payload, headers, result = self._send(["Ofgem", "RIIO-3", "price control"])
        body = payload.decode("utf-8", "replace")

        self.assertEqual(body.count('name="keyterms"'), 3)
        self.assertIn("\r\n\r\nRIIO-3\r\n", body)
        self.assertNotIn('["Ofgem"', body, "The list must not be JSON-encoded into one field.")
        self.assertIn("multipart/form-data; boundary=", headers["Content-Type"])
        self.assertEqual(result.provider, "elevenlabs")
        self.assertEqual(result.text, "Ofgem's RIIO-3 price control.")

    def test_no_keyterms_means_no_keyterm_field(self) -> None:
        payload, _, _ = self._send([])
        self.assertNotIn('name="keyterms"', payload.decode("utf-8", "replace"))

    def test_the_language_is_sent_as_its_base_code(self) -> None:
        payload, _, _ = self._send([])
        self.assertIn('name="language_code"\r\n\r\nen\r\n', payload.decode("utf-8", "replace"))


class MultipartTests(unittest.TestCase):

    def test_a_dict_still_works_for_the_providers_that_take_one(self) -> None:
        payload, content_type = transcribe._multipart(
            {"model": "m"}, "file", "clip.flac", "audio/flac", b"\x00"
        )
        body = payload.decode("utf-8", "replace")
        self.assertIn('name="model"\r\n\r\nm\r\n', body)
        self.assertIn('filename="clip.flac"', body)
        self.assertTrue(content_type.startswith("multipart/form-data; boundary="))


class ProviderSelectionTests(unittest.TestCase):
    """Which provider the environment picks, and that it says so."""

    def test_a_named_provider_wins_over_whatever_keys_are_present(self) -> None:
        env = {"PENCIL_STT_PROVIDER": "openai", "ELEVENLABS_API_KEY": "e", "DEEPGRAM_API_KEY": "d"}
        with mock.patch.dict(os.environ, env, clear=True):
            self.assertEqual(transcribe.configured_provider(), "openai")

    def test_keys_decide_in_the_documented_order(self) -> None:
        with mock.patch.dict(os.environ, {"ELEVENLABS_API_KEY": "e", "OPENAI_API_KEY": "o"}, clear=True):
            self.assertEqual(transcribe.configured_provider(), "elevenlabs")
        with mock.patch.dict(os.environ, {"OPENAI_API_KEY": "o"}, clear=True):
            self.assertEqual(transcribe.configured_provider(), "openai")

    def test_no_key_is_unconfigured_not_an_error(self) -> None:
        with mock.patch.dict(os.environ, {}, clear=True):
            self.assertIsNone(transcribe.configured_provider())
            with self.assertRaises(transcribe.TranscriptionUnconfigured):
                transcribe.transcribe(b"fLaC")


if __name__ == "__main__":
    unittest.main()
