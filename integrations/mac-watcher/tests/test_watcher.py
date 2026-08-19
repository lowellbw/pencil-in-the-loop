"""End-to-end watcher behaviour: dedupe, dry-run, retry, deferral, prompts."""

from __future__ import annotations

import json

from pencil_watcher import ledger as ledger_mod
from pencil_watcher import prompts
from pencil_watcher.bundle import SettleTracker
from pencil_watcher.ledger import Ledger
from pencil_watcher.runner import CommandResult, DryRunCommandRunner, FakeCommandRunner
from pencil_watcher.watcher import Watcher
from tests.helpers import FakeClock, TempDirTestCase, make_config, write_bundle, write_meta

POKE_ORIGIN = {"kind": "cowork", "sessionId": "8f3c", "returnPath": {"type": "poke", "triggerId": "trig_1"}}


class WatcherTestCase(TempDirTestCase):
    def build(self, *, runner=None, config=None, settle=0.0):
        config = config or make_config(self.root)
        config.settle_seconds = settle
        self.clock = FakeClock()
        self.mono = FakeClock(0.0)
        ledger = Ledger(config.ledger_path, clock=self.clock)
        watcher = Watcher(
            config,
            runner=runner or FakeCommandRunner(),
            ledger=ledger,
            clock=self.clock,
            monotonic=self.mono,
        )
        # SettleTracker is created in __init__ with the real monotonic clock;
        # replace it so tests control time completely.
        watcher.settle = SettleTracker(config.settle_seconds, clock=self.mono)
        return config, watcher

    def settle_in(self, watcher) -> None:
        """Run the passes needed to get past the settle delay."""
        watcher.poll_once()
        self.mono.advance(watcher.config.settle_seconds + 1)


class DeliveryTests(WatcherTestCase):
    def test_a_poke_bundle_is_delivered_once_and_only_once(self) -> None:
        runner = FakeCommandRunner()
        config, watcher = self.build(runner=runner)
        write_bundle(config)
        write_meta(config, origin=POKE_ORIGIN)

        self.settle_in(watcher)
        watcher.poll_once()
        self.assertEqual(len(runner.calls), 1)
        self.assertIn("trig_1", runner.calls[0])

        for _ in range(5):
            self.mono.advance(60)
            self.clock.advance(60)
            watcher.poll_once()
        self.assertEqual(len(runner.calls), 1, "bundle must never be delivered twice")

    def test_dedupe_survives_a_daemon_restart(self) -> None:
        runner = FakeCommandRunner()
        config, watcher = self.build(runner=runner)
        write_bundle(config)
        write_meta(config, origin=POKE_ORIGIN)
        self.settle_in(watcher)
        watcher.poll_once()
        self.assertEqual(len(runner.calls), 1)

        _, watcher2 = self.build(runner=runner, config=config)
        watcher2.ledger = Ledger(config.ledger_path, clock=self.clock)
        self.settle_in(watcher2)
        watcher2.poll_once()
        self.assertEqual(len(runner.calls), 1, "the ledger on disk must stop a redelivery")

    def test_an_edited_bundle_is_delivered_again(self) -> None:
        runner = FakeCommandRunner()
        config, watcher = self.build(runner=runner)
        path = write_bundle(config)
        write_meta(config, origin=POKE_ORIGIN)
        self.settle_in(watcher)
        watcher.poll_once()
        self.assertEqual(len(runner.calls), 1)

        (path / "review.md").write_text("# Review — Auth refactor plan\n\nnew content\n", encoding="utf-8")
        self.settle_in(watcher)
        watcher.poll_once()
        self.assertEqual(len(runner.calls), 2)

    def test_checkin_delivers_nothing(self) -> None:
        runner = FakeCommandRunner()
        config, watcher = self.build(runner=runner)
        write_bundle(config)
        write_meta(config, origin={"kind": "cowork", "returnPath": {"type": "checkin"}})
        self.settle_in(watcher)
        watcher.poll_once()
        self.assertEqual(runner.calls, [])
        entry = list(watcher.ledger.entries())[0]
        self.assertEqual(entry.status, ledger_mod.STATUS_SKIPPED)

    def test_no_return_path_leaves_the_bundle_alone(self) -> None:
        runner = FakeCommandRunner()
        config, watcher = self.build(runner=runner)
        path = write_bundle(config)
        before = sorted(p.name for p in path.iterdir())
        self.settle_in(watcher)
        watcher.poll_once()
        self.assertEqual(runner.calls, [])
        self.assertEqual(sorted(p.name for p in path.iterdir()), before)
        self.assertEqual(list(watcher.ledger.entries())[0].status, ledger_mod.STATUS_HELD)

    def test_a_disabled_route_holds_rather_than_delivering(self) -> None:
        runner = FakeCommandRunner()
        config, watcher = self.build(runner=runner)
        config.route("poke").enabled = False
        write_bundle(config)
        write_meta(config, origin=POKE_ORIGIN)
        self.settle_in(watcher)
        watcher.poll_once()
        self.assertEqual(runner.calls, [])
        self.assertEqual(list(watcher.ledger.entries())[0].status, ledger_mod.STATUS_HELD)

    def test_an_unsettled_bundle_is_not_delivered(self) -> None:
        runner = FakeCommandRunner()
        config, watcher = self.build(runner=runner, settle=5.0)
        write_bundle(config)
        write_meta(config, origin=POKE_ORIGIN)
        watcher.poll_once()
        self.mono.advance(2)
        watcher.poll_once()
        self.assertEqual(runner.calls, [], "must not fire inside the settle window")
        self.mono.advance(4)
        watcher.poll_once()
        self.assertEqual(len(runner.calls), 1)

    def test_a_bundle_with_no_manifest_is_ignored_entirely(self) -> None:
        runner = FakeCommandRunner()
        config, watcher = self.build(runner=runner)
        path = config.outbox / "2026-08-18-a.review"
        path.mkdir(parents=True)
        (path / "review.md").write_text("# Review — a\n", encoding="utf-8")
        write_meta(config, "2026-08-18-a", origin=POKE_ORIGIN)
        for _ in range(3):
            self.mono.advance(10)
            watcher.poll_once()
        self.assertEqual(runner.calls, [])
        self.assertEqual(list(watcher.ledger.entries()), [])


class SinglePassTests(WatcherTestCase):
    """--once must be able to deliver, despite the settle state being in memory."""

    def test_run_once_primes_then_delivers(self) -> None:
        runner = FakeCommandRunner()
        config, watcher = self.build(runner=runner, settle=5.0)
        write_bundle(config)
        write_meta(config, origin=POKE_ORIGIN)

        slept = []

        def sleep(seconds: float) -> None:
            slept.append(seconds)
            self.mono.advance(seconds)

        watcher.run_once(sleep=sleep)
        self.assertEqual(slept, [5.5])
        self.assertEqual(len(runner.calls), 1)

    def test_run_once_still_refuses_a_bundle_that_is_changing(self) -> None:
        runner = FakeCommandRunner()
        config, watcher = self.build(runner=runner, settle=5.0)
        path = write_bundle(config)
        write_meta(config, origin=POKE_ORIGIN)

        def sleep(seconds: float) -> None:
            self.mono.advance(seconds)
            (path / "ink").mkdir(exist_ok=True)
            (path / "ink" / "page-01.png").write_bytes(b"still downloading")

        watcher.run_once(sleep=sleep)
        self.assertEqual(runner.calls, [])


class DryRunTests(WatcherTestCase):
    def test_dry_run_runs_nothing_and_writes_nothing(self) -> None:
        printed = []
        runner = DryRunCommandRunner(sink=printed.append)
        config, watcher = self.build(runner=runner)
        write_bundle(config)
        write_meta(config, origin=POKE_ORIGIN)

        self.settle_in(watcher)
        watcher.poll_once()

        self.assertEqual(len(runner.calls), 1, "the argv should have been computed")
        self.assertTrue(printed and printed[0].startswith("DRY RUN would execute:"))
        self.assertIn("trig_1", printed[0])
        self.assertFalse(config.ledger_path.exists(), "dry run must not write the ledger")
        self.assertEqual(list(watcher.ledger.entries()), [])

    def test_dry_run_is_repeatable_and_does_not_consume_the_delivery(self) -> None:
        runner = DryRunCommandRunner(sink=lambda _line: None)
        config, watcher = self.build(runner=runner)
        write_bundle(config)
        write_meta(config, origin=POKE_ORIGIN)
        for _ in range(3):
            self.settle_in(watcher)
            watcher.poll_once()
        self.assertEqual(len(runner.calls), 3)
        self.assertFalse(config.ledger_path.exists())

        real = FakeCommandRunner()
        watcher.runner = real
        self.settle_in(watcher)
        watcher.poll_once()
        self.assertEqual(len(real.calls), 1, "a real run after dry runs must still deliver")

    def test_dry_run_leaves_the_bundle_untouched(self) -> None:
        runner = DryRunCommandRunner(sink=lambda _line: None)
        config, watcher = self.build(runner=runner)
        path = write_bundle(config, ink=["ink/page-01.png"])
        write_meta(config, origin=POKE_ORIGIN)
        before = {p.name: p.stat().st_mtime_ns for p in path.rglob("*")}
        self.settle_in(watcher)
        watcher.poll_once()
        after = {p.name: p.stat().st_mtime_ns for p in path.rglob("*")}
        self.assertEqual(before, after)


class RetryTests(WatcherTestCase):
    def failing_runner(self) -> FakeCommandRunner:
        return FakeCommandRunner(handler=lambda argv: CommandResult(argv=argv, returncode=1, stderr="nope"))

    def test_failure_retries_with_growing_backoff_then_exhausts(self) -> None:
        runner = self.failing_runner()
        config, watcher = self.build(runner=runner)
        config.max_attempts = 3
        config.retry_base_seconds = 30.0
        write_bundle(config)
        write_meta(config, origin=POKE_ORIGIN)

        self.settle_in(watcher)
        watcher.poll_once()
        self.assertEqual(len(runner.calls), 1)
        entry = list(watcher.ledger.entries())[0]
        self.assertEqual(entry.status, ledger_mod.STATUS_FAILED)

        # inside the backoff window: no second attempt
        self.clock.advance(20)
        self.settle_in(watcher)
        watcher.poll_once()
        self.assertEqual(len(runner.calls), 1)

        # backoff elapsed
        self.clock.advance(20)
        self.settle_in(watcher)
        watcher.poll_once()
        self.assertEqual(len(runner.calls), 2)

        # second backoff is longer: 60s, so 40s is not enough
        self.clock.advance(40)
        self.settle_in(watcher)
        watcher.poll_once()
        self.assertEqual(len(runner.calls), 2)

        self.clock.advance(30)
        self.settle_in(watcher)
        watcher.poll_once()
        self.assertEqual(len(runner.calls), 3)

        entry = list(watcher.ledger.entries())[0]
        self.assertEqual(entry.status, ledger_mod.STATUS_EXHAUSTED)

        # exhausted means it stops, and stays surfaced
        self.clock.advance(100_000)
        self.settle_in(watcher)
        watcher.poll_once()
        self.assertEqual(len(runner.calls), 3)

    def test_a_failed_bundle_is_left_untouched_on_disk(self) -> None:
        runner = self.failing_runner()
        config, watcher = self.build(runner=runner)
        path = write_bundle(config)
        write_meta(config, origin=POKE_ORIGIN)
        before = sorted(p.name for p in path.rglob("*"))
        self.settle_in(watcher)
        watcher.poll_once()
        self.assertEqual(sorted(p.name for p in path.rglob("*")), before)

    def test_a_transient_failure_succeeds_on_retry(self) -> None:
        results = [CommandResult(argv=[], returncode=1, stderr="busy"), CommandResult(argv=[], returncode=0)]
        runner = FakeCommandRunner(responses=results)
        config, watcher = self.build(runner=runner)
        write_bundle(config)
        write_meta(config, origin=POKE_ORIGIN)

        self.settle_in(watcher)
        watcher.poll_once()
        self.clock.advance(60)
        self.settle_in(watcher)
        watcher.poll_once()

        self.assertEqual(len(runner.calls), 2)
        self.assertEqual(list(watcher.ledger.entries())[0].status, ledger_mod.STATUS_DELIVERED)

    def test_forget_requeues_an_exhausted_bundle(self) -> None:
        runner = self.failing_runner()
        config, watcher = self.build(runner=runner)
        config.max_attempts = 1
        write_bundle(config)
        write_meta(config, origin=POKE_ORIGIN)
        self.settle_in(watcher)
        watcher.poll_once()
        self.assertEqual(list(watcher.ledger.entries())[0].status, ledger_mod.STATUS_EXHAUSTED)

        self.assertEqual(watcher.ledger.forget("outbox/2026-08-18-auth-refactor-plan.review"), 1)
        watcher._reported_exhausted.clear()
        self.settle_in(watcher)
        watcher.poll_once()
        self.assertEqual(len(runner.calls), 2)


class DeferralTests(WatcherTestCase):
    """Route 5: hold the bundle while a local session is running, fire when free."""

    def test_a_busy_session_holds_the_bundle_and_fires_when_it_frees_up(self) -> None:
        state = {"busy": True}

        def handler(argv):
            if argv[0] == "pgrep":
                return CommandResult(argv=argv, returncode=0 if state["busy"] else 1)
            return CommandResult(argv=argv, returncode=0)

        runner = FakeCommandRunner(handler=handler)
        config = make_config(self.root, busy_command=["pgrep", "-x", "claude"])
        config, watcher = self.build(runner=runner, config=config)
        write_bundle(config)
        write_meta(config, origin={"kind": "claude-code", "returnPath": {"type": "resume", "sessionId": "s1"}})

        self.settle_in(watcher)
        watcher.poll_once()
        entry = list(watcher.ledger.entries())[0]
        self.assertEqual(entry.status, ledger_mod.STATUS_DEFERRED)
        self.assertEqual(entry.deferrals, 1)
        delivery_calls = [c for c in runner.calls if c[0] == "claude"]
        self.assertEqual(delivery_calls, [])

        # still busy at the next due time
        self.clock.advance(1000)
        self.settle_in(watcher)
        watcher.poll_once()
        self.assertEqual(list(watcher.ledger.entries())[0].deferrals, 2)

        # session frees up
        state["busy"] = False
        self.clock.advance(1000)
        self.settle_in(watcher)
        watcher.poll_once()
        entry = list(watcher.ledger.entries())[0]
        self.assertEqual(entry.status, ledger_mod.STATUS_DELIVERED)
        delivery_calls = [c for c in runner.calls if c[0] == "claude"]
        self.assertEqual(len(delivery_calls), 1)
        self.assertIn("--resume", delivery_calls[0])

    def test_deferral_respects_its_own_backoff(self) -> None:
        runner = FakeCommandRunner(handler=lambda argv: CommandResult(argv=argv, returncode=0))
        config = make_config(self.root, busy_command=["pgrep", "-x", "claude"])
        config, watcher = self.build(runner=runner, config=config)
        config.defer_base_seconds = 10.0
        write_bundle(config)
        write_meta(config, origin={"kind": "claude-code", "returnPath": {"type": "resume", "sessionId": "s1"}})

        self.settle_in(watcher)
        watcher.poll_once()
        probes = len(runner.calls)
        self.clock.advance(5)
        self.settle_in(watcher)
        watcher.poll_once()
        self.assertEqual(len(runner.calls), probes, "must not re-probe inside the defer backoff")
        self.clock.advance(10)
        self.settle_in(watcher)
        watcher.poll_once()
        self.assertEqual(len(runner.calls), probes + 1)


class PromptTests(WatcherTestCase):
    def test_delivered_text_tells_the_agent_where_to_write_its_reply(self) -> None:
        runner = FakeCommandRunner()
        config, watcher = self.build(runner=runner)
        path = write_bundle(config, ink=["ink/page-01.png"])
        write_meta(config, origin=POKE_ORIGIN)
        self.settle_in(watcher)
        watcher.poll_once()

        text = [arg for arg in runner.calls[0] if "Review" in arg or "reply.md" in arg]
        self.assertTrue(text)
        delivered = "\n".join(text)
        self.assertIn(str(path / "reply.md"), delivered)
        self.assertIn("Auth refactor plan", delivered)
        self.assertIn(str(path / "ink"), delivered)

    def test_the_reply_instruction_is_one_named_constant(self) -> None:
        self.assertIn("{reply_path}", prompts.REPLY_CHANNEL_INSTRUCTION)
        built = prompts.build_delivery_text(
            title="T",
            review_text="body",
            review_path="/r/review.md",
            bundle_path="/r",
            reply_path="/r/reply.md",
        )
        self.assertIn("/r/reply.md", built)

    def test_an_oversized_review_is_pointed_at_rather_than_inlined(self) -> None:
        runner = FakeCommandRunner()
        config, watcher = self.build(runner=runner)
        config.max_inline_chars = 100
        path = write_bundle(config, review_md="# Review — Big\n\n" + ("x" * 5000))
        write_meta(config, origin=POKE_ORIGIN)
        self.settle_in(watcher)
        watcher.poll_once()
        delivered = "\n".join(runner.calls[0])
        self.assertNotIn("x" * 200, delivered)
        self.assertIn(str(path / "review.md"), delivered)
        self.assertIn(str(path / "reply.md"), delivered)


class ConfigTests(TempDirTestCase):
    def test_config_file_round_trip(self) -> None:
        from pencil_watcher.config import ConfigError, load_config

        path = self.root / "config.json"
        path.write_text(
            json.dumps(
                {
                    "syncRoot": str(self.root / "sync"),
                    "watcher": {
                        "pollIntervalSeconds": 7,
                        "settleSeconds": 3,
                        "stateDir": str(self.root / "state"),
                        "busyCommand": None,
                        "routes": {"poke": {"enabled": False}, "cloud": {"command": ["mycli", "{text}"]}},
                    },
                }
            ),
            encoding="utf-8",
        )
        config = load_config(path)
        self.assertEqual(config.poll_interval, 7)
        self.assertEqual(config.settle_seconds, 3)
        self.assertEqual(config.outbox, self.root / "sync" / "outbox")
        self.assertFalse(config.route("poke").enabled)
        self.assertEqual(config.route("cloud").command, ["mycli", "{text}"])
        self.assertIsNone(config.busy_command)
        self.assertEqual(config.ledger_path, self.root / "state" / "watcher-ledger.json")

        with self.assertRaises(ConfigError):
            load_config(self.root / "missing.json")

    def test_reader_folder_alias_and_env_var_are_accepted(self) -> None:
        """Stay in step with integrations/cowork-skill, which writes this file."""
        import os

        from pencil_watcher.config import load_config

        path = self.root / "config.json"
        path.write_text(json.dumps({"readerFolder": str(self.root / "alias")}), encoding="utf-8")
        self.assertEqual(load_config(path).sync_root, self.root / "alias")

        os.environ["PENCIL_LOOP_READER_FOLDER"] = str(self.root / "fromenv")
        self.addCleanup(os.environ.pop, "PENCIL_LOOP_READER_FOLDER", None)
        self.assertEqual(load_config(path).sync_root, self.root / "fromenv")

    def test_cli_sync_root_overrides_the_file(self) -> None:
        from pencil_watcher.config import load_config

        path = self.root / "config.json"
        path.write_text(json.dumps({"syncRoot": "/nope"}), encoding="utf-8")
        config = load_config(path, {"sync_root": str(self.root / "other")})
        self.assertEqual(config.sync_root, self.root / "other")
