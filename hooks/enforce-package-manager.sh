#!/usr/bin/env bash
set -euo pipefail

# PreToolUse hook: blocks npm commands in projects that use pnpm.
# Generalizes to any "use X not Y" convention -- swap the detection
# and blocked command patterns for your stack.
#
# Exit codes:
#   0 = allow
#   2 = block (error message fed back to Claude)

CMD=$(jq -r '.tool_input.command')

# Detect if project uses pnpm (pnpm-lock.yaml in working directory)
if [ -f "pnpm-lock.yaml" ]; then
    if echo "$CMD" | grep -qE '^npm[[:space:]]+(install|i|add|remove|uninstall|ci|run|exec)'; then
        echo "BLOCKED: This project uses pnpm. Use 'pnpm' instead of 'npm'." >&2
        exit 2
    fi
fi

# Detect if project uses yarn (yarn.lock in working directory)
if [ -f "yarn.lock" ]; then
    if echo "$CMD" | grep -qE '^npm[[:space:]]+(install|i|add|remove|uninstall|ci|run|exec)'; then
        echo "BLOCKED: This project uses yarn. Use 'yarn' instead of 'npm'." >&2
        exit 2
    fi
fi
