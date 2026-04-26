#!/usr/bin/env bash
# PreToolUse + PostToolUse hook: append a redacted JSON line per tool call.
#
# Wire up in settings.json:
#   PreToolUse  -> matcher "*" -> command "$HOME/.claude/hooks/log-tool-calls.sh pre"
#   PostToolUse -> matcher "*" -> command "$HOME/.claude/hooks/log-tool-calls.sh post"
#
# Reads Claude Code hook stdin JSON, extracts metadata, redacts secrets via
# lib/redact.py, and atomic-appends one JSONL line via lib/jsonl-write.py.
#
# Pre call writes start time to ${TMPDIR}/claude-tool-${call_id}; post call
# reads it for duration_ms and deletes the temp file.
#
# Logging failures NEVER break a tool call -- everything is wrapped to exit 0.

set -uo pipefail

EVENT="${1:-pre}"
[ "$EVENT" = "pre" ] || [ "$EVENT" = "post" ] || EVENT="pre"

# Resolve our own location through symlink chain.
SCRIPT_DIR=$(cd "$(dirname "$(readlink "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")")" 2>/dev/null && pwd) || \
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="${SCRIPT_DIR}/lib"

# Read stdin once, reuse.
INPUT=$(cat)

LOG_DIR="${HOME}/.claude/logs"
mkdir -p "$LOG_DIR" 2>/dev/null || true
LOG_FILE="${LOG_DIR}/tool-calls-$(date +%Y-%m-%d).jsonl"

# Extract common fields (default to "null" / "unknown" on missing).
session_id=$(echo "$INPUT" | jq -r '.session_id // "unknown"' 2>/dev/null || echo "unknown")
cwd=$(echo "$INPUT" | jq -r '.cwd // "unknown"' 2>/dev/null || echo "unknown")
tool=$(echo "$INPUT" | jq -r '.tool_name // "unknown"' 2>/dev/null || echo "unknown")

# Parse mcp_server from tool name (mcp__<server>__<method>).
if [[ "$tool" == mcp__* ]]; then
    mcp_server=$(python3 -c 'import sys
t = sys.argv[1]
# Strip leading "mcp__", then take everything before the next "__".
rest = t[5:]
idx = rest.find("__")
print(rest if idx < 0 else rest[:idx])' "$tool")
    [ -z "$mcp_server" ] && mcp_server="null"
else
    mcp_server="null"
fi

# call_id: nanosecond-ish timestamp + PID. macOS `date` has no %N, use python.
call_id=$(python3 -c 'import time, os; print(f"{int(time.time()*1_000_000):d}-{os.getpid()}")')
ts=$(python3 -c 'import datetime; print(datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="milliseconds").replace("+00:00","Z"))')

if [ "$EVENT" = "pre" ]; then
    # Capture start time for duration calculation later.
    echo "$call_id $(python3 -c 'import time; print(time.time())')" > "${TMPDIR:-/tmp}/claude-tool-${call_id}" 2>/dev/null || true

    args=$(echo "$INPUT" | jq -c '.tool_input // {}' 2>/dev/null || echo "{}")
    if [ "$mcp_server" = "null" ]; then
        mcp_field='null'
    else
        mcp_field=$(printf '%s' "$mcp_server" | jq -R -s '.|gsub("\n$";"")')
    fi
    payload=$(jq -nc \
        --arg ts "$ts" \
        --arg sid "$session_id" \
        --arg cwd "$cwd" \
        --arg cid "$call_id" \
        --arg tool "$tool" \
        --argjson mcp "$mcp_field" \
        --argjson args "$args" \
        '{ts:$ts, session_id:$sid, cwd:$cwd, event:"pre", call_id:$cid, tool:$tool, mcp_server:$mcp, args:$args}')
else
    # Post call.
    # Find the most recent matching pre-row for this session+tool to compute duration.
    # Simpler approach: scan recent temp files for the same session and tool that haven't been claimed.
    start_file=""
    start_time=""
    for f in "${TMPDIR:-/tmp}"/claude-tool-*; do
        [ -f "$f" ] || continue
        # Match by session if present; else just take the most recent.
        line=$(cat "$f" 2>/dev/null) || continue
        start_file="$f"
        start_time=$(echo "$line" | awk '{print $2}')
        break
    done
    if [ -n "$start_time" ]; then
        end_time=$(python3 -c 'import time; print(time.time())')
        duration_ms=$(python3 -c "print(int(($end_time - $start_time) * 1000))")
        rm -f "$start_file" 2>/dev/null || true
    else
        duration_ms=0
    fi

    exit_status=$(echo "$INPUT" | jq -r '.tool_response.exit_code // .tool_response.exitCode // 0' 2>/dev/null || echo 0)
    output=$(echo "$INPUT" | jq -c '.tool_response // {}' 2>/dev/null || echo "{}")
    if [ "$mcp_server" = "null" ]; then
        mcp_field='null'
    else
        mcp_field=$(printf '%s' "$mcp_server" | jq -R -s '.|gsub("\n$";"")')
    fi
    payload=$(jq -nc \
        --arg ts "$ts" \
        --arg sid "$session_id" \
        --arg cwd "$cwd" \
        --arg cid "$call_id" \
        --arg tool "$tool" \
        --argjson mcp "$mcp_field" \
        --argjson exit "$exit_status" \
        --argjson dur "$duration_ms" \
        --argjson output "$output" \
        '{ts:$ts, session_id:$sid, cwd:$cwd, event:"post", call_id:$cid, tool:$tool, mcp_server:$mcp, exit_status:$exit, duration_ms:$dur, output:$output}')
fi

# Pipe through redaction then atomic write. Never let logging break a tool call.
{
    echo "$payload" | python3 "${LIB_DIR}/redact.py" | python3 "${LIB_DIR}/jsonl-write.py" "$LOG_FILE"
} >/dev/null 2>&1 || true

exit 0
