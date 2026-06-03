#!/usr/bin/env python3
"""Redact secret patterns from JSON values.

Reads a JSON value from stdin, walks it recursively, replaces secret-like
substrings inside any string with REDACTED markers, and writes the
modified JSON to stdout.

Redaction has two layers (both defined in `_log_core.py`):

  1. Flat-string patterns (`_PATTERNS`) run on every string leaf: JWT, PEM
     private-key blocks, AWS access/STS keys, GitHub tokens + fine-grained
     PATs, Slack tokens, Anthropic keys, OpenAI keys (legacy + proj/svcacct/
     admin), URL-userinfo passwords, compound env vars, generic key=value and
     --flag=value secrets, and Authorization/Bearer headers.
  2. Key-aware redaction (`_SECRET_KEY_RE`): any dict value under a key naming
     a secret (password, token, api_key, authorization, ...) is replaced with
     `***` regardless of the value's shape -- structured payloads carry the
     secret in the value, not in `key=value` text.

`_log_core._PATTERNS` and `_SECRET_KEY_RE` are the source of truth; this list
is a summary. Usage: python3 redact.py < input.json > output.json
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
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
