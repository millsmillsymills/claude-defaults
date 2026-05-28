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

# Remote class allows digits/dots/slashes (origin2, fork.url, a/b). The branch
# may appear as a bare ref or as the destination of a refspec (HEAD:main,
# feature:main, main:main) -- match an optional `<src>:` before main/master so
# those forms don't slip through. `main:feature` (pushing INTO feature) is left
# alone because the destination isn't main/master.
if echo "$SCRUBBED" | grep -qE 'git[[:space:]]+push[[:space:]]+[A-Za-z0-9._/-]+[[:space:]]+([A-Za-z0-9._/-]+:)?(main|master)([[:space:]]|$)'; then
    echo 'BLOCKED: Use feature branches, not direct push to main' >&2
    exit 2
fi
