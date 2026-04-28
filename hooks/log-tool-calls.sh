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

# Issue #6: silently no-op if python3 is unavailable. Logging must NEVER
# break a tool call, and PreToolUse exit-code semantics for 127 are
# unspecified — bail out cleanly instead of relying on `exec` failure.
command -v python3 >/dev/null 2>&1 || exit 0

exec python3 "${SCRIPT_DIR}/lib/log_tool_call.py" "${1:-pre}"
