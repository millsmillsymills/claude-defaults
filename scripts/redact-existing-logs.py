#!/usr/bin/env python3
"""Re-redact existing JSONL logs after adding a redaction pattern.

Runs every line of each given tool-call log through the shared `redact_value`
(the same redaction the live logger applies) and rewrites the file atomically.
Lines that are not valid JSON are preserved unchanged so no data is lost. Run
this once after editing `_log_core._PATTERNS` to scrub secrets that were
captured before the new pattern existed.

WARNING: the rewrite uses `os.replace`, which swaps in a new inode. Any process
still appending to the old inode (a live logger) loses its concurrent writes
silently. Run this only against rotated/inactive logs, or when no Claude session
is active.

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

from _log_core import (  # noqa: E402  # ty: ignore[unresolved-import]
    redact_string,
    redact_value,
)


def redact_file(path: str) -> tuple[int, int]:
    """Redact one JSONL file in place.

    Returns a `(lines_total, lines_changed)` pair counting every non-empty line.
    The rewrite is atomic: a temp file in the same directory is renamed over
    the original only after every line is processed.
    """
    total = 0
    changed = 0
    dir_name = os.path.dirname(os.path.abspath(path)) or "."
    fd, tmp = tempfile.mkstemp(dir=dir_name, suffix=".redact.tmp")
    success = False
    try:
        with (
            os.fdopen(fd, "w", encoding="utf-8", errors="surrogateescape") as out,
            open(path, encoding="utf-8", errors="surrogateescape") as src,
        ):
            for line in src:
                stripped = line.rstrip("\n")
                if not stripped:
                    out.write(line)
                    continue
                total += 1
                try:
                    obj = json.loads(stripped)
                except json.JSONDecodeError:
                    # Not JSON (a corrupt/legacy raw line): a token in it would
                    # survive a verbatim copy, so run the string-level redaction.
                    redacted = redact_string(stripped)
                else:
                    redacted = json.dumps(redact_value(obj), ensure_ascii=False)
                if redacted != stripped:
                    changed += 1
                out.write(redacted + "\n")
        # mkstemp creates the temp file at 0600; carrying that into the live log
        # via os.replace would tighten perms away from the logger's 0644.
        try:
            original_mode = os.stat(path).st_mode & 0o777
        except OSError:
            original_mode = 0o644
        os.chmod(tmp, original_mode)
        os.replace(tmp, path)
        success = True
    finally:
        if not success and os.path.exists(tmp):
            os.unlink(tmp)
    return total, changed


def main(argv: list[str]) -> int:
    if not argv:
        print(
            "usage: redact-existing-logs.py <log-file> [<log-file> ...]\n"
            "WARNING: rewrites each file via os.replace, which drops concurrent "
            "writes to the old inode. Run only against rotated/inactive logs, "
            "or when no Claude session is active.",
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
