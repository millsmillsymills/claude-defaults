#!/usr/bin/env python3
"""PreToolUse(Bash|Write) hook: block whole-file overwrites of the central
research secrets file (``~/.config/research/.env``).

That file is shared by every ``*-research`` repo -- ``scripts/lib/http.sh`` loads
it first, then the repo-local ``.env`` for per-target overrides. It must hold only
the shared cross-repo credentials and be edited or key-merged *in place*. Copying
a whole file over it (``cp``/``mv``/``tee``/a truncating ``>``/``install``/``dd``)
replaces it with one repo's slice and wipes every other repo's keys -- exactly how
the shared ``H1_*`` credentials were lost. This guard denies the clobbering forms
while allowing reads, appends (``>>``), and in-place Edits.

Exit 2 blocks the call; exit 0 allows it. Malformed input fails *open* (there is
nothing to scan). A scan crash fails *closed* via ``guard_io.fail_closed``, the
same posture as the sibling destructive-command guards.
"""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path

# Shared command tokenization lives in hooks/lib; the path is injected at runtime
# because the hook may run from a symlink, so static resolution can't see it.
sys.path.insert(0, str(Path(__file__).resolve().parent / "lib"))

from cmdscan import (  # noqa: E402  # ty: ignore[unresolved-import]
    base as _base,
    command_start as _command_start,
    segments as _segments,
    strip_redirects as _strip_redirects,
    tokenize as _tokenize,
)
from guard_io import block, fail_closed  # noqa: E402  # ty: ignore[unresolved-import]

# The central file at the end of a path token: `.config/research/.env` with a
# slash (or string start) before `.config`, so `.env.example` and an unrelated
# `myconfig/research/.env` are both excluded.
_RE_CENTRAL = re.compile(r"(?:^|/)\.config/research/\.env$")
_RE_ASSIGN = re.compile(r"^([A-Za-z_]\w*)=(.*)$")
_RE_VARREF = re.compile(r"^\$\{?([A-Za-z_]\w*)\}?$")
# Truncating redirect operators as the tokenizer emits them. `>>` (append) and
# the `>&`/dup forms are deliberately excluded -- only a truncating write to the
# central file clobbers it.
_TRUNC_REDIRECTS = {">", ">|", "&>"}
_COPY_CMDS = {"cp", "mv", "install", "rsync", "ln"}
# Commands whose named-file argument is overwritten in place unless an append
# flag is given.
_NAMED_WRITE_CMDS = {"tee", "sponge"}
_APPEND_FLAGS = {"-a", "--append"}


def _is_central(token: str, central_vars: set[str]) -> bool:
    """True if `token` names the central file directly or via a resolved var."""
    ref = _RE_VARREF.match(token)
    if ref:
        return ref.group(1) in central_vars
    return _RE_CENTRAL.search(token) is not None


def _central_vars(tokens: list[str]) -> set[str]:
    """Names of shell vars assigned the central path earlier in the command.

    Catches the seeding form `f="$HOME/.config/research/.env"; ...; mv "$t" "$f"`,
    where the clobber target reaches the `mv` only through `$f`.
    """
    out: set[str] = set()
    for token in tokens:
        assign = _RE_ASSIGN.match(token)
        if assign and _RE_CENTRAL.search(assign.group(2)):
            out.add(assign.group(1))
    return out


def _redirect_clobber(seg: list[str], central_vars: set[str]) -> bool:
    """A truncating redirect (`>`, `>|`, `&>`) whose target is the central file."""
    for i, token in enumerate(seg):
        if token in _TRUNC_REDIRECTS and i + 1 < len(seg):
            if _is_central(seg[i + 1], central_vars):
                return True
    return False


def _copy_clobber(seg: list[str], central_vars: set[str]) -> bool:
    """`cp`/`mv`/`install`/`rsync`/`ln` with the central file as destination.

    The destination is the last positional; the central file appearing earlier
    (as a *source*, e.g. `cp <central> backup`) is not a clobber and stays allowed.
    """
    i = _command_start(seg)
    if i >= len(seg) or _base(seg[i]) not in _COPY_CMDS:
        return False
    positionals = [t for t in _strip_redirects(seg[i + 1 :]) if not t.startswith("-")]
    return len(positionals) >= 2 and _is_central(positionals[-1], central_vars)


def _named_write_clobber(seg: list[str], central_vars: set[str]) -> bool:
    """`tee`/`sponge` writing the central file (truncating, no append flag)."""
    i = _command_start(seg)
    if i >= len(seg) or _base(seg[i]) not in _NAMED_WRITE_CMDS:
        return False
    args = _strip_redirects(seg[i + 1 :])
    if _base(seg[i]) == "tee" and any(a in _APPEND_FLAGS for a in args):
        return False
    return any(_is_central(a, central_vars) for a in args if not a.startswith("-"))


def _dd_clobber(seg: list[str], central_vars: set[str]) -> bool:
    """`dd` writing the central file via `of=`."""
    i = _command_start(seg)
    if i >= len(seg) or _base(seg[i]) != "dd":
        return False
    return any(
        token.startswith("of=") and _is_central(token[3:], central_vars)
        for token in seg[i + 1 :]
    )


_CLOBBERS = (_redirect_clobber, _copy_clobber, _named_write_clobber, _dd_clobber)


def _scan_command(cmd: str) -> bool:
    """True if any segment of `cmd` clobbers the central file.

    Unbalanced quotes (`tokenize` raises `ValueError`) fail open: the well-formed
    copy forms are the ones that recur, and blocking a broken command reads as a
    false positive.
    """
    try:
        tokens = _tokenize(cmd)
    except ValueError:
        return False
    central_vars = _central_vars(tokens)
    return any(
        check(seg, central_vars) for seg in _segments(tokens) for check in _CLOBBERS
    )


_MESSAGE = (
    "refusing to overwrite ~/.config/research/.env as a whole file. It is the "
    "central secrets file shared by every *-research repo (scripts/lib/http.sh "
    "loads it first, then the repo-local .env). A whole-file copy replaces it "
    "with one repo's keys and wipes every other repo's -- that is how the shared "
    "H1_* creds were lost. Edit it in place, or append a single key "
    "(printf 'KEY=VALUE\\n' >> ~/.config/research/.env). Repo-specific keys "
    "belong in the repo-local .env, which http.sh already layers on top -- they "
    "never need to be copied into the central file."
)


def _blocks(tool_name: object, tool_input: object) -> bool:
    if not isinstance(tool_input, dict):
        return False
    if tool_name == "Write":
        file_path = tool_input.get("file_path", "")
        return isinstance(file_path, str) and _RE_CENTRAL.search(file_path) is not None
    if tool_name == "Bash":
        cmd = tool_input.get("command", "")
        return isinstance(cmd, str) and bool(cmd) and _scan_command(cmd)
    return False


def main() -> int:
    try:
        data = json.load(sys.stdin)
    except (json.JSONDecodeError, UnicodeDecodeError):
        return 0  # malformed input: nothing to scan, fail open quietly
    if not isinstance(data, dict):
        return 0
    try:
        hit = _blocks(data.get("tool_name"), data.get("tool_input"))
    except Exception as exc:  # noqa: BLE001 -- fail closed + loud, see guard_io
        return fail_closed("block-research-env-clobber.py", exc)
    return block(_MESSAGE) if hit else 0


if __name__ == "__main__":
    sys.exit(main())
