"""Route selection and every adapter, with a fake command runner."""

from __future__ import annotations

from pencil_watcher import routes as routes_mod
from pencil_watcher.bundle import ReturnPath, load_bundle
from pencil_watcher.routes import DeliveryContext, render, select
from pencil_watcher.runner import CommandResult, FakeCommandRunner
from tests.helpers import TempDirTestCase, make_config, write_bundle


class SelectionTests(TempDirTestCase):
    def test_every_return_path_type_maps_to_an_adapter(self) -> None:
        expected = {
            "poke": "poke",
            "checkin": "checkin",
            "cloud": "cloud",
            "resume": "resume",
            "none": "none",
        }
        for rp_type, adapter_name in expected.items():
            with self.subTest(rp_type=rp_type):
                self.assertEqual(select(ReturnPath(type=rp_type)).name, adapter_name)

    def test_codex_kind_overrides_the_type(self) -> None:
        self.assertEqual(select(ReturnPath(type="resume", kind="codex")).name, "codex")
        self.assertEqual(select(ReturnPath(type="cloud", kind="codex")).name, "codex")

    def test_claude_code_kind_does_not_override(self) -> None:
        self.assertEqual(select(ReturnPath(type="resume", kind="claude-code")).name, "resume")

    def test_unknown_type_falls_back_to_none(self) -> None:
        self.assertEqual(select(ReturnPath(type="telepathy")).name, "none")

    def test_case_and_whitespace_tolerant(self) -> None:
        self.assertEqual(select(ReturnPath(type=" Poke ")).name, "poke")


class RenderTests(TempDirTestCase):
    def test_placeholders_are_substituted_per_argument(self) -> None:
        argv = render(["claude", "--cloud", "{sessionId}", "-p", "{text}"], {"sessionId": "s1", "text": "hello"})
        self.assertEqual(argv, ["claude", "--cloud", "s1", "-p", "hello"])

    def test_shell_metacharacters_stay_inside_one_argument(self) -> None:
        nasty = 'a "quote"; rm -rf / `whoami`\nnewline'
        argv = render(["claude", "-p", "{text}"], {"text": nasty})
        self.assertEqual(argv[2], nasty)
        self.assertEqual(len(argv), 3)


class AdapterTests(TempDirTestCase):
    def context(self, return_path: ReturnPath, config=None) -> DeliveryContext:
        config = config or make_config(self.root)
        item = load_bundle(write_bundle(config), config.sync_root)
        return DeliveryContext(bundle=item, return_path=return_path, text="REVIEW TEXT", config=config)

    def test_poke_fires_the_trigger(self) -> None:
        ctx = self.context(ReturnPath(type="poke", kind="cowork", trigger_id="trig_1"))
        runner = FakeCommandRunner()
        outcome = routes_mod.ADAPTERS["poke"].deliver(ctx, runner)
        self.assertEqual(outcome.status, routes_mod.DELIVERED)
        self.assertEqual(len(runner.calls), 1)
        self.assertIn("trig_1", runner.calls[0])
        self.assertIn("REVIEW TEXT", runner.calls[0])

    def test_poke_without_a_trigger_id_fails_without_running_anything(self) -> None:
        ctx = self.context(ReturnPath(type="poke", kind="cowork"))
        runner = FakeCommandRunner()
        outcome = routes_mod.ADAPTERS["poke"].deliver(ctx, runner)
        self.assertEqual(outcome.status, routes_mod.FAILED)
        self.assertEqual(runner.calls, [])

    def test_checkin_is_a_no_op(self) -> None:
        """Route 2: the session collects the review itself. Never double-deliver."""
        ctx = self.context(ReturnPath(type="checkin", kind="cowork"))
        runner = FakeCommandRunner()
        outcome = routes_mod.ADAPTERS["checkin"].deliver(ctx, runner)
        self.assertEqual(outcome.status, routes_mod.SKIPPED)
        self.assertEqual(runner.calls, [])

    def test_cloud_uses_the_documented_shape(self) -> None:
        ctx = self.context(ReturnPath(type="cloud", kind="claude-code", session_id="sess-1"))
        runner = FakeCommandRunner()
        outcome = routes_mod.ADAPTERS["cloud"].deliver(ctx, runner)
        self.assertEqual(outcome.status, routes_mod.DELIVERED)
        self.assertEqual(runner.calls[0][:4], ["claude", "--cloud", "sess-1", "-p"])

    def test_resume_uses_the_documented_shape(self) -> None:
        ctx = self.context(ReturnPath(type="resume", kind="claude-code", session_id="sess-2"))
        runner = FakeCommandRunner()
        outcome = routes_mod.ADAPTERS["resume"].deliver(ctx, runner)
        self.assertEqual(outcome.status, routes_mod.DELIVERED)
        self.assertEqual(runner.calls[0], ["claude", "-p", "REVIEW TEXT", "--resume", "sess-2"])

    def test_running_local_session_defers_instead_of_delivering(self) -> None:
        """Route 5: cannot inject into a running session; hold the bundle."""
        config = make_config(self.root, busy_command=["pgrep", "-x", "claude"])
        ctx = self.context(ReturnPath(type="resume", session_id="sess-3"), config=config)
        runner = FakeCommandRunner(handler=lambda argv: CommandResult(argv=argv, returncode=0))
        outcome = routes_mod.ADAPTERS["resume"].deliver(ctx, runner)
        self.assertEqual(outcome.status, routes_mod.DEFERRED)
        self.assertEqual(len(runner.calls), 1, "only the busy probe should have run")
        self.assertEqual(runner.calls[0], ["pgrep", "-x", "claude"])

    def test_idle_local_session_delivers_after_the_probe(self) -> None:
        config = make_config(self.root, busy_command=["pgrep", "-x", "claude"])
        ctx = self.context(ReturnPath(type="resume", session_id="sess-3"), config=config)
        runner = FakeCommandRunner(handler=lambda argv: CommandResult(argv=argv, returncode=1 if argv[0] == "pgrep" else 0))
        outcome = routes_mod.ADAPTERS["resume"].deliver(ctx, runner)
        self.assertEqual(outcome.status, routes_mod.DELIVERED)
        self.assertEqual(len(runner.calls), 2)

    def test_a_missing_probe_binary_does_not_look_busy(self) -> None:
        config = make_config(self.root, busy_command=["pgrep", "-x", "claude"])
        ctx = self.context(ReturnPath(type="resume", session_id="s"), config=config)
        runner = FakeCommandRunner(
            handler=lambda argv: CommandResult(argv=argv, returncode=0, not_found=True)
            if argv[0] == "pgrep"
            else CommandResult(argv=argv, returncode=0)
        )
        self.assertEqual(routes_mod.ADAPTERS["resume"].deliver(ctx, runner).status, routes_mod.DELIVERED)

    def test_codex_uses_the_codex_binary(self) -> None:
        ctx = self.context(ReturnPath(type="resume", kind="codex", session_id="cx-1"))
        runner = FakeCommandRunner()
        outcome = routes_mod.ADAPTERS["codex"].deliver(ctx, runner)
        self.assertEqual(outcome.status, routes_mod.DELIVERED)
        self.assertEqual(runner.calls[0][0], "codex")

    def test_none_holds_and_runs_nothing(self) -> None:
        """Route 7: the iPad has its own share-sheet fallback. Invent nothing."""
        ctx = self.context(ReturnPath(type="none"))
        runner = FakeCommandRunner()
        outcome = routes_mod.ADAPTERS["none"].deliver(ctx, runner)
        self.assertEqual(outcome.status, routes_mod.HELD)
        self.assertEqual(runner.calls, [])

    def test_failed_command_is_reported_not_raised(self) -> None:
        ctx = self.context(ReturnPath(type="cloud", session_id="s"))
        runner = FakeCommandRunner(responses=[CommandResult(argv=[], returncode=1, stderr="no such session")])
        outcome = routes_mod.ADAPTERS["cloud"].deliver(ctx, runner)
        self.assertEqual(outcome.status, routes_mod.FAILED)
        self.assertIn("no such session", outcome.detail)

    def test_missing_binary_is_reported_clearly(self) -> None:
        ctx = self.context(ReturnPath(type="cloud", session_id="s"))
        runner = FakeCommandRunner(responses=[CommandResult(argv=[], returncode=127, not_found=True)])
        outcome = routes_mod.ADAPTERS["cloud"].deliver(ctx, runner)
        self.assertEqual(outcome.status, routes_mod.FAILED)
        self.assertIn("not found", outcome.detail)

    def test_empty_command_template_fails_loudly(self) -> None:
        config = make_config(self.root)
        config.route("cloud").command = []
        ctx = self.context(ReturnPath(type="cloud", session_id="s"), config=config)
        runner = FakeCommandRunner()
        outcome = routes_mod.ADAPTERS["cloud"].deliver(ctx, runner)
        self.assertEqual(outcome.status, routes_mod.FAILED)
        self.assertEqual(runner.calls, [])

    def test_each_route_can_be_disabled_in_config(self) -> None:
        config = make_config(self.root)
        for name in ("poke", "checkin", "cloud", "resume", "codex"):
            with self.subTest(route=name):
                config.route(name).enabled = False
                self.assertFalse(routes_mod.ADAPTERS[name].enabled(config))
                config.route(name).enabled = True
                self.assertTrue(routes_mod.ADAPTERS[name].enabled(config))

    def test_describe_never_runs_anything(self) -> None:
        runner = FakeCommandRunner()
        for name, adapter in routes_mod.ADAPTERS.items():
            ctx = self.context(ReturnPath(type=name, session_id="s", trigger_id="t"))
            self.assertTrue(adapter.describe(ctx))
        self.assertEqual(runner.calls, [])
