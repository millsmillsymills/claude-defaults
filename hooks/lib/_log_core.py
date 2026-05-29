#!/usr/bin/env python3
"""Shared redaction patterns + JSONL helpers for claude-defaults logging.

This is the canonical home for:

  - `_PATTERNS`          : compiled secret-redaction regex pairs
  - `redact_string(s)`   : run the patterns against a single string
  - `redact_value(v)`    : recursively redact strings inside JSON values
  - `truncate_output(obj, max_bytes)`
                         : trim `output.stdout`/`output.stderr` so the
                           serialized line fits within `max_bytes`
  - `atomic_append(path, obj)`
                         : single-syscall O_APPEND write of a JSONL line
  - `DEFAULT_MAX_LINE`   : 1 MB per-line cap

The three CLI/library callers in this directory all import from here so
patterns and truncation logic exist in exactly one place:

  - `redact.py`          : thin CLI wrapper around `redact_value`
  - `jsonl_write.py`     : thin CLI wrapper around `truncate_output` +
                           `atomic_append`
  - `log_tool_call.py`   : consolidated PreToolUse + PostToolUse logger;
                           imports rather than spawning a subprocess to
                           preserve the single-fork performance win

Compatible with Python 3.9+ (relies on PEP 563 deferred annotations).
"""
from __future__ import annotations

import json
import os
import re

# ---------------------------------------------------------------------------
# Redaction patterns
# ---------------------------------------------------------------------------
# Compiled patterns (bounded to avoid catastrophic backtracking).
# Order matters: more-specific patterns run first so generic key=value
# fallbacks don't clobber a structured replacement (e.g. AKIA... is matched
# as an AWS key, not as a `key=value` pair).
_PATTERNS: list[tuple[re.Pattern[str], str]] = [
    # JWT (three base64url segments separated by dots, first two start with eyJ)
    (re.compile(r"eyJ[A-Za-z0-9_\-]{4,}\.eyJ[A-Za-z0-9_\-]{4,}\.[A-Za-z0-9_\-]{4,}"),
     "***JWT***"),
    # PEM private key blocks (any key type). Non-greedy between fixed anchors,
    # DOTALL so it spans the newline-delimited body -- no backtracking risk.
    (re.compile(
        r"-----BEGIN [A-Z ]*PRIVATE KEY-----.*?-----END [A-Z ]*PRIVATE KEY-----",
        re.DOTALL,
    ), "***PRIVATE_KEY***"),
    # AWS access key
    (re.compile(r"\bAKIA[0-9A-Z]{16}\b"), "***AWS_KEY***"),
    # AWS STS temporary credential keys (separate prefix from AKIA)
    (re.compile(r"\bASIA[0-9A-Z]{16}\b"), "***AWS_STS_KEY***"),
    # GitHub tokens (ghp_, gho_, ghs_, ghu_)
    (re.compile(r"\bgh[opsu]_[A-Za-z0-9]{36,}\b"), "***GH_TOKEN***"),
    # GitHub fine-grained PATs (different prefix than gh[opsu]_)
    (re.compile(r"\bgithub_pat_[A-Za-z0-9_]{30,}\b"), "***GH_PAT***"),
    # Slack tokens (bot/user/workspace/refresh/admin/legacy-refresh:
    # xoxb-, xoxp-, xoxa-, xoxr-, xoxs-, xoxe-)
    (re.compile(r"\bxox[baprse]-[A-Za-z0-9-]{10,}\b"), "***SLACK_TOKEN***"),
    # Slack app-level tokens (xapp-1-...)
    (re.compile(r"\bxapp-1-[A-Za-z0-9-]{10,}\b"), "***SLACK_APP_TOKEN***"),
    # Stripe secret keys (sk_live_/sk_test_; underscore form, distinct from sk-)
    (re.compile(r"\bsk_(?:live|test)_[A-Za-z0-9]{16,}\b"), "***STRIPE_KEY***"),
    # Twilio API key SID (SK + 32 hex)
    (re.compile(r"\bSK[a-f0-9]{32}\b"), "***TWILIO_KEY***"),
    # Twilio Account SID (AC + 32 hex)
    (re.compile(r"\bAC[a-f0-9]{32}\b"), "***TWILIO_SID***"),
    # SendGrid API keys (SG.<22>.<43>)
    (re.compile(r"\bSG\.[A-Za-z0-9_\-]{22}\.[A-Za-z0-9_\-]{43}\b"),
     "***SENDGRID_KEY***"),
    # Anthropic API keys
    (re.compile(r"\bsk-ant-[A-Za-z0-9_\-]{8,}\b"), "***ANTHROPIC_KEY***"),
    # OpenAI keys -- legacy (sk-...) and modern project/service/admin keys
    # (sk-proj-, sk-svcacct-, sk-admin-) which contain - and _ and run long.
    # Runs after the Anthropic pattern so sk-ant- keys keep their own marker.
    (re.compile(r"\bsk-(?:proj-|svcacct-|admin-)?[A-Za-z0-9_\-]{20,}\b"),
     "***OPENAI_KEY***"),
    # URL userinfo passwords: postgresql://user:password@host/db -- redact any
    # non-empty password between : and @ while preserving the user and host.
    (re.compile(r"(://[^:@\s/]+):([^@\s]{1,})@"), r"\1:***@"),
    # Compound env vars: DB_PASSWORD=, app_secret_key=, AWS_SECRET_ACCESS_KEY=.
    # A plain \b-anchored pattern misses these because _ is a word character
    # (no boundary before "PASSWORD"). Require `_` before the suffix word to
    # avoid matches inside ordinary words (MONKEY, BUCKET, TICKET would hit
    # "KEY"/"TOKEN"). Case-insensitive so lowercase/mixed-case names match too.
    (re.compile(
        r"([A-Za-z][A-Za-z0-9]*(?:_[A-Za-z0-9]+)*"
        r"_(?:PASSWORD|PASSWD|SECRET|TOKEN|KEY|PAT|CREDENTIAL|CREDENTIALS|AUTH|URL))"
        r"(\s*=\s*)([^\s,;'\"]{1,})",
        re.IGNORECASE,
    ), r"\1\2***"),
    # key=value secrets where value is a single shell/URL token (no internal
    # whitespace). No minimum value length -- a named secret of any size leaks.
    (re.compile(
        r"(?i)\b(password|passwd|secret|token|api[_-]?key)"
        r"(\s*[:=]\s*)([^\s,;'\"]{1,})"
    ), r"\1\2***"),
    # Header-style: Authorization: <scheme> <credential...>; Bearer <token>
    # Value class allows internal spaces; stops at line/quote/comma/semicolon.
    # Separator may be ':', '=', or whitespace alone (e.g. `Bearer abc`).
    # Value class excludes '*' so we don't re-match earlier-redacted markers
    # (e.g. preserve `Bearer ***JWT***` -> `Bearer ***`).
    (re.compile(
        r"(?i)\b(authorization|bearer)"
        r"(\s*[:=]\s*|\s+)([^*,;'\"\r\n]{3,})"
    ), r"\1\2***"),
    # --flag=value CLI secrets
    (re.compile(
        r"(--(?:password|token|secret|api[_-]?key))(=)([^\s,;'\"]{3,})"
    ), r"\1\2***"),
]


def redact_string(s: str) -> str:
    """Run every redaction pattern against `s` in order.

    Patterns are tried in the order they appear in `_PATTERNS`; more-specific
    patterns (JWT, AWS, GH, etc.) run first so the generic key=value fallback
    doesn't clobber a structured replacement. Returns the redacted string;
    leaves non-matching content untouched.
    """
    for pattern, replacement in _PATTERNS:
        s = pattern.sub(replacement, s)
    return s


# Dict keys whose value is a secret regardless of the value's shape. The flat
# string patterns above only fire on `key=value` text; structured payloads
# (MCP args, env maps, config objects) carry the secret as a bare JSON value
# under a sensitive key, so the key itself is the signal.
#
# The key must END with a secret word (matched with `.fullmatch`). The end
# anchor is what protects analytics telemetry -- `csrf_token_count`,
# `bearer_count`, `last_authorization_at` end in a non-secret word, so they do
# not match. The prefix is permissive (`.*`, any separator or camelCase hump)
# so camelCase keys are caught too: `secretAccessKey`, `accessToken`,
# `refreshToken`, `clientSecret`, `sessionToken`, `bearerToken`, `authToken`.
_SECRET_KEY_RE = re.compile(
    r"(?i)^.*(?:password|passwd|secret|token|api[_-]?key|access[_-]?key"
    r"|private[_-]?key|secret[_-]?key|authorization|bearer|credentials?)$"
)


def redact_value(v: object) -> object:
    """Recursively walk a JSON-decoded value, redacting strings and secret keys.

    Walks dicts, lists, and strings; passes through other JSON scalar types
    (int, float, bool, None) unchanged. When a dict key names a secret
    (`password`, `api_key`, `authorization`, ...), its entire value is replaced
    with `***` regardless of shape -- structured payloads put the secret in the
    value, not in `key=value` text. Returns a new structure; input is not
    mutated.
    """
    if isinstance(v, str):
        return redact_string(v)
    if isinstance(v, list):
        return [redact_value(x) for x in v]
    if isinstance(v, dict):
        return {
            k: "***" if isinstance(k, str) and _SECRET_KEY_RE.fullmatch(k)
            else redact_value(val)
            for k, val in v.items()
        }
    return v


# ---------------------------------------------------------------------------
# JSONL write helpers
# ---------------------------------------------------------------------------
DEFAULT_MAX_LINE = 1024 * 1024  # 1 MB


def truncate_output(obj: dict, max_bytes: int) -> dict:
    """If serialized JSON would exceed `max_bytes`, trim output.{stdout,stderr}.

    Mutates and returns `obj` for convenience. Records the number of dropped
    bytes in `output._truncated_bytes` when anything was dropped. When the
    non-trimmable envelope (call_id, ts, args, ...) alone exceeds `max_bytes`,
    stdout/stderr are dropped entirely and `output._truncated_oversize` is set
    true: the line is still emitted over the cap, because nothing left here is
    trimmable. The marker therefore never implies a cap that wasn't met.
    """
    serialized = json.dumps(obj, ensure_ascii=False)
    overhead = len((serialized + "\n").encode("utf-8")) - max_bytes
    if overhead <= 0:
        return obj

    output = obj.get("output")
    if not isinstance(output, dict):
        # Nothing structured to trim; leave as-is.
        return obj

    truncated_total = 0
    for key in ("stdout", "stderr"):
        v = output.get(key)
        if not isinstance(v, str):
            continue
        encoded = v.encode("utf-8")
        if len(encoded) <= 256:
            continue
        # Reserve ~256 bytes of context, drop the middle.
        keep = max(256, len(encoded) - max(0, overhead - truncated_total))
        if keep < len(encoded):
            output[key] = encoded[:keep].decode("utf-8", errors="replace")
            truncated_total += len(encoded) - keep
        # Re-check size.
        serialized = json.dumps(obj, ensure_ascii=False)
        if len((serialized + "\n").encode("utf-8")) <= max_bytes:
            break

    if truncated_total > 0:
        output["_truncated_bytes"] = truncated_total

    # The per-field loop respects a 256-byte floor and skips fields already at
    # or under it, so a payload whose envelope plus two short fields still
    # exceeds max_bytes would otherwise be written oversize. Hard-truncate
    # below the floor (stdout first, since it is usually larger). The 64-byte
    # margin leaves room for the marker.
    for key in ("stdout", "stderr"):
        serialized = json.dumps(obj, ensure_ascii=False)
        overhead = len((serialized + "\n").encode("utf-8")) - max_bytes
        if overhead <= 0:
            break
        v = output.get(key)
        if not isinstance(v, str):
            continue
        encoded = v.encode("utf-8")
        keep = max(0, len(encoded) - overhead - 64)
        if keep >= len(encoded):
            continue
        output[key] = encoded[:keep].decode("utf-8", errors="replace")
        output["_truncated_bytes"] = output.get("_truncated_bytes", 0) + (len(encoded) - keep)

    # If even empty stdout/stderr cannot bring the line under max_bytes, the
    # envelope alone exceeds the cap. Flag it honestly rather than letting
    # _truncated_bytes imply the per-line cap was met.
    serialized = json.dumps(obj, ensure_ascii=False)
    if len((serialized + "\n").encode("utf-8")) > max_bytes:
        output["_truncated_oversize"] = True

    return obj


def atomic_append(path: str, obj: dict) -> None:
    """Append a JSON object as one line via a single O_APPEND syscall.

    Atomic on macOS APFS for the line sizes we produce (≤ 1 MB).
    Caller is responsible for catching ENOSPC if it wants to silently
    drop on disk-full.
    """
    line = (json.dumps(obj, ensure_ascii=False) + "\n").encode("utf-8")
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    fd = os.open(path, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o644)
    try:
        os.write(fd, line)
    finally:
        os.close(fd)
