#!/usr/bin/env bash
# Shared helpers for claude-defaults hooks.
#
# Source from a hook script:
#     SCRIPT_DIR=$(SCRIPT_DIR_OF "${BASH_SOURCE[0]}")
#     source "${SCRIPT_DIR}/lib/common.sh"
#
# Functions:
#   SCRIPT_DIR_OF <path>    - absolute dir of <path>, resolving symlinks
#   claude_logs_dir         - prints ~/.claude/logs
#   ensure_logs_dir         - mkdir -p the logs dir, idempotent
#   extract_jq_field <jq>   - reads stdin, runs jq with the expression,
#                             prints "null" on missing/empty (no error)

SCRIPT_DIR_OF() {
    local target="$1"
    # readlink -f is GNU; macOS lacks it. Use a portable fallback.
    if command -v greadlink >/dev/null 2>&1; then
        dirname "$(greadlink -f "$target")"
    elif readlink -f / >/dev/null 2>&1; then
        dirname "$(readlink -f "$target")"
    else
        # macOS-portable: cd into dir, follow symlink one level
        local link
        link=$(readlink "$target" || echo "$target")
        case "$link" in
            /*) dirname "$link" ;;
            *)  cd "$(dirname "$target")" && cd "$(dirname "$link")" && pwd ;;
        esac
    fi
}

claude_logs_dir() {
    echo "${HOME}/.claude/logs"
}

ensure_logs_dir() {
    mkdir -p "$(claude_logs_dir)" 2>/dev/null || true
}

extract_jq_field() {
    local expr="$1"
    jq -r "${expr} // \"null\"" 2>/dev/null || echo "null"
}
