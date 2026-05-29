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

# Match npm at a command boundary: line start, after &&/||/;/|, after a
# subshell/group opener ( or {, or after env-var assignments (NODE_ENV=prod npm
# install). Anchoring only to `^` missed those and leading whitespace; matching
# bare whitespace would false-positive on `npm` in prose (echo, commit
# messages), so we require a real boundary.
NPM_RE='(^|&&|\|\||;|\||\(|\{)[[:space:]]*([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]+[[:space:]]+)*npm[[:space:]]+(install|i|add|remove|uninstall|ci|run|exec)'

# Detect if project uses pnpm (pnpm-lock.yaml in working directory)
if [ -f "pnpm-lock.yaml" ]; then
    if echo "$CMD" | grep -qE "$NPM_RE"; then
        echo "BLOCKED: This project uses pnpm. Use 'pnpm' instead of 'npm'." >&2
        exit 2
    fi
fi

# Detect if project uses yarn (yarn.lock in working directory)
if [ -f "yarn.lock" ]; then
    if echo "$CMD" | grep -qE "$NPM_RE"; then
        echo "BLOCKED: This project uses yarn. Use 'yarn' instead of 'npm'." >&2
        exit 2
    fi
fi
