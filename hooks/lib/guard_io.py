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
    payload, or a missing/non-string/empty command -- so the caller fails open
    quietly. A parser edge case must never wedge the session.
    """
    try:
        data = json.load(sys.stdin)
    except (json.JSONDecodeError, UnicodeDecodeError):
        return None
    if not isinstance(data, dict):
        return None
    cmd = data.get("tool_input", {}).get("command", "")
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
    _log_scan_error(hook_name, exc)
    return block(
        f"{hook_name} could not verify this command (scan crashed). "
        "Refusing out of caution -- rerun, or bypass explicitly if you trust it."
    )


def _log_scan_error(hook_name: str, exc: BaseException) -> None:
    """Record a scan crash to a durable log and stderr; caller fails closed."""
    try:
        print(
            f"WARNING: {hook_name} scan crashed ({exc!r}); the guard could not "
            "run. File a bug or run scripts/doctor.sh.",
            file=sys.stderr,
        )
    except OSError:
        pass  # a dead stderr must never change the fail-closed verdict
    try:
        log_dir = Path.home() / ".claude" / "logs"
        log_dir.mkdir(parents=True, exist_ok=True)
        stamp = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        with (log_dir / "hook-errors.log").open("a", encoding="utf-8") as fh:
            fh.write(f"{stamp} {hook_name} scan-error: {exc!r}\n")
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
