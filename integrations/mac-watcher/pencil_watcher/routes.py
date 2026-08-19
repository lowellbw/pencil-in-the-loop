"""Delivery routes, one adapter each, behind one small interface.

Every route in docs/06 is a :class:`RouteAdapter`. The watcher never knows how
a route works; it hands the adapter a :class:`DeliveryContext` and a
``CommandRunner`` and reads back an :class:`Outcome`. That is deliberate —
docs/08 question 7 flags the poke semantics and the ``claude --cloud`` shape as
unverified, so each one needs to be replaceable on its own, disableable on its
own, and inspectable with --dry-run without being run.

The adapter interface, for Wave 3 reconciliation with the MCP server unit:

    name          str                       matches returnPath.type
    enabled(cfg)  -> bool                   config switch, per route
    describe(ctx) -> str                    one line, what it would do
    plan(ctx)     -> list[str] | None       argv it would run, None if no command
    deliver(ctx, runner) -> Outcome         performs it

``Outcome.status`` is one of DELIVERED · SKIPPED · HELD · DEFERRED · FAILED and
maps 1:1 onto ledger statuses.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Dict, List, Optional, Sequence

from pencil_watcher.bundle import Bundle, ReturnPath
from pencil_watcher.config import Config
from pencil_watcher.runner import CommandRunner, preview_quote, shell_quote

DELIVERED = "delivered"
SKIPPED = "skipped"
HELD = "held"
DEFERRED = "deferred"
FAILED = "failed"


@dataclass
class DeliveryContext:
    bundle: Bundle
    return_path: ReturnPath
    text: str
    config: Config


@dataclass
class Outcome:
    status: str
    detail: str = ""
    argv: Optional[List[str]] = None


class RouteAdapter:
    """Base class. Subclasses override :meth:`plan` or :meth:`deliver`."""

    name = "unknown"
    #: human sentence for the log and for --dry-run
    summary = ""
    #: True when docs/08 q7 or docs/06 leaves this route's mechanics unproven
    unverified = True

    def enabled(self, config: Config) -> bool:
        return config.route(self.name).enabled

    def template(self, config: Config) -> List[str]:
        return list(config.route(self.name).command)

    # -- to override -------------------------------------------------------

    def plan(self, ctx: DeliveryContext) -> Optional[List[str]]:
        """The argv this route would execute, or None when it runs nothing."""
        return None

    def precondition(self, ctx: DeliveryContext, runner: CommandRunner) -> Optional[Outcome]:
        """Return a non-None Outcome to stop before running anything."""
        return None

    # -- shared ------------------------------------------------------------

    def describe(self, ctx: DeliveryContext) -> str:
        argv = self.plan(ctx)
        if argv is None:
            return "%s: %s" % (self.name, self.summary or "no command")
        return "%s: %s" % (self.name, preview_quote(argv))

    def deliver(self, ctx: DeliveryContext, runner: CommandRunner) -> Outcome:
        blocked = self.precondition(ctx, runner)
        if blocked is not None:
            return blocked

        argv = self.plan(ctx)
        if argv is None:
            return Outcome(SKIPPED, self.summary or "nothing to do")
        if not argv:
            return Outcome(
                FAILED,
                "route %s has an empty command template; set watcher.routes.%s.command"
                % (self.name, self.name),
            )

        result = runner.run(argv, timeout=ctx.config.command_timeout)
        if result.ok:
            return Outcome(DELIVERED, preview_quote(argv), argv=argv)
        return Outcome(FAILED, result.summary(), argv=argv)


def render(template: Sequence[str], values: Dict[str, str]) -> List[str]:
    """Substitute ``{placeholder}`` tokens in a command template.

    Substitution is per-argument and literal — the text is passed as one argv
    element, never through a shell, so a review containing quotes, backticks or
    newlines cannot become shell syntax.
    """
    out: List[str] = []
    for part in template:
        rendered = part
        for key, value in values.items():
            rendered = rendered.replace("{%s}" % key, value)
        out.append(rendered)
    return out


def _common_values(ctx: DeliveryContext) -> Dict[str, str]:
    return {
        "text": ctx.text,
        "sessionId": ctx.return_path.session_id,
        "triggerId": ctx.return_path.trigger_id,
        "bundlePath": str(ctx.bundle.path),
        "reviewPath": str(ctx.bundle.review_md),
        "replyPath": str(ctx.bundle.reply_md),
        "slug": ctx.bundle.slug,
    }


# --------------------------------------------------------------------------
# 1 · poke the Cowork session
# --------------------------------------------------------------------------


class PokeRoute(RouteAdapter):
    name = "poke"
    summary = "fire the poke-only scheduled task bound to the Cowork session"

    def plan(self, ctx: DeliveryContext) -> Optional[List[str]]:
        return render(self.template(ctx.config), _common_values(ctx))

    def precondition(self, ctx: DeliveryContext, runner: CommandRunner) -> Optional[Outcome]:
        if not ctx.return_path.trigger_id:
            return Outcome(FAILED, "returnPath.type is poke but no triggerId was recorded")
        return None


# --------------------------------------------------------------------------
# 2 · scheduled check-in
# --------------------------------------------------------------------------


class CheckinRoute(RouteAdapter):
    name = "checkin"
    summary = (
        "the session has its own scheduled check-in and collects the review itself; "
        "the watcher must not also deliver it"
    )
    unverified = False

    def plan(self, ctx: DeliveryContext) -> Optional[List[str]]:
        return None

    def deliver(self, ctx: DeliveryContext, runner: CommandRunner) -> Outcome:
        return Outcome(SKIPPED, self.summary)


# --------------------------------------------------------------------------
# 3 · Claude Code cloud session
# --------------------------------------------------------------------------


class CloudRoute(RouteAdapter):
    name = "cloud"
    summary = "queue the review into a live Claude Code cloud session"

    def plan(self, ctx: DeliveryContext) -> Optional[List[str]]:
        return render(self.template(ctx.config), _common_values(ctx))

    def precondition(self, ctx: DeliveryContext, runner: CommandRunner) -> Optional[Outcome]:
        if not ctx.return_path.session_id:
            return Outcome(FAILED, "returnPath.type is cloud but no sessionId was recorded")
        return None


# --------------------------------------------------------------------------
# 4/5 · Claude Code local session — idle resumes, running defers
# --------------------------------------------------------------------------


class ResumeRoute(RouteAdapter):
    name = "resume"
    summary = "resume the idle local Claude Code session and deliver the review"

    def plan(self, ctx: DeliveryContext) -> Optional[List[str]]:
        return render(self.template(ctx.config), _common_values(ctx))

    def precondition(self, ctx: DeliveryContext, runner: CommandRunner) -> Optional[Outcome]:
        if not ctx.return_path.session_id:
            return Outcome(FAILED, "returnPath.type is resume but no sessionId was recorded")
        busy = ctx.config.busy_command
        if busy:
            # docs/06: a running local session cannot be injected into. Hold
            # the bundle and fire when it frees up.
            probe = runner.run(list(busy), timeout=15.0)
            if probe.returncode == 0 and not probe.not_found and not probe.timed_out:
                return Outcome(
                    DEFERRED,
                    "a local Claude Code session appears to be running (%s); holding the bundle"
                    % shell_quote(list(busy)),
                )
        return None


# --------------------------------------------------------------------------
# 6 · Codex
# --------------------------------------------------------------------------


class CodexRoute(ResumeRoute):
    name = "codex"
    summary = "resume the Codex session and deliver the review"

    def precondition(self, ctx: DeliveryContext, runner: CommandRunner) -> Optional[Outcome]:
        if not ctx.return_path.session_id:
            return Outcome(FAILED, "origin.kind is codex but no sessionId was recorded")
        return None


# --------------------------------------------------------------------------
# 7 · no return path
# --------------------------------------------------------------------------


class NoneRoute(RouteAdapter):
    name = "none"
    summary = (
        "no return path recorded; leaving the bundle alone. The iPad app's share-sheet "
        "fallback covers this case (docs/06) and the watcher must not invent a route"
    )
    unverified = False

    def enabled(self, config: Config) -> bool:
        return True

    def plan(self, ctx: DeliveryContext) -> Optional[List[str]]:
        return None

    def deliver(self, ctx: DeliveryContext, runner: CommandRunner) -> Outcome:
        return Outcome(HELD, self.summary)


ADAPTERS: Dict[str, RouteAdapter] = {
    adapter.name: adapter
    for adapter in (
        PokeRoute(),
        CheckinRoute(),
        CloudRoute(),
        ResumeRoute(),
        CodexRoute(),
        NoneRoute(),
    )
}


def select(return_path: ReturnPath) -> RouteAdapter:
    """Map a resolved return path onto the adapter that handles it.

    ``origin.kind == "codex"`` wins over the resume/cloud type, because docs/06
    says Codex has equivalent semantics through a different binary.
    """
    kind = (return_path.kind or "").strip().lower()
    rp_type = (return_path.type or "none").strip().lower()

    if kind == "codex" and rp_type in ("resume", "cloud", "poke"):
        return ADAPTERS["codex"]

    return ADAPTERS.get(rp_type, ADAPTERS["none"])
