"""Command line entry point."""

from __future__ import annotations

import argparse
import sys
from pathlib import Path
from typing import List, Optional

from pencil_watcher import __version__
from pencil_watcher import ledger as ledger_mod
from pencil_watcher.config import ConfigError, load_config
from pencil_watcher.ledger import Ledger
from pencil_watcher.logsetup import configure
from pencil_watcher.runner import DryRunCommandRunner, SubprocessCommandRunner
from pencil_watcher.watcher import Watcher


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="pencil-watcher",
        description=(
            "Watch <sync root>/outbox for pencil review bundles and deliver each one back "
            "into the conversation its document came from."
        ),
    )
    parser.add_argument("--config", type=Path, default=None, help="path to config.json (default ~/.pencil-loop/config.json)")
    parser.add_argument("--sync-root", default=None, help="override the sync folder from config")
    parser.add_argument("--interval", type=float, default=None, help="poll interval in seconds")
    parser.add_argument("--settle", type=float, default=None, help="settle delay in seconds")
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="print exactly what would be run, run nothing, write nothing to the ledger",
    )
    parser.add_argument(
        "--foreground",
        action="store_true",
        help="debug mode: stay attached to the terminal with verbose per-poll logging",
    )
    parser.add_argument("--once", action="store_true", help="do a single pass and exit")
    parser.add_argument("--verbose", "-v", action="store_true", help="debug-level logging")
    parser.add_argument("--list", action="store_true", help="print the ledger and exit")
    parser.add_argument(
        "--forget",
        metavar="BUNDLE",
        default=None,
        help="drop a bundle from the ledger so it is delivered again (path relative to the sync root)",
    )
    parser.add_argument("--version", action="version", version="pencil-watcher %s" % __version__)
    return parser


def _print_ledger(ledger: Ledger) -> int:
    entries = sorted(ledger.entries(), key=lambda e: (e.status, e.bundle))
    if not entries:
        print("ledger is empty: %s" % ledger.path)
        return 0
    print("%-11s %-7s %-9s %s" % ("STATUS", "TRIES", "ROUTE", "BUNDLE"))
    for entry in entries:
        print(
            "%-11s %-7s %-9s %s"
            % (entry.status, entry.attempts, entry.route or "-", entry.bundle)
        )
        if entry.last_error:
            print("%-30s%s" % ("", entry.last_error))
    exhausted = [e for e in entries if e.status == ledger_mod.STATUS_EXHAUSTED]
    if exhausted:
        print(
            "\n%d bundle(s) exhausted their retries and need attention." % len(exhausted)
        )
        return 1
    return 0


def main(argv: Optional[List[str]] = None) -> int:
    args = build_parser().parse_args(argv)

    overrides = {}
    if args.sync_root:
        overrides["sync_root"] = args.sync_root
    if args.interval:
        overrides["poll_interval"] = args.interval
    if args.settle is not None:
        overrides["settle_seconds"] = args.settle

    try:
        config = load_config(args.config, overrides)
    except ConfigError as exc:
        print("pencil-watcher: %s" % exc, file=sys.stderr)
        return 2

    verbose = args.verbose or args.foreground
    log = configure(config.log_path, verbose=verbose)

    ledger = Ledger(config.ledger_path)

    if args.list:
        return _print_ledger(ledger)

    if args.forget:
        removed = ledger.forget(args.forget)
        print("removed %d ledger entr%s for %s" % (removed, "y" if removed == 1 else "ies", args.forget))
        return 0 if removed else 1

    runner = DryRunCommandRunner(sink=log.info) if args.dry_run else SubprocessCommandRunner()
    watcher = Watcher(config, runner=runner, ledger=ledger)

    if args.foreground:
        log.debug(
            "foreground mode: config=%s sync_root=%s log=%s",
            config.source_path or "(defaults)",
            config.sync_root,
            config.log_path,
        )

    if args.once:
        acted = watcher.run_once()
        log.info("single pass complete, acted on %d bundle(s)", len(acted))
        return 0

    return watcher.run_forever()
