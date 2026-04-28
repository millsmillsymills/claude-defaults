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
  - OpenAI API keys (sk-... 40-80 chars)
  - key=value with key in {password, passwd, secret, token, api_key, api-key,
    bearer, authorization}
  - --flag=value with flag in {password, token, secret, api-key, api_key}

Usage: python3 redact.py < input.json > output.json

This is the canonical CLI; the shared patterns live in `_log_core.py`.
"""
from __future__ import annotations

import json
import os
import sys

# Make sibling-module imports work when this script is invoked through a
# symlink (e.g. ~/.claude/hooks/lib/redact.py -> repo path).
sys.path.insert(0, os.path.dirname(os.path.realpath(__file__)))

from _log_core import redact_value  # noqa: E402


def main() -> int:
    try:
        data = json.load(sys.stdin)
    except json.JSONDecodeError as exc:
        print(f"redact: input is not valid JSON: {exc}", file=sys.stderr)
        return 1
    json.dump(redact_value(data), sys.stdout)
    return 0


if __name__ == "__main__":
    sys.exit(main())
