"""Ledger: deduplication, retry, backoff, persistence."""

from __future__ import annotations

from pencil_watcher import ledger as ledger_mod
from pencil_watcher.ledger import Ledger, backoff_delay
from tests.helpers import FakeClock, TempDirTestCase

BASE = dict(base=30.0, factor=2.0, cap=1800.0, max_attempts=3)


class LedgerDedupeTests(TempDirTestCase):
    def ledger(self, clock=None) -> Ledger:
        return Ledger(self.root / "ledger.json", clock=clock or FakeClock())

    def test_unknown_key_is_due_and_not_delivered(self) -> None:
        ledger = self.ledger()
        self.assertFalse(ledger.is_delivered("a#1"))
        self.assertTrue(ledger.due("a#1"))

    def test_delivered_key_is_never_due_again(self) -> None:
        ledger = self.ledger()
        ledger.mark_terminal("a#1", "outbox/a.review", "1", ledger_mod.STATUS_DELIVERED, "poke")
        self.assertTrue(ledger.is_delivered("a#1"))
        self.assertFalse(ledger.due("a#1"))
        self.assertTrue(ledger.is_terminal("a#1"))

    def test_same_path_new_content_hash_is_a_new_key(self) -> None:
        """An edited-and-resynced bundle must be deliverable again."""
        ledger = self.ledger()
        ledger.mark_terminal("outbox/a.review#h1", "outbox/a.review", "h1", ledger_mod.STATUS_DELIVERED, "poke")
        self.assertFalse(ledger.due("outbox/a.review#h1"))
        self.assertTrue(ledger.due("outbox/a.review#h2"))

    def test_same_content_different_path_is_a_new_key(self) -> None:
        ledger = self.ledger()
        ledger.mark_terminal("outbox/a.review#h", "outbox/a.review", "h", ledger_mod.STATUS_DELIVERED, "poke")
        self.assertTrue(ledger.due("outbox/b.review#h"))

    def test_skipped_and_held_are_terminal(self) -> None:
        ledger = self.ledger()
        ledger.mark_terminal("a#1", "a", "1", ledger_mod.STATUS_SKIPPED, "checkin")
        ledger.mark_terminal("b#1", "b", "1", ledger_mod.STATUS_HELD, "none")
        self.assertFalse(ledger.due("a#1"))
        self.assertFalse(ledger.due("b#1"))
        self.assertFalse(ledger.is_delivered("a#1"))

    def test_survives_a_reload(self) -> None:
        clock = FakeClock()
        ledger = Ledger(self.root / "ledger.json", clock=clock)
        ledger.mark_terminal("a#1", "outbox/a.review", "1", ledger_mod.STATUS_DELIVERED, "cloud")
        reloaded = Ledger(self.root / "ledger.json", clock=clock)
        self.assertTrue(reloaded.is_delivered("a#1"))
        self.assertEqual(reloaded.get("a#1").route, "cloud")

    def test_corrupt_ledger_does_not_raise(self) -> None:
        path = self.root / "ledger.json"
        path.write_text("{not json", encoding="utf-8")
        ledger = Ledger(path, clock=FakeClock())
        self.assertEqual(list(ledger.entries()), [])

    def test_ledger_lives_outside_the_sync_folder(self) -> None:
        """Guards the contract: no daemon state inside the shared folder."""
        from tests.helpers import make_config

        config = make_config(self.root)
        self.assertNotIn(str(config.sync_root), str(config.ledger_path))

    def test_forget_requeues(self) -> None:
        ledger = self.ledger()
        ledger.mark_terminal("outbox/a.review#h", "outbox/a.review", "h", ledger_mod.STATUS_EXHAUSTED, "poke")
        self.assertFalse(ledger.due("outbox/a.review#h"))
        self.assertEqual(ledger.forget("outbox/a.review"), 1)
        self.assertTrue(ledger.due("outbox/a.review#h"))


class BackoffTests(TempDirTestCase):
    def test_delay_grows_exponentially_and_caps(self) -> None:
        self.assertEqual(backoff_delay(1, base=30, factor=2, cap=1800), 30)
        self.assertEqual(backoff_delay(2, base=30, factor=2, cap=1800), 60)
        self.assertEqual(backoff_delay(3, base=30, factor=2, cap=1800), 120)
        self.assertEqual(backoff_delay(9, base=30, factor=2, cap=1800), 1800)

    def test_failure_schedules_growing_retries(self) -> None:
        clock = FakeClock()
        ledger = Ledger(self.root / "ledger.json", clock=clock)

        entry = ledger.mark_failure("a#1", "a", "1", "poke", "boom", **BASE)
        self.assertEqual(entry.status, ledger_mod.STATUS_FAILED)
        self.assertFalse(ledger.due("a#1"))
        self.assertAlmostEqual(ledger.wait_remaining("a#1"), 30.0)

        clock.advance(29)
        self.assertFalse(ledger.due("a#1"))
        clock.advance(2)
        self.assertTrue(ledger.due("a#1"))

        entry = ledger.mark_failure("a#1", "a", "1", "poke", "boom", **BASE)
        self.assertAlmostEqual(ledger.wait_remaining("a#1"), 60.0)

    def test_retries_are_capped_then_exhausted(self) -> None:
        clock = FakeClock()
        ledger = Ledger(self.root / "ledger.json", clock=clock)
        for _ in range(3):
            entry = ledger.mark_failure("a#1", "a", "1", "poke", "boom", **BASE)
            clock.advance(10_000)
        self.assertEqual(entry.attempts, 3)
        self.assertEqual(entry.status, ledger_mod.STATUS_EXHAUSTED)
        self.assertFalse(ledger.due("a#1"))
        self.assertTrue(ledger.is_terminal("a#1"))
        self.assertFalse(ledger.is_delivered("a#1"))

    def test_deferral_backs_off_but_never_exhausts(self) -> None:
        """docs/06: a running local session frees up eventually. Hold, don't give up."""
        clock = FakeClock()
        ledger = Ledger(self.root / "ledger.json", clock=clock)
        for _ in range(20):
            entry = ledger.mark_deferred(
                "a#1", "a", "1", "resume", "busy", base=10.0, factor=2.0, cap=60.0
            )
            clock.advance(10_000)
        self.assertEqual(entry.status, ledger_mod.STATUS_DEFERRED)
        self.assertEqual(entry.deferrals, 20)
        self.assertFalse(entry.terminal)
        self.assertTrue(ledger.due("a#1"))

    def test_deferral_delay_is_capped(self) -> None:
        clock = FakeClock()
        ledger = Ledger(self.root / "ledger.json", clock=clock)
        ledger.mark_deferred("a#1", "a", "1", "resume", "busy", base=10.0, factor=2.0, cap=60.0)
        self.assertAlmostEqual(ledger.wait_remaining("a#1"), 10.0)
        for _ in range(9):
            ledger.mark_deferred("a#1", "a", "1", "resume", "busy", base=10.0, factor=2.0, cap=60.0)
        self.assertAlmostEqual(ledger.wait_remaining("a#1"), 60.0)
