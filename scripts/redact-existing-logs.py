#!/usr/bin/env python3
"""Re-redact existing JSONL logs after adding a redaction pattern.

Runs every line of each given tool-call log through the shared `redact_value`
(the same redaction the live logger applies) and rewrites the file atomically.
Lines that are not valid JSON are preserved unchanged so no data is lost. Run
this once after editing `_log_core._PATTERNS` to scrub secrets that were
captured before the new pattern existed.

Usage: python3 scripts/redact-existing-logs.py <log-file> [<log-file> ...]
"""
from __future__ import annotations

import json
import os
import sys
import tempfile
from pathlib import Path

# Import the shared redaction from hooks/lib regardless of where this is run.
# The path is injected at runtime, so static resolution can't see the module.
sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "hooks" / "lib"))

from _log_core import redact_value  # noqa: E402  # ty: ignore[unresolved-import]


def redact_file(path: str) -> tuple[int, int]:
    """Redact one JSONL file in place.

    Returns a `(lines_total, lines_changed)` pair, counting only JSON lines.
    The rewrite is atomic: a temp file in the same directory is renamed over
    the original only after every line is processed.
    """
    total = 0
    changed = 0
    dir_name = os.path.dirname(os.path.abspath(path)) or "."
    fd, tmp = tempfile.mkstemp(dir=dir_name, suffix=".redact.tmp")
    success = False
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as out, open(
            path, encoding="utf-8"
        ) as src:
            for line in src:
                stripped = line.rstrip("\n")
                if not stripped:
                    out.write(line)
                    continue
                total += 1
                try:
                    obj = json.loads(stripped)
                except json.JSONDecodeError:
                    out.write(line)  # not JSON: preserve verbatim
                    continue
                redacted = json.dumps(redact_value(obj), ensure_ascii=False)
                if redacted != stripped:
                    changed += 1
                out.write(redacted + "\n")
        os.replace(tmp, path)
        success = True
    finally:
        if not success and os.path.exists(tmp):
            os.unlink(tmp)
    return total, changed


def main(argv: list[str]) -> int:
    if not argv:
        print(
            "usage: redact-existing-logs.py <log-file> [<log-file> ...]",
            file=sys.stderr,
        )
        return 2
    exit_code = 0
    for path in argv:
        if not os.path.isfile(path):
            print(f"redact: not a file: {path}", file=sys.stderr)
            exit_code = 1
            continue
        total, changed = redact_file(path)
        print(f"{path}: {changed}/{total} JSON line(s) redacted")
    return exit_code


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
