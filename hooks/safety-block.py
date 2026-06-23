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
    DepthLimitExceeded as _DepthLimitExceeded,
    base as _base,
    command_start as _command_start,
    fallback_payload as _fallback_payload,
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
# `~name` / `~name/...` names a user's home dir, as catastrophic to recursively
# delete as bare `~`. A bare `~` and `~/...` are handled by the literal set.
_RE_TILDE_USER = re.compile(r"~[A-Za-z_][A-Za-z0-9_-]*(/|$)")
# An innermost brace (no nested braces in its body). Expanding the innermost
# first resolves nested forms (`/{etc,x{a..b}}`) to a fixed point.
_RE_INNERMOST_BRACE = re.compile(r"\{([^{}]*)\}")


def _sequence_alternatives(body: str, limit: int) -> list[str] | None:
    """Alternatives for a `{a..b}` / `{m..n}` brace sequence body, else None.

    Covers single-char (`a..f`) and integer (`1..9`, `9..1`) ranges -- the forms
    the shell expands to a literal that can reach a protected root. The range is
    sliced to `limit + 1` *before* it is materialized, so `{1..100000000}` builds
    a bounded list (and trips the caller's overflow -> fail-closed path) instead
    of allocating the whole sequence and hanging the hook.
    """
    parts = body.split("..")
    if len(parts) != 2:
        return None
    start, stop = parts
    if re.fullmatch(r"-?[0-9]+", start) and re.fullmatch(r"-?[0-9]+", stop):
        lo, hi, convert = int(start), int(stop), str
    elif len(start) == 1 and len(stop) == 1:
        lo, hi, convert = ord(start), ord(stop), chr
    else:
        return None
    step = 1 if lo <= hi else -1
    return [convert(x) for x in range(lo, hi + step, step)[: limit + 1]]


def _brace_alternatives(body: str, limit: int) -> list[str] | None:
    """The alternatives a single brace body expands to (comma list or sequence)."""
    if "," in body:
        return body.split(",")
    return _sequence_alternatives(body, limit)


def _brace_expand(token: str, limit: int = 256) -> tuple[list[str], bool]:
    """Expand brace alternatives to a fixed point; report whether the bound hit.

    `rm -rf /{etc,usr}` reaches the hook as one literal token the shell would
    expand to `/etc /usr`. Innermost braces are expanded first, so comma lists,
    `{a..b}` sequences, and nested combinations (`/{etc,x{a..b}}`) all resolve. A
    hostile blowup would drop unchecked alternatives, so on hitting `limit` the
    second element is True and the caller fails closed rather than trusting a
    truncated expansion.
    """
    results = [token]
    truncated = False
    while not truncated:
        progressed = False
        expanded: list[str] = []
        for item in results:
            alts, span = _first_expandable_brace(item, limit)
            if alts is None:
                expanded.append(item)
                continue
            progressed = True
            pre, post = item[: span[0]], item[span[1] :]
            for alt in alts:
                expanded.append(pre + alt + post)
                if len(expanded) >= limit:
                    truncated = True
                    break
            if truncated:
                break
        results = expanded
        if not progressed:
            break
    return results, truncated


def _first_expandable_brace(
    token: str, limit: int
) -> tuple[list[str] | None, tuple[int, int]]:
    """The alternatives and span of the first expandable innermost brace.

    Skips an innermost brace that is neither a comma list nor a sequence (a bare
    `{abc}` the shell leaves literal), so a later expandable brace is still found.
    """
    for match in _RE_INNERMOST_BRACE.finditer(token):
        alts = _brace_alternatives(match.group(1), limit)
        if alts is not None:
            return alts, (match.start(), match.end())
    return None, (0, 0)


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


def _prefix_reaches_protected_root(prefix: str) -> bool:
    """True if `prefix` can complete into a protected root.

    The prefix reaches a root when the literal is a prefix of the root
    (`/Us` -> `/Users`) or the root (or a child of it) is a prefix of the literal
    (`/etc`). A prefix that cannot reach any root (`/usr-mirror`) stays allowed.
    """
    if not prefix or prefix[0] not in "/~$":
        return False
    for root in ("/", *_PROTECTED_SYSTEM_DIRS, *_HOME_TARGETS):
        if root.startswith(prefix) or prefix == root or prefix.startswith(root + "/"):
            return True
    return False


def _glob_reaches_protected(token: str) -> bool:
    """True if a glob's literal prefix can expand to reach a protected root.

    `/Us*` can expand to `/Users`, `/et*` to `/etc`, `~*` to `~` -- the glob
    defeats a literal-path check by completing the part before the first glob
    char. `/usr-mirror*` and `./build/*` reach no root, so stay allowed.
    """
    cut = min((token.find(c) for c in _GLOB_CHARS if c in token), default=-1)
    if cut < 0:
        return False
    return _prefix_reaches_protected_root(token[:cut])


def _brace_prefix_reaches_protected(token: str) -> bool:
    """A residual non-expandable brace (`{abc}`) whose literal prefix only
    completes into a protected root (`/et{c}` -> /etc).

    Comma lists and `{a..b}` sequences are expanded by `_brace_expand`; what
    remains is a brace the shell leaves literal. A prefix of `""` or `/` is too
    coarse to judge (it would flag a harmless `/tmp{...}`), so only a more
    specific prefix is checked.
    """
    prefix = token[: token.index("{")]
    return len(prefix) > 1 and _prefix_reaches_protected_root(prefix)


def _brace_reaches_protected(token: str) -> bool:
    """True if a brace token can expand to reach a protected root.

    Comma lists and `{a..b}` sequences are expanded and each result re-checked;
    a residual non-expandable brace (`{abc}`) falls back to the literal-prefix
    rule; an expansion that overflows the bound fails closed rather than dropping
    unchecked candidates.
    """
    expansions, truncated = _brace_expand(token)
    if truncated:
        return True
    for expanded in expansions:
        if "{" in expanded:
            if _brace_prefix_reaches_protected(expanded):
                return True
        elif expanded != token and _is_protected_target(expanded):
            return True
    return False


def _is_protected_target(token: str) -> bool:
    """True if `token` names root, a system dir, the home dir, or a child.

    Covers the bare path, a root/system glob (`/*`, `/usr/*`), children
    (`/etc/cron.d`), `/./` and `//` normalization, globs whose literal prefix
    can expand to a protected root (`/Us*`, `~*`), `~user` home dirs, and brace
    alternatives that reach a protected root (`/{etc,usr}`). The narrow original
    set (only `/`, `/Users`, `~`) let `rm -rf /*`, `/etc`, `/Users*` through.
    """
    token = _normalize_leading(token)
    if token in ("/", "/*", "/Users", "~", "$HOME", "${HOME}"):
        return True
    if token.startswith(("/Users/", "~/", "$HOME/", "${HOME}/")):
        return True
    if _RE_TILDE_USER.match(token):
        return True
    if any(
        token == d or token == d + "/*" or token.startswith(d + "/")
        for d in _PROTECTED_SYSTEM_DIRS
    ):
        return True
    if _glob_reaches_protected(token):
        return True
    return "{" in token and _brace_reaches_protected(token)


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


def _command_base(seg: list[str]) -> str:
    """Basename of the real command after skipping launcher/brace prefixes.

    `dd`/`mkfs`/`fdisk`/`chmod` checks inspected `seg[0]` directly, so a launcher
    prefix (`sudo dd ...`, `command mkfs ...`, `env mkfs ...`) or a brace group
    (`{ ... }`) hid the command behind a token -- routing through the shared
    launcher-skip recognizes those forms the way `rm`/`git` already do.
    """
    i = _command_start(seg)
    return _base(seg[i]) if i < len(seg) else ""


def _is_dd_to_disk(seg: list[str]) -> bool:
    """`dd` writing to a raw disk device."""
    return _command_base(seg) == "dd" and any(_RE_DD_DISK.match(t) for t in seg)


def _is_mkfs(seg: list[str]) -> bool:
    """A filesystem-creation or wipe command (`mkfs*`, `wipefs`)."""
    base = _command_base(seg)
    return base.startswith("mkfs") or base == "wipefs"


def _is_disk_partition(seg: list[str]) -> bool:
    """`fdisk`/`parted` invoked with a write operation on a device."""
    base = _command_base(seg)
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


def _is_octal_world_writable(mode: str) -> bool:
    """True for an octal mode granting rwx to all (`777`, `0777`, `1777`, ...)."""
    if not mode or any(c not in "01234567" for c in mode):
        return False
    return int(mode, 8) & 0o777 == 0o777


# A symbolic chmod clause: a `who` (`[ugoa]*`) then one or more op groups, e.g.
# `o+w`, `a=rwx`, `=rwx`, `a-x+w` (a single clause can chain ops). Each op's
# argument is either a literal perm set (`[rwxXst]*`) or a reference-letter set
# (`[ugo]+`, the reference-copy form `o=u`/`o=ug` -- copy owner/group bits to
# other); the reference is matched first so `=u` is read as a copy, not an empty
# perm set. Comma joins separate clauses, split before this is applied.
_RE_SYMBOLIC_CLAUSE = re.compile(r"^([ugoa]*)((?:[-+=](?:[ugo]+|[rwxXst]*))+)$")
_RE_SYMBOLIC_OP = re.compile(r"([-+=])([ugo]+|[rwxXst]*)")
# chmod's own short flags, stripped off a bundled token to reach the mode.
_CHMOD_FLAG_LETTERS = "RvfchHLP"


def _clause_world_writable(clause: str) -> bool:
    """True for a symbolic clause that grants write to other/all.

    `o+w`, `a+rwx`, `a=rwx`, a bare-`who` `=rwx`/`+w` (applies to all), and a
    multi-op clause that grants write somewhere (`a-x+w`) all count; `u+w`/`g+w`
    (owner/group only) and pure `-` removals do not. A reference-copy to other/all
    that names owner or group as a source (`o=u`, `a=g`, `o=ug`) may carry that
    source's write bit, so it counts too. A grant anywhere in the clause is
    treated as world-writable -- erring toward blocking.
    """
    match = _RE_SYMBOLIC_CLAUSE.match(clause)
    if match is None:
        return False
    who, ops = match.groups()
    if not (who == "" or "o" in who or "a" in who):
        return False
    return any(
        op in "+=" and ("w" in perms or any(src in "ug" for src in perms))
        for op, perms in _RE_SYMBOLIC_OP.findall(ops)
    )


def _chmod_mode_token(token: str) -> str:
    """The mode portion of a chmod arg, with a leading short-flag run stripped.

    `-R777` -> `777`, `-Ra=rwx` -> `a=rwx`. A `--long` option carries no mode.
    """
    if token.startswith("--"):
        return ""
    if token.startswith("-"):
        i = 1
        while i < len(token) and token[i] in _CHMOD_FLAG_LETTERS:
            i += 1
        return token[i:].lstrip("=")
    return token


def _is_world_writable_mode(token: str) -> bool:
    """True if `token` is a chmod mode -- octal or symbolic, standalone or bundled
    into a short flag -- that grants write to everyone."""
    mode = _chmod_mode_token(token)
    if _is_octal_world_writable(mode):
        return True
    return any(_clause_world_writable(c) for c in mode.split(","))


def _is_chmod_777(seg: list[str]) -> bool:
    """Recursive, world-writable `chmod` against / or the home dir.

    Normalizes the mode (`0777` == `777`, octal or symbolic `a=rwx`) and treats
    `--recursive` like `-R`. A bundled `-R777`/`-Ra=rwx` token carries both the
    recursive flag and the mode, so each predicate is checked independently.
    """
    if _command_base(seg) != "chmod":
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


def _fallback_scan(cmd: str, depth: int = 0) -> str | None:
    """Quote-unbalanced input shlex can't parse: strip quotes and re-check.

    The old approximation never re-entered a `bash -c '...'` payload, so a
    wrapped destructive command with broken quoting slipped through; the
    de-quoted wrapper tail is now re-scanned too.
    """
    if depth > _MAX_DEPTH:
        raise _DepthLimitExceeded(f"wrapper nesting exceeded {_MAX_DEPTH} levels")
    cleaned = cmd.replace('"', " ").replace("'", " ")
    for piece in re.split(r"&&|\|\||[;|&\n()]", cleaned):
        seg = piece.split()
        if not seg:
            continue
        reason = _check_segment(seg)
        if reason:
            return reason
        payload = _fallback_payload(seg)
        if payload:
            reason = _fallback_scan(payload, depth + 1)
            if reason:
                return reason
    return None


def scan(cmd: str, depth: int = 0) -> str | None:
    """Return a block reason for `cmd`, recursing into wrapped payloads.

    Nesting past `_MAX_DEPTH` raises `DepthLimitExceeded` so `main` fails closed:
    the inner command would otherwise go unscanned and be allowed.
    """
    if depth > _MAX_DEPTH:
        raise _DepthLimitExceeded(f"wrapper nesting exceeded {_MAX_DEPTH} levels")
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
