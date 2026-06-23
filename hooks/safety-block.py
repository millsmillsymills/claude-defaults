#!/usr/bin/env python3
"""PreToolUse(Bash) hook: block catastrophic destructive commands.

Tokenizes the command with the shared ``cmdscan`` parser and inspects the
resulting segments, so a payload tucked inside ``bash -c '...'``, ``sh -c
'...'`` or ``eval '...'``, and commands hidden after unspaced separators
(``true;mkfs ...``), are unwrapped and checked too -- the previous shell
implementation stripped quoted strings before matching, which let any of those
wrappers bypass every pattern.

Exit 2 with an explanation blocks the call; exit 0 allows it. Malformed input
(unparseable JSON, a non-string command) fails *open* -- there is nothing to
scan, so a parser edge case never wedges the session, and ``permissions.deny``
in settings.json is the hard backstop for the ``rm -rf`` / ``sudo`` classes. A
*scan crash* fails *closed* (see ``guard_io.fail_closed``): a matcher threw on a
real command, so there is no verdict, and the destructive classes with no
deny-list backstop (``dd``, ``mkfs``, fork bombs, ...) would otherwise pass
unchecked. That one command is blocked and the crash is logged loudly.
"""

from __future__ import annotations

import posixpath
import re
import sys
from pathlib import Path

# Shared command tokenization lives in hooks/lib so all three guards parse a
# command the same way. The path is injected at runtime (the hook may run from a
# symlink), so static resolution can't see the module.
sys.path.insert(0, str(Path(__file__).resolve().parent / "lib"))

from cmdscan import (  # noqa: E402  # ty: ignore[unresolved-import]
    base as _base,
    has_recursive_force as _has_recursive_force,
    nested_payloads as _nested_payloads,
    rm_invocation as _rm_invocation,
    segments as _segments,
    strip_redirects as _strip_redirects,
    tokenize as _tokenize,
)
from guard_io import (  # noqa: E402  # ty: ignore[unresolved-import]
    block,
    fail_closed,
    read_command,
)

_MAX_DEPTH = 5

_RE_DD_DISK = re.compile(r"^of=/dev/(?:disk|sd|nvme|rdisk)")
_PROTECTED_BRANCHES = ("main", "master", "production", "prod")
# Top-level system directories an `rm -rf` (or `chmod -R 777`) must never touch.
# Deliberately excludes the temp dirs (/tmp, /private, /dev) so legitimate
# scratch deletes and `> /dev/null` redirects are not false-positives.
_PROTECTED_SYSTEM_DIRS = (
    "/etc",
    "/usr",
    "/bin",
    "/sbin",
    "/var",
    "/opt",
    "/lib",
    "/lib64",
    "/boot",
    "/root",
    "/System",
    "/Library",
    "/Applications",
    "/home",
)
# A fork bomb anchored at the start of a command string, so a literal
# `echo ":(){ :|:& };:"` -- where the pattern is an argument, not the command
# being defined -- is not mistaken for the real thing.
_RE_FORK_BOMB = re.compile(r"^\s*:\s*\(\)\s*\{.*\|.*&.*\}", re.DOTALL)


_HOME_TARGETS = ("/Users", "~", "$HOME", "${HOME}")
_GLOB_CHARS = "*?["


def _normalize_leading(token: str) -> str:
    """Collapse `/./` and repeated slashes in an absolute path's lead.

    `rm -rf /./etc`, `//etc`, and `/.//etc` all name `/etc`, but the literal
    prefix check would miss them. `posixpath.normpath` resolves `.`/`..` and
    single redundant slashes; POSIX keeps a leading `//`, so collapse that too.
    Only absolute paths are normalized; relative paths and `~`/`$HOME` forms are
    returned unchanged so normpath never rewrites a non-path token.
    """
    if not token.startswith("/"):
        return token
    normalized = posixpath.normpath(token)
    while normalized.startswith("//"):
        normalized = normalized[1:]
    return normalized


def _glob_reaches_protected(token: str) -> bool:
    """True if a glob's literal prefix can expand to reach a protected root.

    `/Us*` can expand to `/Users`, `/et*` to `/etc`, `~*` to `~` -- the glob
    defeats a literal-path check. Compares the part before the first glob char
    against each protected root: the glob reaches the root when the literal is a
    prefix of the root (`/Us` -> `/Users`) or the root (or a child of it) is a
    prefix of the literal (`/etc*`). A literal that cannot reach any root
    (`/usr-mirror*`, `./build/*`) stays allowed.
    """
    cut = min((token.find(c) for c in _GLOB_CHARS if c in token), default=-1)
    if cut < 0:
        return False
    prefix = token[:cut]
    if not prefix or prefix[0] not in "/~$":
        return False
    roots = ("/", *_PROTECTED_SYSTEM_DIRS, *_HOME_TARGETS)
    for root in roots:
        if root.startswith(prefix):
            return True
        if prefix == root or prefix.startswith(root + "/"):
            return True
    return False


def _is_protected_target(token: str) -> bool:
    """True if `token` names root, a system dir, the home dir, or a child.

    Covers the bare path, a root/system glob (`/*`, `/usr/*`), children
    (`/etc/cron.d`), `/./` and `//` normalization, and globs whose literal
    prefix can expand to a protected root (`/Us*`, `~*`). The narrow original
    set (only `/`, `/Users`, `~`) let `rm -rf /*`, `/etc`, `/Users*` through.
    """
    token = _normalize_leading(token)
    if token in ("/", "/*", "/Users", "~", "$HOME", "${HOME}"):
        return True
    if token.startswith(("/Users/", "~/", "$HOME/", "${HOME}/")):
        return True
    if any(
        token == d or token == d + "/*" or token.startswith(d + "/")
        for d in _PROTECTED_SYSTEM_DIRS
    ):
        return True
    return _glob_reaches_protected(token)


def _is_rm_rf_protected(seg: list[str]) -> bool:
    """`rm` with recursive+force flags targeting a protected path, same call.

    The flags and the protected target must belong to this segment (one
    invocation), so `cp -r /Users/x dst && rm -f junk` can't combine.
    """
    i = _rm_invocation(seg)
    if i < 0:
        return False
    rest = _strip_redirects(seg[i + 1 :])
    return _has_recursive_force(rest) and any(_is_protected_target(t) for t in rest)


def _is_sudo_rm_rf(seg: list[str]) -> bool:
    """`sudo rm` with recursive+force flags against any target."""
    i = _rm_invocation(seg)
    if i < 0 or "sudo" not in seg[:i]:
        return False
    return _has_recursive_force(_strip_redirects(seg[i + 1 :]))


def _is_dd_to_disk(seg: list[str]) -> bool:
    """`dd` writing to a raw disk device."""
    return (
        bool(seg) and _base(seg[0]) == "dd" and any(_RE_DD_DISK.match(t) for t in seg)
    )


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
        return any(t.startswith("/dev/") for t in seg) and any(
            t in ("mklabel", "mkpart", "rm", "resizepart") for t in seg
        )
    return False


def _is_chmod_recursive(token: str) -> bool:
    """True for a recursive chmod flag (`--recursive` or a `-R` short bundle).

    Lowercase `-r` is the symbolic *read* perm, not recursion, so only `R` in a
    short bundle counts; `--recursive` was missed entirely before.
    """
    if token == "--recursive":
        return True
    return token.startswith("-") and not token.startswith("--") and "R" in token


def _is_world_writable_mode(token: str) -> bool:
    """True for an octal mode granting rwx to all (`777`, `0777`, `1777`, ...)."""
    if not token or any(c not in "01234567" for c in token):
        return False
    return int(token, 8) & 0o777 == 0o777


def _is_chmod_777(seg: list[str]) -> bool:
    """Recursive, world-writable `chmod` against / or the home dir.

    Normalizes the mode (`0777` == `777`) and treats `--recursive` like `-R` --
    `chmod -R 0777 ~` and `chmod --recursive 777 ~` both slipped through before.
    """
    if "chmod" not in [_base(t) for t in seg]:
        return False
    rest = _strip_redirects(seg)
    return (
        any(_is_chmod_recursive(t) for t in rest)
        and any(_is_world_writable_mode(t) for t in rest)
        and any(_is_protected_target(t) for t in rest)
    )


def _push_dest(ref: str) -> str:
    """The destination branch of a push refspec (the part after the last ':').

    Strips a leading `+` (force refspec) and a `refs/heads/` prefix. Only the
    final component is the branch, so `hotfix/prod` resolves to `hotfix/prod`,
    not `prod` -- the old `[:/]` split flagged any path component as protected.
    """
    dest = ref.lstrip("+").rsplit(":", 1)[-1]
    prefix = "refs/heads/"
    if dest.startswith(prefix):
        dest = dest[len(prefix) :]
    return dest


def _targets_protected_branch(ref: str) -> bool:
    """True if a push refspec's destination is main/master/production/prod."""
    return _push_dest(ref) in _PROTECTED_BRANCHES


def _is_force_push(seg: list[str]) -> bool:
    """`git push --force` to a protected branch, or with no branch named.

    A force push that names a non-protected branch (the common rebase-then-push
    of your own feature branch) is allowed; a force push that targets a
    protected branch -- or names none, so it pushes the current branch which may
    be protected -- is blocked.
    """
    if "git" not in [_base(t) for t in seg] or "push" not in seg:
        return False
    after_push = seg[seg.index("push") + 1 :]
    positionals = [t for t in after_push if not t.startswith("-")]
    branches = positionals[1:]  # first positional is the remote
    # A leading `+` on a refspec (`git push origin +main`) is a force update
    # even with no -f/--force flag; block it if it targets a protected branch.
    if any(b.startswith("+") and _targets_protected_branch(b) for b in branches):
        return True
    if not any(t in ("-f", "--force", "--force-with-lease") for t in after_push):
        return False
    return any(_targets_protected_branch(b) for b in branches) or not branches


_CHECKS: list[tuple] = [
    (
        _is_rm_rf_protected,
        "rm -rf against root, /Users, ~, or $HOME. Use 'trash' or a specific path.",
    ),
    (
        _is_sudo_rm_rf,
        "sudo rm -rf is too dangerous. Run targeted deletes manually if needed.",
    ),
    (
        _is_dd_to_disk,
        "dd writing to /dev/disk*, /dev/sd*, /dev/nvme*, or /dev/rdisk* destroys "
        "the disk. Refusing.",
    ),
    (_is_mkfs, "mkfs/wipefs against any device wipes data. Refusing."),
    (_is_disk_partition, "fdisk/parted write operation. Refusing."),
    (
        _is_chmod_777,
        "chmod -R 777 against / or ~ is destructive (loses original perms). Refusing.",
    ),
    (
        _is_force_push,
        "force-push detected. Use a feature branch and PR, not a force push.",
    ),
]


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
    # Fork bombs are matched on the raw string: punctuation tokenization splits
    # the `()`/`|`/`&` the pattern is built from across segments, so a
    # per-segment check could never see the whole thing.
    if _RE_FORK_BOMB.match(cmd):
        return "fork bomb pattern detected."
    try:
        tokens = _tokenize(cmd)
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
    cmd = read_command()
    if not cmd:
        return 0  # malformed input: nothing to scan, fail open quietly
    try:
        reason = scan(cmd)
    except Exception as exc:  # noqa: BLE001 -- fail closed + loud, see guard_io
        return fail_closed("safety-block.py", exc)
    if reason:
        return block(reason)
    return 0


if __name__ == "__main__":
    sys.exit(main())
