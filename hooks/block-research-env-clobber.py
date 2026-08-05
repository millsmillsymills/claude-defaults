#!/usr/bin/env python3
"""PreToolUse(Bash|Write) hook: block whole-file overwrites of the central
research secrets file (``~/.config/research/.env``).

That file is shared by every ``*-research`` repo -- ``scripts/lib/http.sh`` loads
it first, then the repo-local ``.env`` for per-target overrides. It must hold only
the shared cross-repo credentials and be edited or key-merged *in place*. Copying
a whole file over it (``cp``/``mv``/``tee``/a truncating ``>``/``install``/``dd``)
replaces it with one repo's slice and wipes every other repo's keys -- exactly how
the shared credentials have been lost before. This guard denies the clobbering
forms while allowing reads, appends (``>>``), and in-place Edits.

Exit 2 blocks the call; exit 0 allows it. Malformed input fails *open* (there is
nothing to scan). A scan crash -- including ``DepthLimitExceeded`` from wrapper
nesting -- fails *closed* via ``guard_io.fail_closed``, the same posture as the
sibling destructive-command guards.
"""

from __future__ import annotations

import json
import posixpath
import re
import sys
from pathlib import Path

# Shared command tokenization lives in hooks/lib; the path is injected at runtime
# because the hook may run from a symlink, so static resolution can't see it.
sys.path.insert(0, str(Path(__file__).resolve().parent / "lib"))

from cmdscan import (  # noqa: E402  # ty: ignore[unresolved-import]
    base as _base,
    command_start as _command_start,
    iter_segments as _iter_segments,
    strip_redirects as _strip_redirects,
)
from guard_io import block, fail_closed  # noqa: E402  # ty: ignore[unresolved-import]

# The central file at the end of a path token: `.config/research/.env` with a
# slash (or string start) before `.config`, so `.env.example` and an unrelated
# `myconfig/research/.env` are both excluded. Tokens are normalized first, so
# `.//`, `./`, and `research/../research` spellings collapse before matching.
_RE_CENTRAL = re.compile(r"(?:^|/)\.config/research/\.env$")
_RE_CENTRAL_DIR = re.compile(r"(?:^|/)\.config/research$")
_RE_ASSIGN = re.compile(r"^([A-Za-z_]\w*)=(.*)$")
_RE_VARREF = re.compile(r"^\$\{?([A-Za-z_]\w*)\}?$")
# Truncating redirect operators as the tokenizer emits them. `>>` (append) and
# the `>&`/dup forms are deliberately excluded -- only a truncating write to the
# central file clobbers it.
_TRUNC_REDIRECTS = {">", ">|", "&>"}
_COPY_CMDS = {"cp", "mv", "install", "rsync", "ln"}
_TARGET_DIR_FLAGS = {"-t", "--target-directory"}
# Commands whose named-file argument is overwritten in place unless an append
# flag is given (`truncate` has no append form; any size rewrite clobbers).
_NAMED_WRITE_CMDS = {"tee", "sponge", "truncate"}
_APPEND_CAPABLE = {"tee", "sponge"}
# Downloaders that overwrite a named output file.
_FETCH_OUTPUT_FLAGS = {"curl": {"-o", "--output"}, "wget": {"-O", "--output-document"}}


def _normalize(path: str) -> str:
    """Collapse `.`/`..`/`//` segments and trim whitespace before matching."""
    return posixpath.normpath(path.strip())


def _is_central(token: str, central_vars: set[str]) -> bool:
    """True if `token` names the central file directly or via a resolved var."""
    ref = _RE_VARREF.match(token)
    if ref:
        return ref.group(1) in central_vars
    return _RE_CENTRAL.search(_normalize(token)) is not None


def _is_central_dir(token: str) -> bool:
    return _RE_CENTRAL_DIR.search(_normalize(token)) is not None


def _central_vars(tokens: list[str]) -> set[str]:
    """Names of shell vars assigned the central path earlier in the command.

    Catches the seeding form `f="$HOME/.config/research/.env"; ...; mv "$t" "$f"`,
    where the clobber target reaches the `mv` only through `$f`.
    """
    out: set[str] = set()
    for token in tokens:
        assign = _RE_ASSIGN.match(token)
        if assign and _RE_CENTRAL.search(_normalize(assign.group(2))):
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
    """`cp`/`mv`/`install`/`rsync`/`ln` writing over the central file.

    The destination is the last positional, or the value of `-t`/
    `--target-directory`. The central file appearing earlier (as a *source*,
    e.g. `cp <central> backup`) is not a clobber and stays allowed. A
    destination naming the *directory* clobbers just the same when a source
    basename is `.env` (`cp repo/.env ~/.config/research/`), so that form is
    treated as a write to the file itself.
    """
    i = _command_start(seg)
    if i >= len(seg) or _base(seg[i]) not in _COPY_CMDS:
        return False
    args = _strip_redirects(seg[i + 1 :])
    target_dir = None
    positionals: list[str] = []
    j = 0
    while j < len(args):
        arg = args[j]
        if arg in _TARGET_DIR_FLAGS and j + 1 < len(args):
            target_dir = args[j + 1]
            j += 2
            continue
        if arg.startswith("--target-directory="):
            target_dir = arg.split("=", 1)[1]
        elif not arg.startswith("-"):
            positionals.append(arg)
        j += 1
    if target_dir is not None:
        dest, sources = target_dir, positionals
    elif len(positionals) >= 2:
        dest, sources = positionals[-1], positionals[:-1]
    else:
        return False
    if _is_central(dest, central_vars):
        return True
    return _is_central_dir(dest) and any(
        posixpath.basename(_normalize(s)) == ".env" for s in sources
    )


def _appends(cmd: str, args: list[str]) -> bool:
    """True if an append-capable writer was given an append flag (`-a` alone or
    bundled, `tee -ai`; or `--append`)."""
    if cmd not in _APPEND_CAPABLE:
        return False
    for arg in args:
        if arg == "--append":
            return True
        if len(arg) > 1 and arg[0] == "-" and arg[1] != "-" and "a" in arg[1:]:
            return True
    return False


def _named_write_clobber(seg: list[str], central_vars: set[str]) -> bool:
    """`tee`/`sponge`/`truncate` rewriting the central file (no append flag)."""
    i = _command_start(seg)
    if i >= len(seg) or _base(seg[i]) not in _NAMED_WRITE_CMDS:
        return False
    args = _strip_redirects(seg[i + 1 :])
    if _appends(_base(seg[i]), args):
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


def _fetch_clobber(seg: list[str], central_vars: set[str]) -> bool:
    """`curl -o`/`wget -O` downloading over the central file."""
    i = _command_start(seg)
    if i >= len(seg):
        return False
    flags = _FETCH_OUTPUT_FLAGS.get(_base(seg[i]))
    if not flags:
        return False
    args = seg[i + 1 :]
    for j, arg in enumerate(args):
        if (
            arg in flags
            and j + 1 < len(args)
            and _is_central(args[j + 1], central_vars)
        ):
            return True
        if any(
            arg.startswith(f + "=") and _is_central(arg.split("=", 1)[1], central_vars)
            for f in flags
            if f.startswith("--")
        ):
            return True
    return False


_CLOBBERS = (
    _redirect_clobber,
    _copy_clobber,
    _named_write_clobber,
    _dd_clobber,
    _fetch_clobber,
)


def _scan_command(cmd: str) -> bool:
    """True if any segment of `cmd` clobbers the central file.

    `iter_segments` recurses into `bash -c`/`sh -c`/`eval` payloads and de-quotes
    unbalanced-quote commands, so wrapped and malformed spellings are scanned
    like the sibling guards do. `DepthLimitExceeded` propagates to the caller's
    fail-closed handler.
    """
    segs = list(_iter_segments(cmd))
    central_vars = _central_vars([t for seg in segs for t in seg])
    return any(check(seg, central_vars) for seg in segs for check in _CLOBBERS)


_MESSAGE = (
    "refusing to overwrite ~/.config/research/.env as a whole file. It is the "
    "central secrets file shared by every *-research repo (scripts/lib/http.sh "
    "loads it first, then the repo-local .env). A whole-file copy replaces it "
    "with one repo's keys and wipes every other repo's -- that is how the shared "
    "creds have been lost before. Edit it in place, or append a single key "
    "(printf 'KEY=VALUE\\n' >> ~/.config/research/.env). Repo-specific keys "
    "belong in the repo-local .env, which http.sh already layers on top -- they "
    "never need to be copied into the central file."
)


def _blocks(tool_name: object, tool_input: object) -> bool:
    if not isinstance(tool_input, dict):
        return False
    if tool_name == "Write":
        file_path = tool_input.get("file_path", "")
        return (
            isinstance(file_path, str)
            and _RE_CENTRAL.search(_normalize(file_path)) is not None
        )
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
