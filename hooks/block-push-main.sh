#!/usr/bin/env bash
set -euo pipefail

# PreToolUse hook: blocks direct push to main/master, requires feature branches.
# Wire up in settings.json PreToolUse -> Bash matcher.
#
# Exit codes:
#   0 = allow
#   2 = block (error message fed back to Claude)

CMD=$(jq -r '.tool_input.command')

if echo "$CMD" | grep -qE 'git[[:space:]]+push[[:space:]]+[a-zA-Z_-]+[[:space:]]+(main|master)([[:space:]]|$)'; then
    echo 'BLOCKED: Use feature branches, not direct push to main' >&2
    exit 2
fi
