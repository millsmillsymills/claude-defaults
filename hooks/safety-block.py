#!/usr/bin/env python3
"""PreToolUse(Bash) hook: block catastrophic destructive commands.

Parses the command with ``shlex`` and inspects the resulting tokens, so a
payload tucked inside ``bash -c '...'``, ``sh -c '...'`` or ``eval '...'`` is
unwrapped and checked too -- the previous shell implementation stripped quoted
strings before matching, which let any of those wrappers bypass every pattern.

Exit 2 with an explanation blocks the call; exit 0 allows it. Malformed input
(unparseable JSON, a non-string command) fails *open* -- there is nothing to
scan, so a parser edge case never wedges the session, and ``permissions.deny``
in settings.json is the hard backstop for the ``rm -rf`` / ``sudo`` classes. A
*scan crash* fails *closed*: a matcher threw on a real command, so there is no
verdict, and the destructive classes with no deny-list backstop (``dd``,
``mkfs``, fork bombs, ...) would otherwise pass unchecked. That one command is
blocked and the crash is logged loudly to ``logs/hook-errors.log`` and stderr
(mirroring run-hook.sh) so the matcher bug is fixable.
"""

from __future__ import annotations

import json
import re
import shlex
import sys
import traceback
from datetime import datetime, timezone
from pathlib import Path

_OPERATORS = {"&&", "||", ";", "|", "&", "\n", "(", ")"}
_SHELL_WRAPPERS = {"bash", "sh", "zsh", "dash", "ksh"}
# Launcher prefixes that delegate to the command that follows. Skipping them
# stops `command rm`, `env rm`, `sudo rm` (etc.) from hiding the real command
# behind a token the checks don't recognize.
_RM_LAUNCHERS = {
    "sudo",
    "doas",
    "command",
    "env",
    "nohup",
    "stdbuf",
    "time",
    "ionice",
    "setsid",
}
# Launchers that consume option args before the real command. `timeout 5 rm`,
# `nice -n 5 rm`, and `xargs rm` all interpose tokens (a duration, a flag's
# value, xargs options) that the plain launcher skip would mistake for the
# command. Skip the launcher, its dash-flags, and the operand each consumes.
_ARG_WRAPPERS = {"timeout", "nice", "xargs"}
# Redirection operators consume the following token (their target), which is not
# an argument of the command. Dropping the pair keeps a redirect target like
# `> /var/log/x` from being mistaken for a destructive command's operand.
_REDIRECTS = {">", ">>", "<", "<<", "<<<", "&>", ">&", "1>", "1>>", "2>", "2>>"}
_MAX_DEPTH = 5

_RE_ENV = re.compile(r"^[A-Za-z_]\w*=")
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


def _base(token: str) -> str:
    """Return the command basename (strip any leading path)."""
    return token.rsplit("/", 1)[-1]


def _expand_home_vars(token: str) -> str:
    """Rewrite home references to a canonical `~` form for matching.

    Covers `$HOME`, `${HOME}`, and `~user` (a tilde with a username, which the
    shell expands to that user's home). Bare `~` and `~/...` already match.
    """
    for var in ("${HOME}", "$HOME"):
        if token == var:
            return "~"
        if token.startswith(var + "/"):
            return "~/" + token[len(var) + 1 :]
    if token.startswith("~") and len(token) > 1 and token[1] not in "/":
        return "~"  # `~root`, `~admin`: a named user's home directory
    return token


def _normalize_leading(path: str) -> str:
    """Collapse leading `//` and resolve leading `/.` segments, string-only.

    POSIX treats exactly `//` as implementation-defined, but for *matching* a
    destructive target it is the same root as `/`, so collapse it. Interior
    `..`/`.` resolution is handled elsewhere; this only fixes the leading forms
    (`//etc`, `/./etc`) that escaped the prefix checks. No filesystem access.
    """
    if not path.startswith("/"):
        return path
    rest = path.lstrip("/")
    while rest.startswith("./") or rest == ".":
        rest = rest[2:]
    return "/" + rest


def _glob_reaches(token: str, target: str) -> bool:
    """True if `/<glob>` could expand to `target` (string-level, no FS access).

    Treats `*`/`?` as wildcards and `[...]`/`{...}` as one matching char, so
    `/us*`, `/e*`, `/[e]tc`, and `/{etc,usr}` are recognized as reaching a
    protected root without touching the filesystem.
    """
    if not any(c in token for c in "*?[{"):
        return False
    pattern = re.escape(token)
    pattern = pattern.replace(r"\*", ".*").replace(r"\?", ".")
    pattern = re.sub(r"\\\[.*?\\\]", ".", pattern)
    pattern = re.sub(r"\\\{.*?\\\}", ".*", pattern)
    return re.fullmatch(pattern, target) is not None


def _is_protected_target(token: str) -> bool:
    """True if `token` names root, a system dir, the home dir, or a child.

    Covers the bare path, root/system globs (`/*`, `/us*`, `/{etc,usr}`),
    children (`/etc/cron.d`), home variable/tilde forms (`${HOME}`, `~root`),
    and leading path-normalization forms (`//etc`, `/./etc`). The narrow
    original set (only `/`, `/Users`, `~`) let all of these through.
    """
    token = _normalize_leading(_expand_home_vars(token))
    if token in ("/", "/*", "/Users", "~", "$HOME"):
        return True
    if token.startswith(("/Users/", "~/", "$HOME/")):
        return True
    protected_roots = ("/",) + _PROTECTED_SYSTEM_DIRS
    if any(_glob_reaches(token, root) for root in protected_roots):
        return True
    return any(
        token == d or token == d + "/*" or token.startswith(d + "/")
        for d in _PROTECTED_SYSTEM_DIRS
    )


def _strip_redirects(tokens: list[str]) -> list[str]:
    """Drop redirection operators and the target token each one consumes."""
    out: list[str] = []
    skip_next = False
    for token in tokens:
        if skip_next:
            skip_next = False
            continue
        if token in _REDIRECTS:
            skip_next = True
            continue
        out.append(token)
    return out


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


def _rm_invocation(seg: list[str]) -> int:
    """Index of the `rm` command in `seg`, or -1 if the segment isn't an `rm`.

    Skips leading launcher prefixes (`sudo`, `command`, `env`, ...) and
    `VAR=value` assignments, and matches on the command *basename* so
    `/bin/rm`, `command rm`, and `env rm` are recognized -- the literal `rm`
    match let every one of those forms through.
    """
    i = 0
    while i < len(seg):
        token = seg[i]
        if token in _RM_LAUNCHERS or _RE_ENV.match(token):
            i += 1
        elif _base(token) in _ARG_WRAPPERS:
            i = _skip_wrapper_args(seg, i + 1)
        else:
            break
    if i < len(seg) and _base(seg[i]) == "rm":
        return i
    return -1


def _skip_wrapper_args(seg: list[str], i: int) -> int:
    """Advance past an arg-consuming wrapper's options to the wrapped command.

    Skips leading dash-flags (and the operand a value-taking flag like
    `nice -n 5` consumes) plus a single bare positional (`timeout`'s duration),
    stopping at the first token that looks like the real command.
    """
    while i < len(seg) and seg[i].startswith("-"):
        flag = seg[i]
        i += 1
        if flag in ("-n", "--adjustment") and i < len(seg):
            i += 1  # the numeric value `nice -n 5` consumes
    if i < len(seg) and _base(seg[i]) not in _RM_LAUNCHERS and _is_duration(seg[i]):
        i += 1  # `timeout 5 rm`: the leading duration positional
    return i


def _is_duration(token: str) -> bool:
    """True for a `timeout` duration like `5`, `1.5`, or `30s`/`5m`/`2h`."""
    return re.fullmatch(r"\d+(?:\.\d+)?[smhd]?", token) is not None


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
    """True for an octal mode granting rwx to all (`777`, `0777`, `1777`, ...).

    Also unwraps a mode fused into a flag token -- `chmod -R=777` and the
    `-Rf777` short bundle carry the mode inside the dash token, which the bare
    octal check never saw.
    """
    if token.startswith("-"):
        match = re.search(r"=?([0-7]+)$", token)
        token = match.group(1) if match else ""
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


def _tokenize(cmd: str) -> list[str]:
    """Tokenize a command, splitting unspaced operators (`true;mkfs ...`).

    `shlex.split` only separates operators that are surrounded by whitespace, so
    `true;mkfs.ext4 /dev/sda` parsed as a single `true;mkfs.ext4` token and
    every check was skipped. `punctuation_chars=True` makes shlex emit `;`, `&`,
    `|`, `(`, `)` as their own tokens regardless of spacing. `commenters=""`
    mirrors `shlex.split` so a `#` mid-command is not treated as a comment.
    """
    lex = shlex.shlex(cmd, posix=True, punctuation_chars=True)
    lex.whitespace_split = True
    lex.commenters = ""
    return list(lex)


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
            # `-c <cmd>`, or a combined short-flag bundle ending in `c`
            # (`bash -lc '...'`, `-ec`, `-xc`, `-ic`), carries the command
            # string in the next token. Matching only `-c` let those wrappers
            # smuggle a payload past every check.
            is_dash_c = token == "-c" or (
                len(token) > 1
                and token[0] == "-"
                and token[1] != "-"
                and token.endswith("c")
            )
            if is_dash_c and i + 1 < len(seg):
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


def _log_scan_error(exc: BaseException) -> None:
    """Record a scan crash to a durable log and stderr; the caller fails closed."""
    try:
        print(
            f"WARNING: safety-block.py scan crashed ({exc!r}); the "
            "destructive-command guard could not run. File a bug or run "
            "scripts/doctor.sh.",
            file=sys.stderr,
        )
    except OSError:
        pass  # a dead stderr must never change the fail-closed verdict
    try:
        log_dir = Path.home() / ".claude" / "logs"
        log_dir.mkdir(parents=True, exist_ok=True)
        stamp = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        with (log_dir / "hook-errors.log").open("a", encoding="utf-8") as fh:
            fh.write(f"{stamp} safety-block.py scan-error: {exc!r}\n")
            fh.write(
                "".join(traceback.format_exception(type(exc), exc, exc.__traceback__))
            )
    except OSError as log_exc:
        try:
            print(
                "WARNING: safety-block.py could not write hook-errors.log "
                f"({log_exc!r}); the scan-crash audit trail was lost.",
                file=sys.stderr,
            )
        except OSError:
            pass


def main() -> int:
    try:
        data = json.load(sys.stdin)
    except (json.JSONDecodeError, UnicodeDecodeError):
        return 0  # malformed input: nothing to scan, fail open quietly
    cmd = (
        data.get("tool_input", {}).get("command", "") if isinstance(data, dict) else ""
    )
    if not isinstance(cmd, str) or not cmd:
        return 0
    try:
        reason = scan(cmd)
    except Exception as exc:  # noqa: BLE001 -- fail closed + loud, see _log_scan_error
        _log_scan_error(exc)
        try:
            print(
                "BLOCKED: safety-block.py could not verify this command "
                "(scan crashed). Refusing out of caution -- rerun, or bypass "
                "explicitly if you trust it.",
                file=sys.stderr,
            )
        except OSError:
            pass  # block regardless of whether the message reached the user
        return 2
    if reason:
        print(f"BLOCKED: {reason}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
