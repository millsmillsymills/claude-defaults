#!/usr/bin/env python3
"""Atomic-append a JSON object to a JSONL file with size truncation.

Reads JSON from stdin, ensures the serialized line is <= max bytes (truncating
inside output.stdout/output.stderr if needed), writes a single line via one
O_APPEND syscall (atomic on macOS APFS for the line sizes we produce).

Usage: python3 jsonl-write.py <output-file>

Env:
  CLAUDE_LOG_MAX_LINE_BYTES   max bytes per line (default 1048576 = 1 MB)

Exit codes:
  0   success, OR ENOSPC (silently dropped)
  1   fatal error (bad JSON, missing arg, permission denied)
"""
import errno
import json
import os
import sys

DEFAULT_MAX = 1024 * 1024  # 1 MB


def _truncate_output(obj: dict, max_bytes: int) -> dict:
    """If serialized JSON would exceed max_bytes, trim output.stdout/stderr."""
    serialized = json.dumps(obj, ensure_ascii=False)
    overhead = len((serialized + "\n").encode("utf-8")) - max_bytes
    if overhead <= 0:
        return obj

    output = obj.get("output")
    if not isinstance(output, dict):
        # Nothing structured to trim; truncate anything we can find.
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


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: jsonl-write.py <output-file>", file=sys.stderr)
        return 1
    out_path = sys.argv[1]
    max_bytes = int(os.environ.get("CLAUDE_LOG_MAX_LINE_BYTES", DEFAULT_MAX))

    try:
        obj = json.load(sys.stdin)
    except json.JSONDecodeError as exc:
        print(f"jsonl-write: stdin is not valid JSON: {exc}", file=sys.stderr)
        return 1

    obj = _truncate_output(obj, max_bytes)
    line = json.dumps(obj, ensure_ascii=False) + "\n"
    encoded = line.encode("utf-8")

    os.makedirs(os.path.dirname(out_path) or ".", exist_ok=True)
    try:
        fd = os.open(out_path, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o644)
        try:
            os.write(fd, encoded)
        finally:
            os.close(fd)
    except OSError as exc:
        if exc.errno == errno.ENOSPC:
            # Disk full — silently drop the line; never break a tool call.
            return 0
        print(f"jsonl-write: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
