#!/usr/bin/env bash
set -euo pipefail

# PreToolUse hook: blocks direct push to main/master, requires feature branches.
# Wire up in settings.json PreToolUse -> Bash matcher.
#
# Exit codes:
#   0 = allow
#   2 = block (error message fed back to Claude)

CMD=$(jq -r '.tool_input.command')

# Strip quoted strings before pattern matching (see block-rm-rf.sh for rationale).
SCRUBBED=$(printf '%s' "$CMD" | sed -E 's/"[^"]*"//g' | sed -E "s/'[^']*'//g")

if echo "$SCRUBBED" | grep -qE 'git[[:space:]]+push[[:space:]]+[a-zA-Z_-]+[[:space:]]+(main|master)([[:space:]]|$)'; then
    echo 'BLOCKED: Use feature branches, not direct push to main' >&2
    exit 2
fi
