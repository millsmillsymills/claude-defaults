#!/usr/bin/env python3
"""Atomic-append a JSON object to a JSONL file with size truncation.

Reads JSON from stdin, ensures the serialized line is <= max bytes (truncating
inside output.stdout/output.stderr if needed), writes a single line via one
O_APPEND syscall (atomic on macOS APFS for the line sizes we produce).

Usage: python3 jsonl_write.py <output-file>

Env:
  CLAUDE_LOG_MAX_LINE_BYTES   max bytes per line (default 1048576 = 1 MB)

Exit codes:
  0   success, OR ENOSPC (silently dropped)
  1   fatal error (bad JSON, missing arg, permission denied)

Truncation logic + atomic-append helper live in `_log_core.py`.
"""
from __future__ import annotations

import errno
import json
import os
import sys

# Make sibling-module imports work when this script is invoked through a
# symlink (e.g. ~/.claude/hooks/lib/jsonl_write.py -> repo path).
sys.path.insert(0, os.path.dirname(os.path.realpath(__file__)))

from _log_core import DEFAULT_MAX_LINE, atomic_append, truncate_output  # noqa: E402


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: jsonl_write.py <output-file>", file=sys.stderr)
        return 1
    out_path = sys.argv[1]
    try:
        max_bytes = int(os.environ.get("CLAUDE_LOG_MAX_LINE_BYTES", DEFAULT_MAX_LINE))
    except ValueError:
        max_bytes = DEFAULT_MAX_LINE

    try:
        obj = json.load(sys.stdin)
    except json.JSONDecodeError as exc:
        print(f"jsonl_write: stdin is not valid JSON: {exc}", file=sys.stderr)
        return 1

    obj = truncate_output(obj, max_bytes)
    try:
        atomic_append(out_path, obj)
    except OSError as exc:
        if exc.errno == errno.ENOSPC:
            # Disk full — silently drop the line; never break a tool call.
            return 0
        print(f"jsonl_write: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
