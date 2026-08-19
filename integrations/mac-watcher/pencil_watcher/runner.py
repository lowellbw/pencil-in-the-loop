"""Command execution, behind an interface.

Nothing in the routes calls :mod:`subprocess` directly. Every route asks a
``CommandRunner`` to run a command, which means:

* ``--dry-run`` swaps in :class:`DryRunCommandRunner` and no process is ever
  started, at any layer;
* tests swap in :class:`FakeCommandRunner` and never shell out to ``claude``.
"""

from __future__ import annotations

import subprocess
from dataclasses import dataclass, field
from typing import Callable, List, Optional, Sequence

from pencil_watcher.logsetup import get_logger


@dataclass
class CommandResult:
    argv: List[str]
    returncode: int
    stdout: str = ""
    stderr: str = ""
    timed_out: bool = False
    not_found: bool = False

    @property
    def ok(self) -> bool:
        return self.returncode == 0 and not self.timed_out and not self.not_found

    def summary(self) -> str:
        if self.not_found:
            return "executable not found: %s" % (self.argv[0] if self.argv else "?")
        if self.timed_out:
            return "timed out"
        detail = (self.stderr or self.stdout or "").strip().replace("\n", " ")
        if len(detail) > 400:
            detail = detail[:400] + "…"
        return "exit %d%s" % (self.returncode, (": " + detail) if detail else "")


def shell_quote(argv: Sequence[str]) -> str:
    """Render argv the way a human would type it, for logs and --dry-run."""
    try:
        import shlex

        return " ".join(shlex.quote(a) for a in argv)
    except Exception:  # pragma: no cover - shlex is stdlib
        return " ".join(argv)


def preview_quote(argv: Sequence[str], limit: int = 120) -> str:
    """Like :func:`shell_quote`, but elides long arguments.

    The delivered review is one argv element and can be tens of thousands of
    characters. Log lines get this; the --dry-run line that promises to show
    exactly what would run gets the real thing.
    """
    parts = []
    for arg in argv:
        if len(arg) > limit:
            parts.append("<%d chars: %s…>" % (len(arg), arg[:60].replace("\n", " ")))
        else:
            parts.append(arg)
    return shell_quote(parts)


class CommandRunner:
    """Interface. ``run`` must never raise for an ordinary command failure."""

    dry_run = False

    def run(self, argv: Sequence[str], timeout: float = 120.0) -> CommandResult:
        raise NotImplementedError


class SubprocessCommandRunner(CommandRunner):
    def run(self, argv: Sequence[str], timeout: float = 120.0) -> CommandResult:
        argv = list(argv)
        try:
            proc = subprocess.run(
                argv,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                timeout=timeout,
                check=False,
            )
        except FileNotFoundError:
            return CommandResult(argv=argv, returncode=127, not_found=True)
        except subprocess.TimeoutExpired:
            return CommandResult(argv=argv, returncode=124, timed_out=True)
        except OSError as exc:
            return CommandResult(argv=argv, returncode=126, stderr=str(exc))
        return CommandResult(
            argv=argv,
            returncode=proc.returncode,
            stdout=proc.stdout.decode("utf-8", "replace") if proc.stdout else "",
            stderr=proc.stderr.decode("utf-8", "replace") if proc.stderr else "",
        )


class DryRunCommandRunner(CommandRunner):
    """Prints exactly what it would run. Starts no process, changes nothing."""

    dry_run = True

    def __init__(self, sink: Optional[Callable[[str], None]] = None) -> None:
        self.calls: List[List[str]] = []
        self._sink = sink

    def run(self, argv: Sequence[str], timeout: float = 120.0) -> CommandResult:
        argv = list(argv)
        self.calls.append(argv)
        line = "DRY RUN would execute: %s" % shell_quote(argv)
        if self._sink is not None:
            self._sink(line)
        else:
            get_logger().info(line)
        return CommandResult(argv=argv, returncode=0, stdout="")


@dataclass
class FakeCommandRunner(CommandRunner):
    """Test double. Answers from a queue or a callable, records every call."""

    responses: List[CommandResult] = field(default_factory=list)
    handler: Optional[Callable[[List[str]], CommandResult]] = None
    calls: List[List[str]] = field(default_factory=list)
    dry_run: bool = False

    def run(self, argv: Sequence[str], timeout: float = 120.0) -> CommandResult:
        argv = list(argv)
        self.calls.append(argv)
        if self.handler is not None:
            return self.handler(argv)
        if self.responses:
            result = self.responses.pop(0)
            result.argv = argv
            return result
        return CommandResult(argv=argv, returncode=0)
