#!/usr/bin/env bash
# PostToolUse hook (matcher: Task, exit 0): records that a review ran this
# session by writing a per-session marker when a review subagent completes.
# gate-public-review.sh requires both a standard and an adversarial marker before
# it permits an issue/PR write to a public GitHub repo. Never blocks (exit 0).
#
# This is a cooperative-workflow guardrail, not a defense against an adversarial
# agent: markers live in agent-writable ~/.claude/state, so a bare `touch
# review-<category>-<sid>` forges one. The gate's value is reminding a cooperating
# session to run reviews, not making the markers unforgeable.
#   standard:    code-reviewer
#   adversarial: silent-failure-hunter, red-team-reviewer, security review, or any
#                subagent whose name reads as security / red-team / adversarial.
set -uo pipefail

input=$(cat)
tool=$(printf '%s' "$input" | jq -r '.tool_name // ""' 2>/dev/null || echo "")
[ "$tool" = "Task" ] || exit 0
subagent=$(printf '%s' "$input" | jq -r '.tool_input.subagent_type // ""' 2>/dev/null || echo "")
sid=$(printf '%s' "$input" | jq -r '.session_id // ""' 2>/dev/null || echo "")
[ -n "$subagent" ] || exit 0
[ -n "$sid" ] || sid="unknown"
sid="${sid//[^A-Za-z0-9_-]/_}"

# Strip any plugin namespace ("pr-review-toolkit:code-reviewer" -> "code-reviewer")
# and lowercase so matching is namespace- and case-insensitive.
name="${subagent##*:}"
name=$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]')

state_dir="${HOME}/.claude/state"
mkdir -p "$state_dir" 2>/dev/null || true
# Backstop sweep for sessions that died without SessionEnd cleanup.
find "$state_dir" -name 'review-*' -type f -mtime +7 -delete 2>/dev/null || true

category=""
case "$name" in
code-reviewer) category="standard" ;;
silent-failure-hunter | red-team-reviewer | security-reviewer | security-review) category="adversarial" ;;
*security* | *red-team* | *redteam* | *adversar*) category="adversarial" ;;
esac
[ -n "$category" ] || exit 0

: >"${state_dir}/review-${category}-${sid}" 2>/dev/null || true
exit 0
