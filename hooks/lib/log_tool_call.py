#!/usr/bin/env python3
"""Consolidated PreToolUse + PostToolUse logger for claude-defaults.

Replaces the bash + 4-jq + 5-python3 + redact.py + jsonl_write.py pipeline
with a single python3 invocation per tool call. Same on-disk schema as the
bash version; same redaction patterns; same temp-file pairing.

Usage: log_tool_call.py {pre|post}
       (reads Claude Code hook JSON from stdin)

Logging failures NEVER break a tool call -- all errors caught and swallowed,
exit 0 unconditionally on failure paths.

Patterns + truncation + atomic-append all live in `_log_core.py` so the
three callers (this file, redact.py, jsonl_write.py) share one source of
truth.

Compatible with Python 3.9+ (relies on PEP 563 deferred annotations).
"""
from __future__ import annotations

import hashlib
import json
import os
import re
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

# Make sibling-module imports work when this script is invoked through a
# symlink (e.g. ~/.claude/hooks/lib/log_tool_call.py -> repo path).
sys.path.insert(0, os.path.dirname(os.path.realpath(__file__)))

from _log_core import (  # noqa: E402
    DEFAULT_MAX_LINE,
    atomic_append,
    redact_value,
    truncate_output,
)


# ---------------------------------------------------------------------------
# Hook entry
# ---------------------------------------------------------------------------
_SAFE_CHARS = re.compile(r"[^A-Za-z0-9_\-]")


def _sanitize(s: str) -> str:
    return _SAFE_CHARS.sub("_", s) if s else "unknown"


def _parse_mcp_server(tool: str) -> str | None:
    if not tool.startswith("mcp__"):
        return None
    rest = tool[len("mcp__"):]
    sep = rest.find("__")
    if sep <= 0:
        return None
    return rest[:sep]


def _now_iso() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z")


def _call_id() -> str:
    return f"{int(time.time() * 1_000_000)}-{os.getpid()}"


def _pair_key(session_id: str, tool_input: dict) -> str:
    h = hashlib.sha256(json.dumps(tool_input, sort_keys=True, ensure_ascii=False).encode("utf-8")).hexdigest()[:16]
    return f"{_sanitize(session_id)}-{h}"


def _temp_dir() -> str:
    return os.environ.get("TMPDIR", "/tmp").rstrip("/")


def _max_line_bytes() -> int:
    try:
        return int(os.environ.get("CLAUDE_LOG_MAX_LINE_BYTES", DEFAULT_MAX_LINE))
    except ValueError:
        return DEFAULT_MAX_LINE


def main() -> int:
    event = "pre"
    if len(sys.argv) >= 2 and sys.argv[1] in ("pre", "post"):
        event = sys.argv[1]

    try:
        raw = sys.stdin.read()
        data = json.loads(raw) if raw.strip() else {}
    except (json.JSONDecodeError, OSError):
        return 0  # logging never breaks a tool call

    session_id = str(data.get("session_id") or "unknown")
    cwd = str(data.get("cwd") or "unknown")
    tool = str(data.get("tool_name") or "unknown")
    tool_input = data.get("tool_input") or {}
    if not isinstance(tool_input, dict):
        tool_input = {"_raw": tool_input}

    mcp_server = _parse_mcp_server(tool)
    log_dir = Path.home() / ".claude" / "logs"
    # Issue #10: filename uses UTC to match the ts field. Otherwise rows
    # written near local midnight land in a file dated for the previous
    # local day while the ts field is the next UTC day.
    log_file = str(log_dir / f"tool-calls-{datetime.now(timezone.utc).strftime('%Y-%m-%d')}.jsonl")
    pair_path = os.path.join(_temp_dir(), f"claude-tool-{_pair_key(session_id, tool_input)}")

    # Generate call_id ONCE per invocation. For pre, write it into the pair
    # file alongside the start time so post can read it back and the pre-row's
    # call_id matches its post-row's call_id (the docs/LOGGING.md "join on
    # call_id" contract). For post, use a fresh call_id and duration_ms=None
    # when the canonical pair file is absent. Claude Code's hook contract passes
    # no state pre->post, so there is no correct lookup key when the pair file
    # is missing -- guessing from other files would fabricate wrong values.
    call_id = _call_id()

    if event == "pre":
        try:
            # Issue #15 (polish): pair files are created 0o600 (owner-only).
            # They contain timing + session metadata; no reason for other
            # local users to read them.
            fd = os.open(pair_path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
            with os.fdopen(fd, "w") as f:
                f.write(f"{call_id} {time.time()}\n")
        except OSError:
            pass

        payload = {
            "ts": _now_iso(),
            "session_id": session_id,
            "cwd": cwd,
            "event": "pre",
            "call_id": call_id,
            "tool": tool,
            "mcp_server": mcp_server,
            "args": redact_value(tool_input),
        }
    else:
        # Post: pair on the canonical content-hash file written by pre. When it
        # is absent (a racing concurrent call, or no preceding pre), emit a
        # fresh call_id and duration_ms=None. We do not guess from other pair
        # files: identical-input calls share a pair_path and any mtime-based
        # match would consume a racing call's file, misattributing both joins.
        start_time = None
        paired_call_id = None
        if os.path.isfile(pair_path):
            try:
                with open(pair_path) as f:
                    parts = f.read().split()
                    if len(parts) >= 2:
                        paired_call_id = parts[0]
                        start_time = float(parts[1])
            except (OSError, ValueError):
                pass
            try:
                os.unlink(pair_path)
            except OSError:
                pass

        duration_ms = int((time.time() - start_time) * 1000) if start_time else None
        tool_response = data.get("tool_response") or {}
        if not isinstance(tool_response, dict):
            tool_response = {"_raw": tool_response}
        exit_status = tool_response.get("exit_code", tool_response.get("exitCode", 0))
        try:
            exit_status = int(exit_status)
        except (TypeError, ValueError):
            exit_status = 0

        payload = {
            "ts": _now_iso(),
            "session_id": session_id,
            "cwd": cwd,
            "event": "post",
            "call_id": paired_call_id or call_id,
            "tool": tool,
            "mcp_server": mcp_server,
            "exit_status": exit_status,
            "duration_ms": duration_ms,
            "output": redact_value(tool_response),
        }

    payload = truncate_output(payload, _max_line_bytes())
    try:
        atomic_append(log_file, payload)
    except OSError as exc:
        # Issue #8: explicit return 0 for ALL OSError variants (not just
        # ENOSPC). Logging must never break a tool call regardless of which
        # filesystem error fires (EACCES after a chown, EROFS after a
        # remount, etc.). The previous code only returned 0 inside the
        # ENOSPC branch and relied on Python's None-exit-code coincidence.
        _ = exc  # explicitly acknowledge we're swallowing all OSErrors
        return 0
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception:
        # Never break a tool call due to logging.
        sys.exit(0)
