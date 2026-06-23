#!/usr/bin/env python3
"""Shared command tokenization for the PreToolUse(Bash) guard hooks.

`safety-block.py`, `block-rm-rf.py`, and `block-push-main.py` all need to break
a shell command into the individual commands it runs -- including any tucked
inside `bash -c '...'`, `sh -c '...'`, or `eval '...'` -- before they can decide
whether to block it. That parsing lives here, in one place, so the three guards
agree on what a command *is*. The previous shell guards stripped quoted strings
with `sed` and split on spaced operators only, which let `bash -c '...'` and
unspaced separators (`true;rm ...`) slip past; this module fixes both classes.

Compatible with Python 3.9+ (relies on PEP 563 deferred annotations).
"""

from __future__ import annotations

import re
import shlex


class DepthLimitExceeded(Exception):
    """Wrapper nesting ran past the recursion bound, so the inner command was
    never scanned. Raised (not silently swallowed) so a guard fails closed."""


# Operators that terminate one command segment and begin the next. `(`/`)` are
# included so a subshell's contents are judged as their own segment.
_OPERATORS = {"&&", "||", ";", "|", "&", "\n", "(", ")"}
# The individual characters those operators are built from. shlex groups a run
# of adjacent punctuation into one token, so a newline next to another operator
# arrives as `|\n`, `&&\n`, or `\n\n`; a token made up only of these chars is a
# separator even when it isn't a member of `_OPERATORS` verbatim.
_SEPARATOR_CHARS = frozenset("&|;\n()")
_SHELL_WRAPPERS = {"bash", "sh", "zsh", "dash", "ksh"}
# Redirection operators consume the following token (their target), which is not
# an argument of the command. Dropping the pair keeps a redirect target like
# `> /var/log/x` from being mistaken for a command operand.
_REDIRECTS = {">", ">>", "<", "<<", "<<<", "&>", ">&", "1>", "1>>", "2>", "2>>"}
_MAX_DEPTH = 5

# Launcher prefixes that delegate to the command that follows. Skipping them
# stops `command rm`, `env git`, `sudo rm` (etc.) from hiding the real command
# behind a token the checks don't recognize.
LAUNCHERS = {
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
# Launchers that carry their own arguments before the wrapped command, so the
# bare-skip used for `sudo`/`command` would stop at the launcher's own option or
# duration and miss the real command (`timeout 5 rm ...`, `nice -n 5 rm ...`).
_ARG_LAUNCHERS = {"timeout", "nice", "xargs"}
# Option flags of an arg-launcher that consume the *following* token as their
# value (the `--flag=value` form carries its own value, so no lookahead).
_LAUNCHER_VALUE_FLAGS = {
    "timeout": {"-k", "--kill-after", "-s", "--signal"},
    "nice": {"-n", "--adjustment"},
    "xargs": {
        "-n",
        "-I",
        "-i",
        "-P",
        "-d",
        "-E",
        "-s",
        "-L",
        "-a",
        "--max-args",
        "--replace",
        "--max-procs",
        "--delimiter",
        "--max-lines",
        "--arg-file",
        "--eof",
    },
}
# Arg-launchers that take a bare positional (not a flag) before the command --
# `timeout`'s DURATION. Consumed after the option flags, but only when it looks
# like a duration: `timeout rm -rf /etc` (no duration) must not skip `rm` as if
# it were the DURATION, or the wrapped command goes unchecked.
_LAUNCHER_POSITIONALS = {"timeout": 1}
_RE_DURATION = re.compile(r"^[0-9]+(\.[0-9]+)?[smhd]?$")
# A brace group runs its body in the current shell, so `{ rm -rf /etc; }` hides
# the real command behind a `{` token. The braces are skipped like a launcher.
_BRACE_GROUP = {"{", "}"}
_RE_ENV = re.compile(r"^[A-Za-z_]\w*=")


def base(token: str) -> str:
    """Return the command basename (strip any leading path)."""
    return token.rsplit("/", 1)[-1]


def _skip_launcher_args(seg: list[str], i: int, launcher: str) -> int:
    """Index of the wrapped command after an arg-launcher's own arguments.

    Consumes the launcher's option flags (and the value of any flag that takes
    one as a separate token) plus any required bare positional, so the command
    the launcher runs (`timeout 5 rm ...`, `nice -n 5 rm ...`) is reached.
    """
    n = len(seg)
    value_flags = _LAUNCHER_VALUE_FLAGS.get(launcher, set())
    while i < n and seg[i].startswith("-"):
        flag = seg[i]
        i += 1
        if "=" not in flag and flag in value_flags and i < n:
            i += 1
    for _ in range(_LAUNCHER_POSITIONALS.get(launcher, 0)):
        if i < n and not seg[i].startswith("-") and _RE_DURATION.match(seg[i]):
            i += 1
    return i


def command_start(seg: list[str]) -> int:
    """Index of the real command in `seg` after skipping every prefix.

    Skips leading launcher prefixes (`sudo`, `doas`, `command`, `env`, ...),
    `VAR=value` assignments, brace-group tokens (`{`/`}`), and arg-launchers with
    their own arguments (`timeout 5`, `nice -n 5`, `xargs`). The returned index
    may be `len(seg)` when the segment is only prefixes (`}` on its own).
    """
    i = 0
    n = len(seg)
    while i < n:
        token = seg[i]
        token_base = base(token)
        if _RE_ENV.match(token) or token in _BRACE_GROUP or token_base in LAUNCHERS:
            i += 1
            continue
        if token_base in _ARG_LAUNCHERS:
            i = _skip_launcher_args(seg, i + 1, token_base)
            continue
        break
    return i


def command_index(seg: list[str], name: str) -> int:
    """Index of command `name` in `seg`, or -1 if `seg` isn't that command.

    Matches on the command *basename* after skipping prefixes, so `/bin/rm`,
    `command rm`, `env git`, and `{ rm ...` are recognized -- a literal match on
    `seg[0]` let every one of those forms through.
    """
    i = command_start(seg)
    if i < len(seg) and base(seg[i]) == name:
        return i
    return -1


def rm_invocation(seg: list[str]) -> int:
    """Index of the `rm` command in `seg`, or -1 if the segment isn't an `rm`."""
    return command_index(seg, "rm")


def has_recursive_force(flags: list[str]) -> bool:
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


def strip_redirects(tokens: list[str]) -> list[str]:
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


def tokenize(cmd: str) -> list[str]:
    """Tokenize a command, splitting unspaced operators (`true;mkfs ...`).

    `shlex.split` only separates operators surrounded by whitespace, so
    `true;cmd /dev/sda` parsed as one `true;cmd` token and the command after the
    separator was never examined. `punctuation_chars=True` makes shlex emit `;`,
    `&`, `|`, `(`, `)` as their own tokens regardless of spacing. `commenters=""`
    mirrors `shlex.split` so a `#` mid-command is not treated as a comment.

    Newline is added to the punctuation set and removed from the whitespace set
    so a command split only by a newline (`echo hi\nrm -rf /etc`) is parsed as
    two segments. shlex's default whitespace swallows `\n`, which let any
    command on a later line slip past every check unexamined.
    Raises `ValueError` on unbalanced quotes (the caller falls back).
    """
    lex = shlex.shlex(cmd, posix=True, punctuation_chars="();<>|&\n")
    lex.whitespace_split = True
    lex.commenters = ""
    lex.whitespace = lex.whitespace.replace("\n", "")
    return list(lex)


def segments(tokens: list[str]):
    """Split a token list into command segments on shell operators."""
    seg: list[str] = []
    for token in tokens:
        if token in _OPERATORS or set(token) <= _SEPARATOR_CHARS:
            if seg:
                yield seg
                seg = []
        else:
            seg.append(token)
    if seg:
        yield seg


def _carries_command_string(token: str) -> bool:
    """True if `token` makes a shell wrapper read its command from the *next*
    token: a bare `-c`, or a combined short-flag bundle ending in `c`
    (`-lc`, `-ec`, `-xc`, `-ic`).

    This predicate is security-relevant and shared by both the balanced
    (`nested_payloads`) and the unbalanced-quote fallback (`fallback_payload`)
    paths, so the two cannot drift: a form one path unwraps but the other misses
    is exactly where a wrapped payload becomes a bypass. A `--long` option never
    qualifies (`token[1] != "-"`).
    """
    return token == "-c" or (
        len(token) > 1 and token[0] == "-" and token[1] != "-" and token.endswith("c")
    )


def nested_payloads(seg: list[str]):
    """Yield nested command strings carried by `bash -c`/`eval`/... in `seg`."""
    if not seg:
        return
    cmd_base = base(seg[0])
    if cmd_base in _SHELL_WRAPPERS:
        for i, token in enumerate(seg):
            if _carries_command_string(token) and i + 1 < len(seg):
                yield seg[i + 1]
                break
    elif cmd_base == "eval":
        payload = " ".join(seg[1:])
        if payload:
            yield payload


def fallback_payload(seg: list[str]) -> str:
    """The wrapped command string a de-quoted `bash -c`/`eval` segment carries.

    The fallback has already split the payload's words apart (quotes are gone),
    so the tail is rejoined into a command string the caller re-scans. Returns
    "" when the segment wraps nothing.
    """
    if not seg:
        return ""
    cmd_base = base(seg[0])
    if cmd_base in _SHELL_WRAPPERS:
        for i, token in enumerate(seg):
            if _carries_command_string(token):
                return " ".join(seg[i + 1 :])
        return ""
    if cmd_base == "eval":
        return " ".join(seg[1:])
    return ""


def _fallback_segments(cmd: str, depth: int = 0, max_depth: int = _MAX_DEPTH):
    """De-quote and split a command shlex can't parse (unbalanced quotes).

    The old approximation flat-split the string and never re-entered a
    `bash -c '...'` payload, so a wrapped destructive command with broken quoting
    slipped through; the de-quoted wrapper tail is now re-scanned too.
    """
    if depth > max_depth:
        raise DepthLimitExceeded(f"wrapper nesting exceeded {max_depth} levels")
    cleaned = cmd.replace('"', " ").replace("'", " ")
    for piece in re.split(r"&&|\|\||[;|&\n()]", cleaned):
        seg = piece.split()
        if not seg:
            continue
        yield seg
        payload = fallback_payload(seg)
        if payload:
            yield from _fallback_segments(payload, depth + 1, max_depth)


def iter_segments(cmd: str, depth: int = 0, max_depth: int = _MAX_DEPTH):
    """Yield every command segment in `cmd`, recursing into wrapped payloads.

    Each yielded value is a token list (one command invocation). Payloads
    carried by `bash -c`/`eval`/... are unwrapped and their segments yielded
    too, so a guard sees the real command regardless of wrapping. Nesting past
    `max_depth` raises `DepthLimitExceeded` -- the inner command would otherwise
    go unscanned, so the caller must fail closed rather than allow it.
    """
    if depth > max_depth:
        raise DepthLimitExceeded(f"wrapper nesting exceeded {max_depth} levels")
    try:
        tokens = tokenize(cmd)
    except ValueError:
        yield from _fallback_segments(cmd, depth, max_depth)
        return
    for seg in segments(tokens):
        yield seg
        for payload in nested_payloads(seg):
            yield from iter_segments(payload, depth + 1, max_depth)
