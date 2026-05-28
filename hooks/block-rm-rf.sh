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

# Block only when rm is invoked with BOTH recursive and force, in any flag
# arrangement: -rf, -fr, -r -f, -Rf, --recursive --force. Detecting the two
# independently (rather than one combined regex) closes the reordered/split
# bypasses; rm -r or rm -f alone is left alone, matching prior behavior.
if echo "$SCRUBBED" | grep -qE '(^|[[:space:]])rm([[:space:]]|$)' \
    && echo "$SCRUBBED" | grep -qE '(-[A-Za-z]*[rR]|--recursive)' \
    && echo "$SCRUBBED" | grep -qE '(-[A-Za-z]*f|--force)'; then
    echo 'BLOCKED: Use trash instead of rm -rf' >&2
    exit 2
fi
