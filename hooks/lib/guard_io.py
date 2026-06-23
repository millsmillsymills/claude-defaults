#!/usr/bin/env python3
"""Shared stdin/verdict plumbing for the PreToolUse(Bash) guard hooks.

Every guard reads the same tool-call envelope from stdin, blocks with the same
exit code, and must fail *closed* (block + log loudly) when its own matcher
crashes -- a never-ran guard silently allowing a destructive command is the
worst outcome. That plumbing lives here so the three guards stay identical on
the parts that aren't policy.

Compatible with Python 3.9+ (relies on PEP 563 deferred annotations).
"""

from __future__ import annotations

import json
import sys
import traceback
from datetime import datetime, timezone
from pathlib import Path


def read_command() -> str | None:
    """Return the Bash command from the tool-call envelope on stdin.

    Returns None when there is nothing to scan -- malformed JSON, a non-dict
    payload, a non-dict `tool_input`, or a missing/non-string/empty command --
    so the caller fails open quietly. A parser edge case must never wedge the
    session: a non-dict `tool_input` (`{"tool_input": "x"}`) used to raise
    AttributeError and exit 1, which the harness treats as a hook error.
    """
    try:
        data = json.load(sys.stdin)
    except (json.JSONDecodeError, UnicodeDecodeError):
        return None
    if not isinstance(data, dict):
        return None
    tool_input = data.get("tool_input")
    if not isinstance(tool_input, dict):
        return None
    cmd = tool_input.get("command", "")
    if not isinstance(cmd, str) or not cmd:
        return None
    return cmd


def block(reason: str) -> int:
    """Print a block message to stderr and return the blocking exit code (2)."""
    try:
        print(f"BLOCKED: {reason}", file=sys.stderr)
    except OSError:
        pass  # block regardless of whether the message reached the user
    return 2


def fail_closed(hook_name: str, exc: BaseException) -> int:
    """Block (exit 2) after a matcher crash, logging the failure durably.

    The scan produced no verdict, so the destructive classes with no
    deny-list backstop would otherwise pass unchecked. Block this one command
    and record the crash to logs/hook-errors.log and stderr so the bug is
    fixable.
    """
    _log_guard_error(
        hook_name,
        exc,
        stderr_note="scan crashed; the guard could not run. File a bug or run "
        "scripts/doctor.sh",
        log_tag="scan-error",
    )
    return block(
        f"{hook_name} could not verify this command (scan crashed). "
        "Refusing out of caution -- rerun, or bypass explicitly if you trust it."
    )


def fail_closed_unverified(
    hook_name: str, block_reason: str, exc: BaseException
) -> int:
    """Block (exit 2) for a *deliberate* fail-closed: the guard could not
    establish a fact it needs to judge the command (not a matcher crash).

    Logs the cause durably with wording that distinguishes it from a scan crash,
    so the audit trail does not read an intentional fail-closed as a bug.
    `block_reason` is shown to the user; `exc` carries the underlying cause.
    """
    _log_guard_error(
        hook_name,
        exc,
        stderr_note="could not verify a precondition; failing closed",
        log_tag="unverified",
    )
    return block(block_reason)


def _log_guard_error(
    hook_name: str, exc: BaseException, *, stderr_note: str, log_tag: str
) -> None:
    """Record a fail-closed cause to a durable log and stderr; caller blocks."""
    try:
        print(f"WARNING: {hook_name} {stderr_note} ({exc!r}).", file=sys.stderr)
    except OSError:
        pass  # a dead stderr must never change the fail-closed verdict
    try:
        log_dir = Path.home() / ".claude" / "logs"
        log_dir.mkdir(parents=True, exist_ok=True)
        stamp = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        with (log_dir / "hook-errors.log").open("a", encoding="utf-8") as fh:
            fh.write(f"{stamp} {hook_name} {log_tag}: {exc!r}\n")
            fh.write(
                "".join(traceback.format_exception(type(exc), exc, exc.__traceback__))
            )
    except OSError as log_exc:
        try:
            print(
                f"WARNING: {hook_name} could not write hook-errors.log "
                f"({log_exc!r}); the scan-crash audit trail was lost.",
                file=sys.stderr,
            )
        except OSError:
            pass
