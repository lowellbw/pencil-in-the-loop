"""The second pass, and the rail that stops it inventing a comment.

The property every test here defends: nothing in the cleanup can make a
transcript worse than the ASR left it. A refused cleanup, a failed request, a
missing key and an empty reply all mean the same thing -- the raw text stands.

Standard library only, and no network: the model call is stubbed. What is
actually under test is the guard, which is the part that has to be right.
"""

from __future__ import annotations

import os
import unittest
from unittest import mock

from pencil_in_the_loop_mcp import cleanup


class InventedRatioTests(unittest.TestCase):
    """Deletion is free; invention is not."""

    def test_punctuation_and_casing_do_not_count(self) -> None:
        # Applying them is the job, so counting them would trip the guard on
        # exactly the corrections that are wanted.
        self.assertEqual(
            cleanup.invented_ratio("the riio 3 determination", "The RIIO 3 determination."),
            0.0,
        )

    def test_removing_a_filler_costs_nothing(self) -> None:
        self.assertEqual(
            cleanup.invented_ratio("um I think the cat sat on the mat", "I think the cat sat on the mat"),
            0.0,
        )

    def test_executing_strike_that_costs_nothing(self) -> None:
        # The case a real clip found. Measuring *change* scored this at exactly
        # the 25% limit for doing precisely what it was told.
        before = "conflicts with their price control strike that conflicts with the Elexon BSC"
        after = "conflicts with the Elexon BSC"
        self.assertEqual(cleanup.invented_ratio(before, after), 0.0)

    def test_a_respelled_term_costs_a_little(self) -> None:
        ratio = cleanup.invented_ratio("a b c d e f g h i j", "a b c d e f g h i X")
        self.assertGreater(ratio, 0.0)
        self.assertLess(ratio, cleanup.MAX_INVENTED_TOKEN_RATIO)

    def test_a_rewrite_costs_everything(self) -> None:
        ratio = cleanup.invented_ratio("the cat sat on the mat quietly today", "a feline reclined upon a rug")
        self.assertGreater(ratio, cleanup.MAX_INVENTED_TOKEN_RATIO)

    def test_added_content_is_caught(self) -> None:
        ratio = cleanup.invented_ratio(
            "yes agreed", "yes agreed and we should also rewrite the whole section immediately"
        )
        self.assertGreater(ratio, cleanup.MAX_INVENTED_TOKEN_RATIO)

    def test_an_empty_result_is_not_an_invention(self) -> None:
        self.assertEqual(cleanup.invented_ratio("anything at all", ""), 0.0)


class PolishTests(unittest.TestCase):
    """Every path that cannot produce a confidently better version keeps the raw."""

    RAW = "um I think the RIIO 3 determination from Ofgem conflicts with there price control"

    def setUp(self) -> None:
        self._saved = dict(os.environ)
        os.environ["OPENAI_API_KEY"] = "test-key"
        os.environ.pop("PENCIL_CLEANUP", None)
        self.addCleanup(self._restore)

    def _restore(self) -> None:
        os.environ.clear()
        os.environ.update(self._saved)

    def reply(self, text: str):
        return {"choices": [{"message": {"content": text}}]}

    def test_a_good_correction_is_applied(self) -> None:
        better = "I think the RIIO-3 determination from Ofgem conflicts with their price control."
        with mock.patch.object(cleanup, "_post", return_value=self.reply(better)):
            result = cleanup.polish(self.RAW, keyterms=["Ofgem", "RIIO-3"])

        self.assertTrue(result.applied)
        self.assertEqual(result.text, better)
        self.assertEqual(result.raw, self.RAW, "the raw transcript is carried, not discarded")

    def test_a_rewrite_is_refused_and_the_raw_stands(self) -> None:
        rewrite = "The author should reconsider the entire regulatory framework from first principles."
        with mock.patch.object(cleanup, "_post", return_value=self.reply(rewrite)):
            result = cleanup.polish(self.RAW)

        self.assertFalse(result.applied)
        self.assertEqual(result.text, self.RAW)
        self.assertIn("nothing behind them", result.reason or "")

    def test_no_key_means_the_raw_stands(self) -> None:
        del os.environ["OPENAI_API_KEY"]

        result = cleanup.polish(self.RAW)

        self.assertFalse(result.applied)
        self.assertEqual(result.text, self.RAW)

    def test_cleanup_can_be_turned_off(self) -> None:
        os.environ["PENCIL_CLEANUP"] = "off"

        result = cleanup.polish(self.RAW)

        self.assertFalse(result.applied)
        self.assertEqual(result.text, self.RAW)

    def test_a_failed_request_keeps_the_raw_rather_than_raising(self) -> None:
        from pencil_in_the_loop_mcp.transcribe import TranscriptionError

        with mock.patch.object(cleanup, "_post", side_effect=TranscriptionError("boom")):
            result = cleanup.polish(self.RAW)

        self.assertFalse(result.applied)
        self.assertEqual(result.text, self.RAW)

    def test_an_empty_reply_keeps_the_raw(self) -> None:
        with mock.patch.object(cleanup, "_post", return_value=self.reply("   ")):
            result = cleanup.polish(self.RAW)

        self.assertFalse(result.applied)
        self.assertEqual(result.text, self.RAW)

    def test_a_short_comment_is_not_judged_by_ratio(self) -> None:
        # One word changed in a four-word comment is 25% and probably correct.
        with mock.patch.object(cleanup, "_post", return_value=self.reply("Yes, agreed.")):
            result = cleanup.polish("yeah agreed")

        self.assertTrue(result.applied)

    def test_only_terms_are_sent_never_the_documents_prose(self) -> None:
        captured = {}

        def spy(url, payload, headers, timeout):
            captured["payload"] = payload.decode("utf-8")
            return self.reply("I think it conflicts.")

        with mock.patch.object(cleanup, "_post", side_effect=spy):
            cleanup.polish(self.RAW, keyterms=["Ofgem", "RIIO-3"])

        self.assertIn("Ofgem", captured["payload"])
        self.assertIn(
            "Terms used in this document",
            captured["payload"],
            "The term list is the disclosure; a paragraph of context would be a much larger one.",
        )


if __name__ == "__main__":
    unittest.main()
