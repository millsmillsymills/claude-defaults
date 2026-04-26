#!/usr/bin/env python3
"""Redact secret patterns from JSON values.

Reads a JSON value from stdin, walks it recursively, replaces secret-like
substrings inside any string with REDACTED markers, and writes the
modified JSON to stdout.

Patterns covered:
  - JWT tokens (eyJ...eyJ...sig)
  - AWS access keys (AKIA + 16 chars)
  - GitHub personal/OAuth/server/user tokens (gh[opsu]_...)
  - Anthropic API keys (sk-ant-...)
  - OpenAI API keys (sk-... 48 chars)
  - key=value with key in {password, passwd, secret, token, api_key, api-key,
    bearer, authorization}
  - --flag=value with flag in {password, token, secret, api-key, api_key}

Usage: python3 redact.py < input.json > output.json
"""
import json
import re
import sys

# Compiled patterns (bounded to avoid catastrophic backtracking).
_PATTERNS: list[tuple[re.Pattern[str], str]] = [
    # JWT (three base64url segments separated by dots, first two start with eyJ)
    (re.compile(r"eyJ[A-Za-z0-9_\-]{4,}\.eyJ[A-Za-z0-9_\-]{4,}\.[A-Za-z0-9_\-]{4,}"),
     "***JWT***"),
    # AWS access key
    (re.compile(r"\bAKIA[0-9A-Z]{16}\b"), "***AWS_KEY***"),
    # GitHub tokens (ghp_, gho_, ghs_, ghu_)
    (re.compile(r"\bgh[opsu]_[A-Za-z0-9]{36,}\b"), "***GH_TOKEN***"),
    # Anthropic API keys
    (re.compile(r"\bsk-ant-[A-Za-z0-9_\-]{8,}\b"), "***ANTHROPIC_KEY***"),
    # OpenAI keys (sk- followed by 40+ base62 chars; bounded)
    (re.compile(r"\bsk-[A-Za-z0-9]{40,80}\b"), "***OPENAI_KEY***"),
    # key=value secrets (case-insensitive key)
    (re.compile(
        r"(?i)\b(password|passwd|secret|token|api[_-]?key|bearer|authorization)"
        r"(\s*[:=]\s*)([^\s,;'\"]{3,})"
    ), r"\1\2***"),
    # --flag=value CLI secrets
    (re.compile(
        r"(--(?:password|token|secret|api[_-]?key))(=)([^\s,;'\"]{3,})"
    ), r"\1\2***"),
]


def redact_string(s: str) -> str:
    for pattern, replacement in _PATTERNS:
        s = pattern.sub(replacement, s)
    return s


def redact_value(v):
    if isinstance(v, str):
        return redact_string(v)
    if isinstance(v, list):
        return [redact_value(x) for x in v]
    if isinstance(v, dict):
        return {k: redact_value(val) for k, val in v.items()}
    return v


def main() -> int:
    try:
        data = json.load(sys.stdin)
    except json.JSONDecodeError as exc:
        print(f"redact: input is not valid JSON: {exc}", file=sys.stderr)
        return 1
    redacted = redact_value(data)
    json.dump(redacted, sys.stdout)
    return 0


if __name__ == "__main__":
    sys.exit(main())
