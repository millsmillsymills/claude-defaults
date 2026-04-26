#!/usr/bin/env python3
"""Shared redaction patterns + JSONL helpers for claude-defaults logging.

This is the canonical home for:

  - `_PATTERNS`          : compiled secret-redaction regex pairs
  - `redact_string(s)`   : run the patterns against a single string
  - `redact_value(v)`    : recursively redact strings inside JSON values
  - `truncate_output(obj, max_bytes)`
                         : trim `output.stdout`/`output.stderr` so the
                           serialized line fits within `max_bytes`
  - `atomic_append(path, obj)`
                         : single-syscall O_APPEND write of a JSONL line
  - `DEFAULT_MAX_LINE`   : 1 MB per-line cap

The three CLI/library callers in this directory all import from here so
patterns and truncation logic exist in exactly one place:

  - `redact.py`          : thin CLI wrapper around `redact_value`
  - `jsonl_write.py`     : thin CLI wrapper around `truncate_output` +
                           `atomic_append`
  - `log_tool_call.py`   : consolidated PreToolUse + PostToolUse logger;
                           imports rather than spawning a subprocess to
                           preserve the single-fork performance win

Compatible with Python 3.9+ (relies on PEP 563 deferred annotations).
"""
from __future__ import annotations

import errno
import json
import os
import re

# ---------------------------------------------------------------------------
# Redaction patterns
# ---------------------------------------------------------------------------
# Compiled patterns (bounded to avoid catastrophic backtracking).
# Order matters: more-specific patterns run first so generic key=value
# fallbacks don't clobber a structured replacement (e.g. AKIA... is matched
# as an AWS key, not as a `key=value` pair).
_PATTERNS: list[tuple[re.Pattern[str], str]] = [
    # JWT (three base64url segments separated by dots, first two start with eyJ)
    (re.compile(r"eyJ[A-Za-z0-9_\-]{4,}\.eyJ[A-Za-z0-9_\-]{4,}\.[A-Za-z0-9_\-]{4,}"),
     "***JWT***"),
    # AWS access key
    (re.compile(r"\bAKIA[0-9A-Z]{16}\b"), "***AWS_KEY***"),
    # GitHub tokens (ghp_, gho_, ghs_, ghu_)
    (re.compile(r"\bgh[opsu]_[A-Za-z0-9]{36,}\b"), "***GH_TOKEN***"),
    # Anthropic API keys
    (re.compile(r"\bsk-ant-[A-Za-z0-9_\-]{8,}\b"), "***ANTHROPIC_KEY***"),
    # OpenAI keys (sk- followed by 40+ base62 chars; bounded)
    (re.compile(r"\bsk-[A-Za-z0-9]{40,80}\b"), "***OPENAI_KEY***"),
    # key=value secrets where value is a single shell/URL token (no internal whitespace)
    (re.compile(
        r"(?i)\b(password|passwd|secret|token|api[_-]?key)"
        r"(\s*[:=]\s*)([^\s,;'\"]{3,})"
    ), r"\1\2***"),
    # Header-style: Authorization: <scheme> <credential...>; Bearer <token>
    # Value class allows internal spaces; stops at line/quote/comma/semicolon.
    # Separator may be ':', '=', or whitespace alone (e.g. `Bearer abc`).
    # Value class excludes '*' so we don't re-match earlier-redacted markers
    # (e.g. preserve `Bearer ***JWT***` -> `Bearer ***`).
    (re.compile(
        r"(?i)\b(authorization|bearer)"
        r"(\s*[:=]\s*|\s+)([^*,;'\"\r\n]{3,})"
    ), r"\1\2***"),
    # --flag=value CLI secrets
    (re.compile(
        r"(--(?:password|token|secret|api[_-]?key))(=)([^\s,;'\"]{3,})"
    ), r"\1\2***"),
]


def redact_string(s: str) -> str:
    """Run every redaction pattern against `s` in order."""
    for pattern, replacement in _PATTERNS:
        s = pattern.sub(replacement, s)
    return s


def redact_value(v):
    """Recursively walk a JSON-decoded value, redacting strings."""
    if isinstance(v, str):
        return redact_string(v)
    if isinstance(v, list):
        return [redact_value(x) for x in v]
    if isinstance(v, dict):
        return {k: redact_value(val) for k, val in v.items()}
    return v


# ---------------------------------------------------------------------------
# JSONL write helpers
# ---------------------------------------------------------------------------
DEFAULT_MAX_LINE = 1024 * 1024  # 1 MB


def truncate_output(obj: dict, max_bytes: int) -> dict:
    """If serialized JSON would exceed `max_bytes`, trim output.{stdout,stderr}.

    Mutates and returns `obj` for convenience. Adds an `output._truncated_bytes`
    marker if anything was dropped.
    """
    serialized = json.dumps(obj, ensure_ascii=False)
    overhead = len((serialized + "\n").encode("utf-8")) - max_bytes
    if overhead <= 0:
        return obj

    output = obj.get("output")
    if not isinstance(output, dict):
        # Nothing structured to trim; leave as-is.
        return obj

    truncated_total = 0
    for key in ("stdout", "stderr"):
        v = output.get(key)
        if not isinstance(v, str):
            continue
        encoded = v.encode("utf-8")
        if len(encoded) <= 256:
            continue
        # Reserve ~256 bytes of context, drop the middle.
        keep = max(256, len(encoded) - max(0, overhead - truncated_total))
        if keep < len(encoded):
            output[key] = encoded[:keep].decode("utf-8", errors="replace")
            truncated_total += len(encoded) - keep
        # Re-check size.
        serialized = json.dumps(obj, ensure_ascii=False)
        if len((serialized + "\n").encode("utf-8")) <= max_bytes:
            break

    if truncated_total > 0:
        output["_truncated_bytes"] = truncated_total

    return obj


def atomic_append(path: str, obj: dict) -> None:
    """Append a JSON object as one line via a single O_APPEND syscall.

    Atomic on macOS APFS for the line sizes we produce (≤ 1 MB).
    Caller is responsible for catching ENOSPC if it wants to silently
    drop on disk-full.
    """
    line = (json.dumps(obj, ensure_ascii=False) + "\n").encode("utf-8")
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    fd = os.open(path, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o644)
    try:
        os.write(fd, line)
    finally:
        os.close(fd)


# Re-export errno so callers don't need a separate import just to check ENOSPC.
ENOSPC = errno.ENOSPC
