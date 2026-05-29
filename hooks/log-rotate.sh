#!/usr/bin/env bash
# SessionEnd hook: gzip-rotate today's log if too big, prune old logs.
#
# Wire up in settings.json:
#   SessionEnd -> command "$HOME/.claude/hooks/log-rotate.sh"
#
# Env:
#   CLAUDE_LOG_ROTATE_BYTES   max bytes before gzip rotation (default 100MB)
#   CLAUDE_LOG_RETAIN_DAYS    days to keep logs (default 365 — long retention
#                             supports cross-session analytics / /ce learning)

set -uo pipefail

LOG_DIR="${HOME}/.claude/logs"
[ -d "$LOG_DIR" ] || exit 0

ROTATE_BYTES="${CLAUDE_LOG_ROTATE_BYTES:-104857600}"   # 100 MB
RETAIN_DAYS="${CLAUDE_LOG_RETAIN_DAYS:-365}"

# UTC to match the writer (log_tool_call.py names files by UTC date); a local
# date would target the wrong file near midnight on non-UTC machines.
today_log="${LOG_DIR}/tool-calls-$(date -u +%Y-%m-%d).jsonl"

# Rotate today's log if too big.
if [ -f "$today_log" ]; then
    size=$(stat -f%z "$today_log" 2>/dev/null || stat -c%s "$today_log" 2>/dev/null || echo 0)
    if [ "$size" -ge "$ROTATE_BYTES" ]; then
        n=1
        while [ -e "${today_log}.${n}.gz" ] || [ -e "${today_log}.${n}.rotating" ]; do
            n=$((n + 1))
        done
        # Rotate without a delete-after-read window. The old code gzipped the
        # live log then rm'd it; any tool call that appended between gzip's EOF
        # read and the rm was silently dropped — a window mid-session rotation
        # makes more reachable with parallel agents sharing this dir. Instead,
        # rename the live log aside first (rename is atomic): appends after this
        # point open the path fresh and land in a new today_log, never in the
        # file we are about to archive. Then gzip the renamed copy and verify it
        # before deleting. A bad archive (ENOSPC, absorbed SIGPIPE) leaves the
        # renamed log in place — data preserved, never destroyed under a broken
        # .gz, and never clobbering a today_log a concurrent writer recreated.
        rotating="${today_log}.${n}.rotating"
        if mv "$today_log" "$rotating" 2>/dev/null; then
            tmp_gz="${today_log}.${n}.gz.tmp"
            if gzip -c "$rotating" > "$tmp_gz" && gzip -t "$tmp_gz" 2>/dev/null; then
                mv "$tmp_gz" "${today_log}.${n}.gz" && rm -f "$rotating"
            else
                rm -f "$tmp_gz"
            fi
        fi
    fi
fi

# Prune old logs.
find "$LOG_DIR" -name 'tool-calls-*.jsonl*' -type f -mtime +"$RETAIN_DAYS" -delete 2>/dev/null || true

exit 0
