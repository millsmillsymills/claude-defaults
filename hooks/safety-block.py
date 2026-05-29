#!/usr/bin/env python3
"""PreToolUse(Bash) hook: block catastrophic destructive commands.

Parses the command with ``shlex`` and inspects the resulting tokens, so a
payload tucked inside ``bash -c '...'``, ``sh -c '...'`` or ``eval '...'`` is
unwrapped and checked too -- the previous shell implementation stripped quoted
strings before matching, which let any of those wrappers bypass every pattern.

Exit 2 with an explanation blocks the call; exit 0 allows it. Any unexpected
internal error exits 0 (fail-open): a parser edge case must never wedge the
session, and ``permissions.deny`` in settings.json is the hard backstop for the
``rm -rf`` / ``sudo`` classes regardless of what this hook does.
"""
from __future__ import annotations

import json
import re
import shlex
import sys

_OPERATORS = {"&&", "||", ";", "|", "&", "\n"}
_SHELL_WRAPPERS = {"bash", "sh", "zsh", "dash", "ksh"}
_MAX_DEPTH = 5

_RE_ENV = re.compile(r"^[A-Za-z_]\w*=")
_RE_DD_DISK = re.compile(r"^of=/dev/(?:disk|sd|nvme|rdisk)")
_PROTECTED_BRANCHES = ("main", "master", "production", "prod")
# A fork bomb anchored at the start of a (de-quoted) segment, so a literal
# `echo ":(){ :|:& };:"` -- where the pattern is an argument, not the command
# being defined -- is not mistaken for the real thing.
_RE_FORK_BOMB = re.compile(r"^:\s*\(\)\s*\{.*\|.*&.*\}", re.DOTALL)


def _base(token: str) -> str:
    """Return the command basename (strip any leading path)."""
    return token.rsplit("/", 1)[-1]


def _is_protected_target(token: str) -> bool:
    """True if `token` names /, /Users, the home dir, or a child of them."""
    if token in ("/", "/Users", "~", "$HOME"):
        return True
    return token.startswith(("/Users/", "~/", "$HOME/"))


def _has_recursive_force(flags: list[str]) -> bool:
    """True if `flags` request both recursive and force in any arrangement."""
    recursive = force = False
    for token in flags:
        if token == "--recursive":
            recursive = True
        elif token == "--force":
            force = True
        elif token.startswith("-"):
            if "r" in token.lower():
                recursive = True
            if "f" in token:
                force = True
    return recursive and force


def _is_rm_rf_protected(seg: list[str]) -> bool:
    """`rm` with recursive+force flags targeting a protected path, same call.

    Leading `sudo` and `VAR=value` assignments are skipped so they don't hide
    the `rm`; the flags and the protected target must belong to this segment
    (one invocation), so `cp -r /Users/x dst && rm -f junk` can't combine.
    """
    i = 0
    while i < len(seg) and (seg[i] == "sudo" or _RE_ENV.match(seg[i])):
        i += 1
    if i >= len(seg) or seg[i] != "rm":
        return False
    rest = seg[i + 1:]
    return _has_recursive_force(rest) and any(_is_protected_target(t) for t in rest)


def _is_sudo_rm_rf(seg: list[str]) -> bool:
    """`sudo rm` with recursive+force flags against any target."""
    return len(seg) >= 2 and seg[0] == "sudo" and seg[1] == "rm" \
        and _has_recursive_force(seg[2:])


def _is_dd_to_disk(seg: list[str]) -> bool:
    """`dd` writing to a raw disk device."""
    return bool(seg) and _base(seg[0]) == "dd" \
        and any(_RE_DD_DISK.match(t) for t in seg)


def _is_mkfs(seg: list[str]) -> bool:
    """A filesystem-creation or wipe command (`mkfs*`, `wipefs`)."""
    if not seg:
        return False
    base = _base(seg[0])
    return base.startswith("mkfs") or base == "wipefs"


def _is_disk_partition(seg: list[str]) -> bool:
    """`fdisk`/`parted` invoked with a write operation on a device."""
    if not seg:
        return False
    base = _base(seg[0])
    if base == "fdisk":
        return "-w" in seg or any(t.startswith("/dev/") for t in seg)
    if base == "parted":
        return any(t.startswith("/dev/") for t in seg) \
            and any(t in ("mklabel", "mkpart", "rm", "resizepart") for t in seg)
    return False


def _is_chmod_777(seg: list[str]) -> bool:
    """`chmod -R 777` against / or the home dir."""
    if "chmod" not in [_base(t) for t in seg]:
        return False
    recursive = any(t.startswith("-") and "R" in t for t in seg)
    return recursive and "777" in seg and any(_is_protected_target(t) for t in seg)


def _targets_protected_branch(ref: str) -> bool:
    """True if a push refspec resolves to main/master/production/prod."""
    parts = re.split(r"[:/]", ref.lstrip("+"))
    return any(p in _PROTECTED_BRANCHES for p in parts)


def _is_force_push(seg: list[str]) -> bool:
    """`git push --force` to a protected branch, or with no branch named.

    A force push that names a non-protected branch (the common rebase-then-push
    of your own feature branch) is allowed; a force push that targets a
    protected branch -- or names none, so it pushes the current branch which may
    be protected -- is blocked.
    """
    if "git" not in [_base(t) for t in seg] or "push" not in seg:
        return False
    if not any(t in ("-f", "--force", "--force-with-lease") for t in seg):
        return False
    positionals = [t for t in seg[seg.index("push") + 1:] if not t.startswith("-")]
    branches = positionals[1:]  # first positional is the remote
    return any(_targets_protected_branch(b) for b in branches) or not branches


def _is_fork_bomb(seg: list[str]) -> bool:
    return bool(_RE_FORK_BOMB.match(" ".join(seg)))


_CHECKS: list[tuple] = [
    (_is_rm_rf_protected,
     "rm -rf against root, /Users, ~, or $HOME. Use 'trash' or a specific path."),
    (_is_sudo_rm_rf,
     "sudo rm -rf is too dangerous. Run targeted deletes manually if needed."),
    (_is_dd_to_disk,
     "dd writing to /dev/disk*, /dev/sd*, /dev/nvme*, or /dev/rdisk* destroys "
     "the disk. Refusing."),
    (_is_mkfs, "mkfs/wipefs against any device wipes data. Refusing."),
    (_is_disk_partition, "fdisk/parted write operation. Refusing."),
    (_is_fork_bomb, "fork bomb pattern detected."),
    (_is_chmod_777,
     "chmod -R 777 against / or ~ is destructive (loses original perms). "
     "Refusing."),
    (_is_force_push,
     "force-push detected. Use a feature branch and PR, not a force push."),
]


def _segments(tokens: list[str]):
    """Split a token list into command segments on shell operators."""
    seg: list[str] = []
    for token in tokens:
        if token in _OPERATORS:
            if seg:
                yield seg
                seg = []
        else:
            seg.append(token)
    if seg:
        yield seg


def _nested_payloads(seg: list[str]):
    """Yield nested command strings carried by `bash -c`/`eval`/... in `seg`."""
    if not seg:
        return
    base = _base(seg[0])
    if base in _SHELL_WRAPPERS:
        for i, token in enumerate(seg):
            if token == "-c" and i + 1 < len(seg):
                yield seg[i + 1]
                break
    elif base == "eval":
        payload = " ".join(seg[1:])
        if payload:
            yield payload


def _check_segment(seg: list[str]) -> str | None:
    for predicate, reason in _CHECKS:
        if predicate(seg):
            return reason
    return None


def _fallback_scan(cmd: str) -> str | None:
    """Quote-unbalanced input shlex can't parse: strip quotes and re-check.

    Reintroduces the old quote-strip approximation only for the rare malformed
    case, so a dangerous command with broken quoting is still caught.
    """
    cleaned = cmd.replace('"', " ").replace("'", " ")
    for piece in re.split(r"&&|\|\||[;|&\n]", cleaned):
        reason = _check_segment(piece.split())
        if reason:
            return reason
    return None


def scan(cmd: str, depth: int = 0) -> str | None:
    """Return a block reason for `cmd`, recursing into wrapped payloads."""
    if depth > _MAX_DEPTH:
        return None
    try:
        tokens = shlex.split(cmd)
    except ValueError:
        return _fallback_scan(cmd)
    for seg in _segments(tokens):
        reason = _check_segment(seg)
        if reason:
            return reason
        for payload in _nested_payloads(seg):
            reason = scan(payload, depth + 1)
            if reason:
                return reason
    return None


def main() -> int:
    try:
        data = json.load(sys.stdin)
        cmd = data.get("tool_input", {}).get("command", "")
    except (json.JSONDecodeError, AttributeError, ValueError):
        return 0
    if not cmd:
        return 0
    reason = scan(cmd)
    if reason:
        print(f"BLOCKED: {reason}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
