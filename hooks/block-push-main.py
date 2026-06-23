#!/usr/bin/env python3
"""PreToolUse(Bash) hook: block any direct push to main/master.

Broader than safety-block.py (which only blocks *force*-pushes): this enforces
the project policy of no direct push to main/master at all. It shares cmdscan's
tokenizer, so a payload tucked inside `bash -c '...'` and unspaced separators
are unwrapped and checked too -- the previous shell guard stripped quoted
strings with `sed`, which any wrapper defeated. It also catches a *bare*
`git push` (no refspec): if the current branch resolves to main/master, that
push goes to a protected branch and is blocked.

Does NOT cover force-push or production branches -- that's safety-block.py's job.

Exit 2 blocks; exit 0 allows. Malformed input fails open; a matcher crash fails
closed and is logged loudly, mirroring safety-block.py.
"""

from __future__ import annotations

import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent / "lib"))

from cmdscan import (  # noqa: E402  # ty: ignore[unresolved-import]
    command_index,
    iter_segments,
)
from guard_io import (  # noqa: E402  # ty: ignore[unresolved-import]
    block,
    fail_closed,
    read_command,
)

_PROTECTED = ("main", "master")
# git-level options (before the `push` subcommand) that consume the next token
# as their value, so it must be skipped when locating `push`.
_GIT_OPTS_WITH_VALUE = {
    "-C",
    "-c",
    "--git-dir",
    "--work-tree",
    "--namespace",
    "--exec-path",
}


def _push_dest(ref: str) -> str:
    """The destination branch of a push refspec (the part after the last ':').

    Strips a leading `+` (force refspec) and a `refs/heads/` prefix, so
    `HEAD:main`, `+main`, and `refs/heads/main` all resolve to `main`, while
    `main:feature` (pushing main INTO feature) resolves to `feature`.
    """
    dest = ref.lstrip("+").rsplit(":", 1)[-1]
    prefix = "refs/heads/"
    if dest.startswith(prefix):
        dest = dest[len(prefix) :]
    return dest


def _current_branch() -> str | None:
    """The checked-out branch name, or None if it can't be determined."""
    try:
        out = subprocess.run(
            ["git", "rev-parse", "--abbrev-ref", "HEAD"],
            capture_output=True,
            text=True,
            timeout=5,
            check=False,
        )
    except (OSError, subprocess.SubprocessError):
        return None
    branch = out.stdout.strip()
    return branch or None


def _push_args(seg: list[str]) -> list[str] | None:
    """Tokens after `push` in a `git push ...` segment, or None if not one.

    Skips launcher prefixes and git-level options (and the value of those that
    take one), so `sudo git -C /repo push origin main` is recognized.
    """
    i = command_index(seg, "git")
    if i < 0:
        return None
    j = i + 1
    while j < len(seg) and seg[j].startswith("-"):
        if seg[j] in _GIT_OPTS_WITH_VALUE:
            j += 1
        j += 1
    if j >= len(seg) or seg[j] != "push":
        return None
    return seg[j + 1 :]


def _is_push_to_protected(seg: list[str]) -> bool:
    """True if `seg` is a `git push` reaching main/master, bare push included."""
    args = _push_args(seg)
    if args is None:
        return False
    positionals = [t for t in args if not t.startswith("-")]
    refspecs = positionals[1:]  # first positional is the remote
    if refspecs:
        return any(_push_dest(r) in _PROTECTED for r in refspecs)
    # Bare push (no refspec): the current branch is the destination.
    return _current_branch() in _PROTECTED


def scan(cmd: str) -> bool:
    """True if any command segment pushes to a protected branch."""
    return any(_is_push_to_protected(seg) for seg in iter_segments(cmd))


def main() -> int:
    cmd = read_command()
    if not cmd:
        return 0
    try:
        hit = scan(cmd)
    except Exception as exc:  # noqa: BLE001 -- fail closed + loud
        return fail_closed("block-push-main.py", exc)
    if hit:
        return block("Use feature branches, not direct push to main")
    return 0


if __name__ == "__main__":
    sys.exit(main())
