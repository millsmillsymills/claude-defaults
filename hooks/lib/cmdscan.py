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

# Operators that terminate one command segment and begin the next. `(`/`)` are
# included so a subshell's contents are judged as their own segment.
_OPERATORS = {"&&", "||", ";", "|", "&", "\n", "(", ")"}
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
    "command",
    "env",
    "nohup",
    "nice",
    "stdbuf",
    "time",
    "ionice",
    "setsid",
}
_RE_ENV = re.compile(r"^[A-Za-z_]\w*=")


def base(token: str) -> str:
    """Return the command basename (strip any leading path)."""
    return token.rsplit("/", 1)[-1]


def command_index(seg: list[str], name: str) -> int:
    """Index of command `name` in `seg`, or -1 if `seg` isn't that command.

    Skips leading launcher prefixes (`sudo`, `command`, `env`, ...) and
    `VAR=value` assignments, and matches on the command *basename* so
    `/bin/rm`, `command rm`, and `env git` are recognized -- a literal match
    let every one of those forms through.
    """
    i = 0
    while i < len(seg) and (seg[i] in LAUNCHERS or _RE_ENV.match(seg[i])):
        i += 1
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
    Raises `ValueError` on unbalanced quotes (the caller falls back).
    """
    lex = shlex.shlex(cmd, posix=True, punctuation_chars=True)
    lex.whitespace_split = True
    lex.commenters = ""
    return list(lex)


def segments(tokens: list[str]):
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


def nested_payloads(seg: list[str]):
    """Yield nested command strings carried by `bash -c`/`eval`/... in `seg`."""
    if not seg:
        return
    cmd_base = base(seg[0])
    if cmd_base in _SHELL_WRAPPERS:
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
    elif cmd_base == "eval":
        payload = " ".join(seg[1:])
        if payload:
            yield payload


def _fallback_segments(cmd: str):
    """De-quote and split a command shlex can't parse (unbalanced quotes).

    Reintroduces the old quote-strip approximation only for the rare malformed
    case, so a dangerous command with broken quoting is still segmented.
    """
    cleaned = cmd.replace('"', " ").replace("'", " ")
    for piece in re.split(r"&&|\|\||[;|&\n()]", cleaned):
        seg = piece.split()
        if seg:
            yield seg


def iter_segments(cmd: str, depth: int = 0, max_depth: int = _MAX_DEPTH):
    """Yield every command segment in `cmd`, recursing into wrapped payloads.

    Each yielded value is a token list (one command invocation). Payloads
    carried by `bash -c`/`eval`/... are unwrapped and their segments yielded
    too, so a guard sees the real command regardless of wrapping.
    """
    if depth > max_depth:
        return
    try:
        tokens = tokenize(cmd)
    except ValueError:
        yield from _fallback_segments(cmd)
        return
    for seg in segments(tokens):
        yield seg
        for payload in nested_payloads(seg):
            yield from iter_segments(payload, depth + 1, max_depth)
