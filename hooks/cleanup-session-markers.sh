#!/usr/bin/env bash
# SessionEnd hook: remove this session's convention-hook markers from
# ~/.claude/state so per-session markers (pr-created-<sid>, clean-nudged-<sid>)
# have a clear owner instead of relying on the opportunistic 7-day mtime sweep
# in warn-merge-after-pr.sh / stop-check-clean-repo.sh. That sweep stays as a
# backstop for sessions that crash without a SessionEnd. Never blocks (exit 0).
set -uo pipefail

input=$(cat)
sid=$(printf '%s' "$input" | jq -r '.session_id // ""' 2>/dev/null || echo "")
[ -n "$sid" ] || exit 0
# session_id is untrusted input; sanitize before it reaches a filesystem path
# (mirrors _sanitize in hooks/lib/log_tool_call.py and the marker writers).
sid="${sid//[^A-Za-z0-9_-]/_}"

state_dir="${HOME}/.claude/state"
rm -f "${state_dir}/pr-created-${sid}" "${state_dir}/clean-nudged-${sid}" 2>/dev/null || true

exit 0
