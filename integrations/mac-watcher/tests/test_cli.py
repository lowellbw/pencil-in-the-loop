"""CLI smoke tests. main() is the thing launchd actually runs."""

from __future__ import annotations

import io
import json
from contextlib import redirect_stdout

from pencil_watcher.cli import main
from tests.helpers import TempDirTestCase, make_config, write_bundle, write_meta

POKE_ORIGIN = {"kind": "cowork", "returnPath": {"type": "poke", "triggerId": "trig_1"}}


class CliTests(TempDirTestCase):
    def setUp(self) -> None:
        super().setUp()
        self.config = make_config(self.root)
        self.config_path = self.root / "config.json"
        self.config_path.write_text(
            json.dumps(
                {
                    "syncRoot": str(self.config.sync_root),
                    "watcher": {
                        "stateDir": str(self.config.state_dir),
                        "settleSeconds": 0,
                        "busyCommand": None,
                        # a command that cannot exist, so a non-dry run fails
                        # cleanly instead of finding a real binary
                        "routes": {"poke": {"command": ["pencil-watcher-no-such-binary", "{text}"]}},
                    },
                }
            ),
            encoding="utf-8",
        )
        self.base = ["--config", str(self.config_path)]

    def run_cli(self, *args) -> tuple:
        buffer = io.StringIO()
        with redirect_stdout(buffer):
            code = main(self.base + list(args))
        return code, buffer.getvalue()

    def test_missing_config_exits_with_a_clear_error(self) -> None:
        code = main(["--config", str(self.root / "nope.json"), "--list"])
        self.assertEqual(code, 2)

    def test_list_on_an_empty_ledger(self) -> None:
        code, out = self.run_cli("--list")
        self.assertEqual(code, 0)
        self.assertIn("ledger is empty", out)

    def test_dry_run_once_prints_the_command_and_writes_nothing(self) -> None:
        write_bundle(self.config)
        write_meta(self.config, origin=POKE_ORIGIN)
        code, out = self.run_cli("--dry-run", "--once")
        self.assertEqual(code, 0)
        self.assertIn("DRY RUN would execute:", out)
        self.assertIn("pencil-watcher-no-such-binary", out)
        self.assertFalse(self.config.ledger_path.exists())

    def test_a_real_run_with_a_missing_binary_fails_and_is_recorded(self) -> None:
        write_bundle(self.config)
        write_meta(self.config, origin=POKE_ORIGIN)
        code, _ = self.run_cli("--once")
        self.assertEqual(code, 0)
        ledger = json.loads(self.config.ledger_path.read_text(encoding="utf-8"))
        entry = list(ledger["entries"].values())[0]
        self.assertEqual(entry["status"], "failed")
        self.assertIn("not found", entry["last_error"])

    def test_forget_reports_when_there_is_nothing_to_forget(self) -> None:
        code, out = self.run_cli("--forget", "outbox/nothing.review")
        self.assertEqual(code, 1)
        self.assertIn("removed 0", out)

    def test_foreground_implies_verbose_and_still_does_one_pass(self) -> None:
        write_bundle(self.config)
        code, _ = self.run_cli("--foreground", "--once", "--dry-run")
        self.assertEqual(code, 0)
