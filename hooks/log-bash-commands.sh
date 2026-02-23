#!/usr/bin/env bash
set -euo pipefail

# PostToolUse hook: appends every Bash command the agent runs to a log file
# with a timestamp. Useful for post-session review of what the agent did.
#
# Usage in settings.json:
#   "PostToolUse": [{
#     "matcher": "Bash",
#     "hooks": [{"type": "command", "command": "hooks/log-bash-commands.sh"}]
#   }]

LOG_FILE="${CLAUDE_BASH_LOG:-$HOME/.claude/bash-commands.log}"
mkdir -p "$(dirname "$LOG_FILE")"

jq -r '"[" + (now | todate) + "] " + .tool_input.command' >> "$LOG_FILE"
