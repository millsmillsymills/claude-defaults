#!/usr/bin/env bash
# Thin wrapper. All logic lives in lib/log_tool_call.py to amortize the
# python3 startup cost (one fork per call instead of ~10).
#
# Wire up in settings.json:
#   PreToolUse  -> matcher "*" -> command "$HOME/.claude/hooks/log-tool-calls.sh pre"
#   PostToolUse -> matcher "*" -> command "$HOME/.claude/hooks/log-tool-calls.sh post"
#
# Logging failures NEVER break a tool call.
set +e

# Resolve script dir through symlink chain.
SOURCE="${BASH_SOURCE[0]}"
if [ -L "$SOURCE" ]; then
    SOURCE=$(readlink "$SOURCE")
fi
SCRIPT_DIR=$(cd "$(dirname "$SOURCE")" 2>/dev/null && pwd) || SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

exec python3 "${SCRIPT_DIR}/lib/log_tool_call.py" "${1:-pre}"
