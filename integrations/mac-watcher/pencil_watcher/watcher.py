"""The daemon loop.

Polling, not FSEvents. That is the correct choice here rather than a
compromise: the sync folder is a file-provider folder (iCloud Drive by default,
docs/08 q2), and file providers materialise entries without emitting the events
a native watch API reports. FSEvents will tell you a directory appeared before
its contents exist, will coalesce the writes that follow, and on an evicted or
re-downloaded item may not fire at all. The iPad side polls for exactly this
reason. A poll plus a settle delay sees the same truth every time and has no
bindings to install.
"""

from __future__ import annotations

import signal
import time
from pathlib import Path
from typing import Callable, List, Optional

from pencil_watcher import bundle as bundle_mod
from pencil_watcher import ledger as ledger_mod
from pencil_watcher import routes as routes_mod
from pencil_watcher.bundle import Bundle, SettleTracker
from pencil_watcher.config import Config
from pencil_watcher.ledger import Ledger
from pencil_watcher.logsetup import get_logger
from pencil_watcher.prompts import build_delivery_text
from pencil_watcher.runner import CommandRunner, SubprocessCommandRunner

_OUTCOME_TO_STATUS = {
    routes_mod.DELIVERED: ledger_mod.STATUS_DELIVERED,
    routes_mod.SKIPPED: ledger_mod.STATUS_SKIPPED,
    routes_mod.HELD: ledger_mod.STATUS_HELD,
}


class Watcher:
    def __init__(
        self,
        config: Config,
        runner: Optional[CommandRunner] = None,
        *,
        ledger: Optional[Ledger] = None,
        clock: Callable[[], float] = time.time,
        monotonic: Callable[[], float] = time.monotonic,
    ) -> None:
        self.config = config
        self.runner = runner or SubprocessCommandRunner()
        self.log = get_logger()
        self.clock = clock
        self.ledger = ledger or Ledger(config.ledger_path, clock=clock)
        self.settle = SettleTracker(config.settle_seconds, clock=monotonic)
        self._stop = False
        self._reported_exhausted: set = set()
        self._reported_waiting: set = set()

    # -- lifecycle ---------------------------------------------------------

    def stop(self, *_args) -> None:
        self._stop = True

    def install_signal_handlers(self) -> None:
        for sig in (signal.SIGINT, signal.SIGTERM):
            try:
                signal.signal(sig, self.stop)
            except (ValueError, OSError):  # not on the main thread
                pass

    def run_forever(self) -> int:
        self.install_signal_handlers()
        self.log.info(
            "watching %s (poll %.0fs, settle %.0fs, ledger %s)%s",
            self.config.outbox,
            self.config.poll_interval,
            self.config.settle_seconds,
            self.config.ledger_path,
            " [DRY RUN — nothing will be executed]" if self.runner.dry_run else "",
        )
        if not self.config.sync_root.is_dir():
            self.log.warning(
                "sync root %s does not exist yet; will keep polling", self.config.sync_root
            )
        while not self._stop:
            try:
                self.poll_once()
            except Exception as exc:  # a bad bundle must not kill the daemon
                self.log.exception("poll failed: %s", exc)
            slept = 0.0
            while slept < self.config.poll_interval and not self._stop:
                step = min(0.5, self.config.poll_interval - slept)
                time.sleep(step)
                slept += step
        self.log.info("stopped")
        return 0

    def run_once(self, sleep: Optional[Callable[[float], None]] = None) -> List[str]:
        """A single-shot pass, for --once and --dry-run.

        The settle state lives in memory, so a fresh process has never seen any
        bundle before and nothing can be settled on a first look. A one-shot run
        therefore does a priming pass, waits out the settle delay, and then does
        the real pass. Without this, --once could never deliver anything.
        """
        sleep = sleep or time.sleep
        self.poll_once()
        if self.config.settle_seconds > 0:
            sleep(self.config.settle_seconds + 0.5)
        return self.poll_once()

    # -- one pass ----------------------------------------------------------

    def poll_once(self) -> List[str]:
        """Scan outbox once. Returns the ledger keys acted on, for tests."""
        acted: List[str] = []
        for path in bundle_mod.discover(self.config.outbox):
            key = self.process(path)
            if key:
                acted.append(key)
        return acted

    def process(self, path: Path) -> Optional[str]:
        ready, reason = self.settle.check(path)
        if not ready:
            self.log.debug("bundle %s not ready: %s", path.name, reason)
            return None

        try:
            item = bundle_mod.load_bundle(path, self.config.sync_root)
        except OSError as exc:
            self.log.warning("bundle %s could not be hashed: %s", path.name, exc)
            return None

        key = item.key
        entry = self.ledger.get(key)

        if entry is not None and entry.terminal:
            if entry.status == ledger_mod.STATUS_EXHAUSTED and key not in self._reported_exhausted:
                self._reported_exhausted.add(key)
                self.log.error(
                    "bundle %s has exhausted %d delivery attempts via route=%s and will not be "
                    "retried: %s — fix the cause and run --forget %s to requeue",
                    item.rel_path,
                    entry.attempts,
                    entry.route or "?",
                    entry.last_error,
                    item.rel_path,
                )
            else:
                self.log.debug(
                    "bundle %s already %s; skipping", item.rel_path, entry.status
                )
            return None

        if entry is not None and not self.ledger.due(key):
            if key not in self._reported_waiting:
                self._reported_waiting.add(key)
                self.log.info(
                    "bundle %s waiting %.0fs before retry %d (last: %s)",
                    item.rel_path,
                    self.ledger.wait_remaining(key),
                    entry.attempts + 1,
                    entry.last_error,
                )
            return None
        self._reported_waiting.discard(key)

        return self.deliver(item)

    # -- delivery ----------------------------------------------------------

    def deliver(self, item: Bundle) -> Optional[str]:
        key = item.key
        return_path = bundle_mod.resolve_return_path(item, self.config.inbox)
        adapter = routes_mod.select(return_path)

        if (
            return_path.type not in routes_mod.ADAPTERS
            and return_path.type != adapter.name
        ):
            self.log.warning(
                "bundle %s has unrecognised returnPath.type=%r; treating as no return path",
                item.rel_path,
                return_path.type,
            )

        self.log.info(
            "bundle %s ready (%s) -> route %s", item.rel_path, return_path.described, adapter.name
        )

        if not adapter.enabled(self.config):
            note = "route %s is disabled in config" % adapter.name
            self.log.warning("bundle %s held: %s", item.rel_path, note)
            self.ledger.mark_terminal(
                key, item.rel_path, item.content_hash, ledger_mod.STATUS_HELD, adapter.name, note
            )
            return key

        text = self.build_text(item)
        ctx = routes_mod.DeliveryContext(
            bundle=item, return_path=return_path, text=text, config=self.config
        )

        if self.runner.dry_run:
            self.log.debug("DRY RUN plan for %s -> %s", item.rel_path, adapter.describe(ctx))

        outcome = adapter.deliver(ctx, self.runner)

        if self.runner.dry_run:
            # Nothing is recorded and nothing is executed in dry-run mode, so a
            # dry run can be repeated and never consumes a real delivery.
            self.log.info(
                "DRY RUN %s via %s would be: %s — %s",
                item.rel_path,
                adapter.name,
                outcome.status,
                outcome.detail,
            )
            self.settle.forget(item.path)
            return key

        if outcome.status in _OUTCOME_TO_STATUS:
            self.ledger.mark_terminal(
                key,
                item.rel_path,
                item.content_hash,
                _OUTCOME_TO_STATUS[outcome.status],
                adapter.name,
                outcome.detail,
            )
            level = self.log.info if outcome.status == routes_mod.DELIVERED else self.log.info
            level(
                "bundle %s %s via %s: %s",
                item.rel_path,
                outcome.status,
                adapter.name,
                outcome.detail,
            )
            return key

        if outcome.status == routes_mod.DEFERRED:
            entry = self.ledger.mark_deferred(
                key,
                item.rel_path,
                item.content_hash,
                adapter.name,
                outcome.detail,
                base=self.config.defer_base_seconds,
                factor=self.config.retry_factor,
                cap=self.config.defer_max_seconds,
            )
            self.log.info(
                "bundle %s deferred (hold #%d, next try in %.0fs): %s",
                item.rel_path,
                entry.deferrals,
                max(0.0, entry.next_attempt - self.clock()),
                outcome.detail,
            )
            return key

        entry = self.ledger.mark_failure(
            key,
            item.rel_path,
            item.content_hash,
            adapter.name,
            outcome.detail,
            base=self.config.retry_base_seconds,
            factor=self.config.retry_factor,
            cap=self.config.retry_max_seconds,
            max_attempts=self.config.max_attempts,
        )
        if entry.status == ledger_mod.STATUS_EXHAUSTED:
            self._reported_exhausted.add(key)
            self.log.error(
                "bundle %s FAILED permanently after %d attempts via %s: %s — the bundle is "
                "untouched; fix the cause and run --forget %s to requeue",
                item.rel_path,
                entry.attempts,
                adapter.name,
                outcome.detail,
                item.rel_path,
            )
        else:
            self.log.warning(
                "bundle %s delivery failed (attempt %d of %d, retry in %.0fs) via %s: %s",
                item.rel_path,
                entry.attempts,
                self.config.max_attempts,
                max(0.0, entry.next_attempt - self.clock()),
                adapter.name,
                outcome.detail,
            )
        return key

    def build_text(self, item: Bundle) -> str:
        return build_delivery_text(
            title=item.title(),
            review_text=item.read_review_text(),
            review_path=str(item.review_md),
            bundle_path=str(item.path),
            reply_path=str(item.reply_md),
            ink_path=str(item.ink_dir) if item.has_ink() else "",
            max_inline_chars=self.config.max_inline_chars,
        )
