#!/usr/bin/env bash
# PreToolUse hook (matcher: Bash): non-blocking advisory for the create/merge
# session-separation convention. Records a per-session marker when `gh pr
# create` runs; on a later `gh pr merge` in the same session, injects a
# system reminder via JSON additionalContext. Never blocks (exit 0).
#
# Exit-0 stderr is invisible to Claude (see docs/HOOKS.md), so the advisory is
# emitted as JSON on stdout -- the only non-blocking, model-visible channel.
set -uo pipefail

input=$(cat)
cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // ""' 2>/dev/null || echo "")
sid=$(printf '%s' "$input" | jq -r '.session_id // ""' 2>/dev/null || echo "")
[ -n "$cmd" ] || exit 0
[ -n "$sid" ] || sid="unknown"
# session_id is untrusted input; sanitize before it reaches a filesystem path
# (mirrors _sanitize in hooks/lib/log_tool_call.py).
sid="${sid//[^A-Za-z0-9_-]/_}"

state_dir="${HOME}/.claude/state"
mkdir -p "$state_dir" 2>/dev/null || true
# Backstop sweep for sessions that died without SessionEnd (the normal owner is
# cleanup-session-markers.sh, which removes this session's marker on exit).
find "$state_dir" -name 'pr-created-*' -type f -mtime +7 -delete 2>/dev/null || true

# Strip quoted strings before matching (mirrors block-push-main.sh) so a
# `gh pr create` inside a quoted literal does not trigger.
scrubbed=$(printf '%s' "$cmd" | sed -E 's/"[^"]*"//g' | sed -E "s/'[^']*'//g")

is_pr_create() { printf '%s' "$scrubbed" | grep -Eq '(^|[^[:alnum:]])gh([[:space:]]+[^;&|]*)?[[:space:]]pr[[:space:]]+create([[:space:]]|$)'; }
is_pr_merge() { printf '%s' "$scrubbed" | grep -Eq '(^|[^[:alnum:]])gh([[:space:]]+[^;&|]*)?[[:space:]]pr[[:space:]]+merge([[:space:]]|$)'; }

marker="${state_dir}/pr-created-${sid}"
if is_pr_create; then
  : >"$marker" 2>/dev/null || true
fi

# A single command that both creates and merges (e.g. `gh pr create && gh pr
# merge`) also matches here -- intentional: the advisory is conservative and
# never blocks, so warning slightly too often is preferred to missing a case.
if is_pr_merge && { [ -f "$marker" ] || is_pr_create; }; then
  msg="PR-workflow convention: this session created a PR. Merges belong in a separate review-cycle session, not the session that created the PR. Proceeding -- consider deferring the merge to a fresh session."
  jq -nc --arg c "$msg" \
    '{hookSpecificOutput:{hookEventName:"PreToolUse",additionalContext:$c}}'
fi

exit 0
