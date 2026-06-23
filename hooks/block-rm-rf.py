#!/usr/bin/env python3
"""PreToolUse(Bash) hook: block any `rm -rf`, point at `trash` instead.

Broader than safety-block.py (which only blocks `rm -rf` against protected
paths): this enforces the project policy that *no* recursive-force delete should
go through `rm`. It shares cmdscan's tokenizer, so a payload tucked inside
`bash -c '...'` / `eval '...'` and unspaced separators (`true;rm -rf x`) are
unwrapped and checked too -- the previous shell guard stripped quoted strings
with `sed`, which any wrapper defeated.

Exit 2 blocks; exit 0 allows. Malformed input fails open (nothing to scan); a
matcher crash fails closed and is logged loudly, mirroring safety-block.py.
"""

from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent / "lib"))

from cmdscan import (  # noqa: E402  # ty: ignore[unresolved-import]
    has_recursive_force,
    iter_segments,
    rm_invocation,
    strip_redirects,
)
from guard_io import block, fail_closed, read_command  # noqa: E402  # ty: ignore[unresolved-import]


def _is_rm_rf(seg: list[str]) -> bool:
    """True if `seg` is an `rm` (any launcher/path form) with recursive+force."""
    i = rm_invocation(seg)
    if i < 0:
        return False
    return has_recursive_force(strip_redirects(seg[i + 1 :]))


def scan(cmd: str) -> bool:
    """True if any command segment (including wrapped payloads) is an rm -rf."""
    return any(_is_rm_rf(seg) for seg in iter_segments(cmd))


def main() -> int:
    cmd = read_command()
    if not cmd:
        return 0
    try:
        hit = scan(cmd)
    except Exception as exc:  # noqa: BLE001 -- fail closed + loud
        return fail_closed("block-rm-rf.py", exc)
    if hit:
        return block("Use trash instead of rm -rf")
    return 0


if __name__ == "__main__":
    sys.exit(main())
