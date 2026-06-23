#!/usr/bin/env bash
# PreToolUse hook (matcher: Bash, exit 2 to block): issue/PR write actions to a
# PUBLIC GitHub repo are blocked until both a standard review and an adversarial
# review have run this session. Those reviews leave per-session markers written
# by mark-review.sh when their subagents complete; this gate refuses the write
# until both markers exist.
#
# Scope: gh issue create/edit/comment/close/reopen/... , gh pr
# create/edit/comment/close/reopen/merge/ready/review, and `gh api` with a
# mutating method against an /issues or /pulls path. Read-only gh (list/view/
# status/diff/checks) is never gated.
#
# Visibility: the repo is resolved from an explicit --repo/-R flag, else from the
# cwd remote, and `gh repo view --json visibility` is consulted once per repo per
# session (cached). PRIVATE/INTERNAL repos are exempt. If visibility cannot be
# confirmed the write is gated (fail closed) -- the write itself needs the same
# network, so an offline session was going to fail regardless.
set -uo pipefail

input=$(cat)
cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // ""' 2>/dev/null || echo "")
sid=$(printf '%s' "$input" | jq -r '.session_id // ""' 2>/dev/null || echo "")
[ -n "$cmd" ] || exit 0
[ -n "$sid" ] || sid="unknown"
# session_id is untrusted input; sanitize before it reaches a filesystem path
# (mirrors _sanitize in hooks/lib/log_tool_call.py and the other marker writers).
sid="${sid//[^A-Za-z0-9_-]/_}"

# Fast bail: nothing to do unless gh is invoked.
printf '%s' "$cmd" | grep -Eq '(^|[^[:alnum:]])gh([[:space:]]|$)' || exit 0

# Strip quoted strings before matching subcommands (mirrors warn-merge-after-pr.sh)
# so a `gh issue create` inside a quoted literal does not trip the gate.
scrubbed=$(printf '%s' "$cmd" | sed -E 's/"[^"]*"//g' | sed -E "s/'[^']*'//g")

gh_sub_re='(^|[^[:alnum:]])gh([[:space:]]+[^;&|]*)?[[:space:]]'

is_write() {
  printf '%s' "$scrubbed" | grep -Eq "${gh_sub_re}issue[[:space:]]+(create|edit|comment|close|reopen|delete|lock|unlock|pin|unpin|transfer|develop)([[:space:]]|$)" && return 0
  printf '%s' "$scrubbed" | grep -Eq "${gh_sub_re}pr[[:space:]]+(create|edit|comment|close|reopen|merge|ready|review)([[:space:]]|$)" && return 0
  if printf '%s' "$scrubbed" | grep -Eq "${gh_sub_re}api([[:space:]]|$)" &&
    printf '%s' "$scrubbed" | grep -Eq -- '(-X|--method)[[:space:]=]+(POST|PATCH|PUT|DELETE)' &&
    printf '%s' "$scrubbed" | grep -Eq '/(issues|pulls)'; then
    return 0
  fi
  return 1
}
is_write || exit 0

state_dir="${HOME}/.claude/state"
mkdir -p "$state_dir" 2>/dev/null || true
# Visibility can change; expire cache entries after a day. SessionEnd cleanup is
# the normal owner -- this sweep is the backstop for crashed sessions.
find "$state_dir" -name 'repovis-*' -type f -mtime +1 -delete 2>/dev/null || true

# Resolve the target repo from an explicit flag (read the original cmd, not the
# quote-scrubbed copy, so owner/repo survives).
repo=$(printf '%s' "$cmd" | grep -Eo -- '(--repo|-R)[[:space:]=]+[^[:space:]]+' | head -1 |
  sed -E 's/^(--repo|-R)[[:space:]=]+//')
repo="${repo//\"/}"
repo="${repo//\'/}"

repo_key="${repo:-__cwd__}"
repo_key="${repo_key//[^A-Za-z0-9_.-]/_}"
visfile="${state_dir}/repovis-${sid}-${repo_key}"

if [ -s "$visfile" ]; then
  visibility=$(cat "$visfile" 2>/dev/null || echo "")
else
  if [ -n "$repo" ]; then
    visibility=$(gh repo view "$repo" --json visibility -q .visibility 2>/dev/null || echo "")
  else
    visibility=$(gh repo view --json visibility -q .visibility 2>/dev/null || echo "")
  fi
  # Cache successful resolutions only; an unresolved repo retries next time.
  [ -n "$visibility" ] && printf '%s' "$visibility" >"$visfile" 2>/dev/null || true
fi

case "$visibility" in
  PRIVATE | INTERNAL) exit 0 ;; # not world-visible -> exempt
esac

std="${state_dir}/review-standard-${sid}"
adv="${state_dir}/review-adversarial-${sid}"
[ -f "$std" ] && [ -f "$adv" ] && exit 0

missing=""
[ -f "$std" ] || missing="${missing} standard"
[ -f "$adv" ] || missing="${missing} adversarial"

vis_note="this repo is public"
[ -n "$visibility" ] || vis_note="this repo's visibility could not be confirmed, so it is treated as public"

cat >&2 <<EOF
BLOCKED: writing to a public GitHub repo requires review first.

Missing review(s):${missing}
Reason: ${vis_note}, and a public issue/PR write must pass a standard review and
an adversarial review this session before it goes out.

To satisfy the gate:
  - Standard review:    dispatch the code-reviewer agent on the change.
  - Adversarial review: run /pr-review:review-pr (covers silent-failure-hunter
                        and security review) or dispatch the red-team-reviewer
                        agent. Either writes the adversarial marker.
Each review's subagent completion records its marker automatically; re-run the
gh command afterward. If this repo is actually private, the visibility check
failed (e.g. offline) -- re-run once gh can reach the network.
EOF
exit 2
