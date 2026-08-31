"""Turning a document into something you can listen to.

The failure this feature would actually have is quiet — a narration that sounds
fluent and has dropped a section — so the first tests here are about coverage,
and the rest are about not producing half a file when something goes wrong.

Standard library only, no network: both providers are stubbed. What is under
test is the shaping, the chunking, the stitching parameters and the failure
paths, which is everything except the model's taste.
"""

from __future__ import annotations

import json
import os
import unittest
from unittest import mock

from pencil_in_the_loop_mcp import narrate


DOC = """# Traces in the Record

Some opening prose about the scan.

## Prevalence estimation

Liang et al. measured UN press releases.

## Pangram and its failure modes

Pangram 4 scores AI-polished text as human.

## Corpus selection

Policy papers and impact assessments.
"""


class HeadingTests(unittest.TestCase):
    def test_every_atx_heading_is_found_in_order(self) -> None:
        self.assertEqual(
            narrate.headings(DOC),
            [
                "Traces in the Record",
                "Prevalence estimation",
                "Pangram and its failure modes",
                "Corpus selection",
            ],
        )

    def test_a_covered_document_reports_nothing_missing(self) -> None:
        turns = [
            narrate.Turn("host", "Traces in the Record looks at prevalence estimation."),
            narrate.Turn("guest", "Pangram has failure modes, and the corpus selection matters."),
        ]
        self.assertEqual(narrate.missing_headings(DOC, turns), [])

    def test_a_dropped_section_is_reported(self) -> None:
        # The whole point: this is the failure that is otherwise invisible.
        turns = [narrate.Turn("host", "Traces in the Record looks at prevalence estimation.")]
        missed = narrate.missing_headings(DOC, turns)
        self.assertIn("Pangram and its failure modes", missed)
        self.assertIn("Corpus selection", missed)

    def test_paraphrase_still_counts_as_covered(self) -> None:
        # The script is meant to paraphrase, so this asks whether the heading's
        # distinctive words appear, not whether it was quoted.
        turns = [narrate.Turn("host", "They estimated prevalence, then chose a corpus, and Pangram came up.")]
        self.assertEqual(narrate.missing_headings(DOC, turns), ["Traces in the Record"])

    def test_a_heading_of_only_common_words_is_not_reported(self) -> None:
        # A false alarm on every "Introduction" trains you to ignore this.
        self.assertEqual(narrate.missing_headings("## Introduction\n\ntext", []), [])


class DepthTests(unittest.TestCase):
    def test_depth_moves_the_target_monotonically(self) -> None:
        doc = " ".join(["word"] * 5000)
        brief = narrate.target_words(doc, "brief")
        standard = narrate.target_words(doc, "standard")
        deep = narrate.target_words(doc, "deep")
        self.assertLess(brief, standard)
        self.assertLess(standard, deep)

    def test_a_very_short_document_still_gets_a_floor(self) -> None:
        self.assertGreaterEqual(narrate.target_words("a few words", "brief"), 200)

    def test_an_unknown_depth_is_refused(self) -> None:
        with self.assertRaises(narrate.NarrationError):
            narrate.narrate(DOC, depth="epic")


class TurnTests(unittest.TestCase):
    def test_order_is_preserved_and_blanks_dropped(self) -> None:
        turns = narrate.parse_turns(
            {"turns": [
                {"speaker": "host", "text": "one"},
                {"speaker": "guest", "text": "  "},
                {"speaker": "guest", "text": "two"},
            ]}
        )
        self.assertEqual([t.text for t in turns], ["one", "two"])
        self.assertEqual([t.speaker for t in turns], ["host", "guest"])

    def test_an_unknown_speaker_becomes_the_host(self) -> None:
        turns = narrate.parse_turns({"turns": [{"speaker": "narrator", "text": "x"}]})
        self.assertEqual(turns[0].speaker, "host")

    def test_one_host_collapses_every_turn_onto_the_host(self) -> None:
        turns = narrate.parse_turns(
            {"turns": [{"speaker": "guest", "text": "x"}]}, hosts=1
        )
        self.assertEqual(turns[0].speaker, "host")

    def test_an_over_long_turn_is_split_on_sentences(self) -> None:
        long = "This is a sentence. " * 400
        pieces = narrate.split_long(long)
        self.assertGreater(len(pieces), 1)
        for piece in pieces:
            self.assertLessEqual(len(piece), narrate.MAX_TURN_CHARS)
        self.assertTrue(all(piece.endswith(".") for piece in pieces))

    def test_rubbish_from_the_model_is_no_turns_rather_than_a_crash(self) -> None:
        self.assertEqual(narrate.parse_turns("not a dict"), [])
        self.assertEqual(narrate.parse_turns({"turns": "nope"}), [])


class SpeechTests(unittest.TestCase):
    def setUp(self) -> None:
        self._saved = dict(os.environ)
        for key in list(os.environ):
            if key.startswith(("PENCIL_", "ELEVEN", "OPENAI")):
                del os.environ[key]
        os.environ["ELEVENLABS_API_KEY"] = "test-key"
        self.addCleanup(self._restore)

    def _restore(self) -> None:
        os.environ.clear()
        os.environ.update(self._saved)

    TURNS = [
        narrate.Turn("host", "First."),
        narrate.Turn("guest", "Second."),
        narrate.Turn("host", "Third."),
    ]

    def test_the_neighbouring_turns_are_sent_as_stitching_context(self) -> None:
        # This parameter pair is the reason a long script can be chunked at all.
        seen = []

        def fake(url, payload, headers, timeout):
            seen.append(json.loads(payload))
            return b"mp3"

        with mock.patch.object(narrate, "_post_bytes", side_effect=fake):
            narrate.speak(self.TURNS)

        self.assertEqual(seen[0]["previous_text"], "")
        self.assertEqual(seen[0]["next_text"], "Second.")
        self.assertEqual(seen[1]["previous_text"], "First.")
        self.assertEqual(seen[1]["next_text"], "Third.")
        self.assertEqual(seen[2]["next_text"], "")

    def test_the_two_speakers_get_two_voices(self) -> None:
        os.environ["PENCIL_TTS_HOST_VOICE"] = "host-voice"
        os.environ["PENCIL_TTS_GUEST_VOICE"] = "guest-voice"
        urls = []

        with mock.patch.object(narrate, "_post_bytes", side_effect=lambda u, *a, **k: urls.append(u) or b"mp3"):
            narrate.speak(self.TURNS)

        self.assertIn("host-voice", urls[0])
        self.assertIn("guest-voice", urls[1])

    def test_the_pieces_are_joined_in_order(self) -> None:
        pieces = [b"one", b"two", b"three"]
        with mock.patch.object(narrate, "_post_bytes", side_effect=pieces):
            audio, _, provider = narrate.speak(self.TURNS)
        self.assertEqual(audio, b"onetwothree")
        self.assertEqual(provider, "elevenlabs")

    def test_openai_is_selectable(self) -> None:
        del os.environ["ELEVENLABS_API_KEY"]
        os.environ["OPENAI_API_KEY"] = "k"
        with mock.patch.object(narrate, "_post_bytes", return_value=b"mp3") as post:
            _, model, provider = narrate.speak([narrate.Turn("host", "x")])
        self.assertEqual(provider, "openai")
        self.assertIn("audio/speech", post.call_args[0][0])
        self.assertEqual(model, "gpt-4o-mini-tts")

    def test_no_key_says_so_rather_than_failing_obscurely(self) -> None:
        del os.environ["ELEVENLABS_API_KEY"]
        with self.assertRaises(narrate.NarrationUnconfigured):
            narrate.speak(self.TURNS)

    def test_one_failed_turn_fails_the_narration_rather_than_half_a_file(self) -> None:
        # Half a document read aloud, ending mid-argument, is worse than none.
        with mock.patch.object(
            narrate, "_post_bytes", side_effect=[b"one", narrate.NarrationError("boom")]
        ):
            with self.assertRaises(narrate.NarrationError):
                narrate.speak(self.TURNS)


class NarrateTests(unittest.TestCase):
    def setUp(self) -> None:
        self._saved = dict(os.environ)
        os.environ["OPENAI_API_KEY"] = "k"
        os.environ["ELEVENLABS_API_KEY"] = "k"
        self.addCleanup(self._restore)

    def _restore(self) -> None:
        os.environ.clear()
        os.environ.update(self._saved)

    def test_end_to_end_reports_what_it_made(self) -> None:
        script = {"choices": [{"message": {"content": json.dumps({"turns": [
            {"speaker": "host", "text": "Traces in the Record: prevalence estimation."},
            {"speaker": "guest", "text": "Pangram failure modes, and corpus selection."},
        ]})}}]}
        with mock.patch.object(narrate, "_post", return_value=script), \
             mock.patch.object(narrate, "_post_bytes", return_value=b"mp3"):
            result = narrate.narrate(DOC, title="Traces", depth="brief")

        self.assertEqual(result.audio, b"mp3mp3")
        self.assertEqual(len(result.turns), 2)
        self.assertEqual(result.missed_sections, [])
        self.assertGreater(result.minutes, 0)
        self.assertEqual(result.as_dict()["missedSections"], [])

    def test_a_dropped_section_reaches_the_caller(self) -> None:
        script = {"choices": [{"message": {"content": json.dumps({"turns": [
            {"speaker": "host", "text": "Only prevalence estimation, nothing else."},
        ]})}}]}
        with mock.patch.object(narrate, "_post", return_value=script), \
             mock.patch.object(narrate, "_post_bytes", return_value=b"mp3"):
            result = narrate.narrate(DOC)

        self.assertIn("Corpus selection", result.missed_sections)

    def test_a_dropped_section_is_asked_for_again_before_anything_is_spoken(self) -> None:
        """The repair pass is the whole reason coverage is checked twice.

        Measured on a real 4,700-word paper, the first draft dropped fourteen of
        forty headings at `standard`. Reporting that in a JSON blob nobody reads
        is not a fix; asking again, before the expensive stage, is.
        """
        thin = {"choices": [{"message": {"content": json.dumps({"turns": [
            {"speaker": "host", "text": "Only prevalence estimation, nothing else."},
        ]})}}]}
        full = {"choices": [{"message": {"content": json.dumps({"turns": [
            {"speaker": "host", "text": "Traces in the Record: prevalence estimation, and Pangram failure modes."},
            {"speaker": "guest", "text": "Then corpus selection, which is the hard part."},
        ]})}}]}
        with mock.patch.object(narrate, "_post", side_effect=[thin, full]) as post, \
             mock.patch.object(narrate, "_post_bytes", return_value=b"mp3"):
            result = narrate.narrate(DOC)

        self.assertEqual(post.call_count, 2)
        self.assertEqual(result.missed_sections, [])
        self.assertEqual(len(result.turns), 2)

    def test_a_repair_that_covers_less_is_thrown_away(self) -> None:
        """A second attempt is not automatically the better one."""
        good = {"choices": [{"message": {"content": json.dumps({"turns": [
            {"speaker": "host", "text": "Prevalence estimation and Pangram failure modes."},
        ]})}}]}
        worse = {"choices": [{"message": {"content": json.dumps({"turns": [
            {"speaker": "host", "text": "Nothing in particular."},
        ]})}}]}
        with mock.patch.object(narrate, "_post", side_effect=[good, worse]), \
             mock.patch.object(narrate, "_post_bytes", return_value=b"mp3"):
            result = narrate.narrate(DOC)

        self.assertIn("prevalence", result.turns[0].text.casefold())
        self.assertIn("Corpus selection", result.missed_sections)

    def test_a_failed_repair_leaves_the_first_script_standing(self) -> None:
        """A narration missing two sections beats no narration at all."""
        thin = {"choices": [{"message": {"content": json.dumps({"turns": [
            {"speaker": "host", "text": "Only prevalence estimation."},
        ]})}}]}
        with mock.patch.object(
            narrate, "_post", side_effect=[thin, narrate.TranscriptionError("502")]
        ), mock.patch.object(narrate, "_post_bytes", return_value=b"mp3"):
            result = narrate.narrate(DOC)

        self.assertEqual(len(result.turns), 1)
        self.assertIn("Corpus selection", result.missed_sections)

    def test_a_covered_script_is_never_asked_for_twice(self) -> None:
        script = {"choices": [{"message": {"content": json.dumps({"turns": [
            {"speaker": "host", "text": "Traces in the Record: prevalence estimation."},
            {"speaker": "guest", "text": "Pangram failure modes, and corpus selection."},
        ]})}}]}
        with mock.patch.object(narrate, "_post", return_value=script) as post, \
             mock.patch.object(narrate, "_post_bytes", return_value=b"mp3"):
            narrate.narrate(DOC, depth="brief")

        self.assertEqual(post.call_count, 1)

    def test_an_empty_document_is_refused(self) -> None:
        with self.assertRaises(narrate.NarrationError):
            narrate.narrate("   ")

    def test_no_script_key_is_unconfigured_not_a_generic_failure(self) -> None:
        del os.environ["OPENAI_API_KEY"]
        with self.assertRaises(narrate.NarrationUnconfigured):
            narrate.narrate(DOC)

    def test_an_empty_script_is_an_error_rather_than_a_silent_empty_file(self) -> None:
        script = {"choices": [{"message": {"content": json.dumps({"turns": []})}}]}
        with mock.patch.object(narrate, "_post", return_value=script):
            with self.assertRaises(narrate.NarrationError):
                narrate.narrate(DOC)


if __name__ == "__main__":
    unittest.main()
