#!/usr/bin/env bash
set -euo pipefail

# PreToolUse hook: blocks rm -rf commands, suggests trash instead.
# Wire up in settings.json PreToolUse -> Bash matcher.
#
# Exit codes:
#   0 = allow
#   2 = block (error message fed back to Claude)

CMD=$(jq -r '.tool_input.command')

# Strip quoted strings before pattern matching so e.g. echo "rm -rf foo"
# (the literal pattern inside a quoted argument) doesn't trigger the block.
# Approximation, not a real shell parser: handles most common cases.
SCRUBBED=$(printf '%s' "$CMD" | sed -E 's/"[^"]*"//g' | sed -E "s/'[^']*'//g")

if echo "$SCRUBBED" | grep -qE 'rm[[:space:]]+-[^[:space:]]*r[^[:space:]]*f'; then
    echo 'BLOCKED: Use trash instead of rm -rf' >&2
    exit 2
fi
