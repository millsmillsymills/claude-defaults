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
# cwd remote, and `gh repo view --json nameWithOwner,visibility` is consulted once
# per repo identity per session (cached on nameWithOwner). PRIVATE/INTERNAL repos
# are exempt. If visibility cannot be
# confirmed the write is gated (fail closed) -- the write itself needs the same
# network, so an offline session was going to fail regardless.
set -uo pipefail

# A security gate must fail closed: without jq it cannot parse the command and so
# cannot tell a benign call from a public write -- refuse rather than allow blind.
command -v jq >/dev/null || {
  echo "BLOCKED: gate cannot parse input (jq unavailable)" >&2
  exit 2
}

input=$(cat)
cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // ""')
sid=$(printf '%s' "$input" | jq -r '.session_id // ""')
# A parsed-but-empty command genuinely means "no Bash command to gate" -> allow.
[ -n "$cmd" ] || exit 0
[ -n "$sid" ] || sid="unknown"
# session_id is untrusted input; sanitize before it reaches a filesystem path
# (mirrors _sanitize in hooks/lib/log_tool_call.py and the other marker writers).
sid="${sid//[^A-Za-z0-9_-]/_}"

# Fast bail: nothing to do unless gh is invoked (gh or gh.exe).
printf '%s' "$cmd" | grep -Eq '(^|[^[:alnum:]])gh(\.exe)?([[:space:]]|$)' || exit 0

# Strip quoted strings before matching subcommands (mirrors warn-merge-after-pr.sh)
# so a `gh issue create` inside a quoted literal does not trip the gate.
scrubbed=$(printf '%s' "$cmd" | sed -E 's/"[^"]*"//g' | sed -E "s/'[^']*'//g")

gh_sub_re='(^|[^[:alnum:]])gh(\.exe)?([[:space:]]+[^;&|]*)?[[:space:]]'

# Accepted gap: user-defined gh aliases (e.g. `gh ic` for `issue create`) are not
# resolved, so an aliased write slips through. Resolving aliases means shelling out
# to `gh alias list`, which the gate deliberately avoids on the hot path.
is_write() {
  printf '%s' "$scrubbed" | grep -Eq "${gh_sub_re}issue[[:space:]]+(create|edit|comment|close|reopen|delete|lock|unlock|pin|unpin|transfer|develop)([[:space:]]|$)" && return 0
  printf '%s' "$scrubbed" | grep -Eq "${gh_sub_re}pr[[:space:]]+(create|edit|comment|close|reopen|merge|ready|review)([[:space:]]|$)" && return 0
  printf '%s' "$scrubbed" | grep -Eq "${gh_sub_re}api([[:space:]]|$)" || return 1
  # graphql mutations create/comment/close without a path or method we'd otherwise
  # match. The payload lives inside quotes (stripped from $scrubbed), so match the
  # mutation keyword against the original $cmd.
  printf '%s' "$scrubbed" | grep -Eq "${gh_sub_re}api[[:space:]]+graphql([[:space:]]|$)" &&
    printf '%s' "$cmd" | grep -Eqi 'mutation' && return 0
  # gh api writes to issues/pulls: an explicit mutating method (-XPOST or -X POST),
  # or an implied POST/PATCH via a field flag (-f/-F/--field/--input/--raw-field).
  printf '%s' "$scrubbed" | grep -Eq '/(issues|pulls)' || return 1
  printf '%s' "$scrubbed" | grep -Eq -- '(-X[[:space:]]*|--method[[:space:]=]+)(POST|PATCH|PUT|DELETE)' && return 0
  printf '%s' "$scrubbed" | grep -Eq -- '(^|[[:space:]])(-f|-F|--field|--input|--raw-field)([[:space:]=]|$)' && return 0
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

# `gh api` carries the target repo in the URL path (`/repos/<owner>/<repo>/...`),
# not a --repo flag. Without parsing it, a `gh api` write to a PUBLIC repo issued
# from inside a PRIVATE checkout would resolve visibility from the cwd remote and
# be exempted -- a fail-open straight past the gate. An explicit --repo flag still
# wins; otherwise pull owner/repo from the api path so the visibility check
# targets the repo actually being written. (Read $scrubbed so a repo path inside
# a quoted argument is not mistaken for the target.)
if [ -z "$repo" ]; then
  repo=$(printf '%s' "$scrubbed" |
    grep -Eo '(^|[[:space:]=/])repos/[^/[:space:]]+/[^/[:space:]]+' | head -1 |
    sed -E 's#.*repos/##')
fi

# Resolve repo identity and visibility in one gh call: "<nameWithOwner>\t<vis>".
# A flagless write resolves identity from the cwd remote. The cache is keyed on
# that identity (not a shared "__cwd__" slot), so cd-ing from a private to a public
# repo can't reuse a stale PRIVATE verdict.
if [ -n "$repo" ]; then
  resolved=$(gh repo view "$repo" --json nameWithOwner,visibility \
    -q '"\(.nameWithOwner)\t\(.visibility)"' 2>/dev/null || true)
else
  resolved=$(gh repo view --json nameWithOwner,visibility \
    -q '"\(.nameWithOwner)\t\(.visibility)"' 2>/dev/null || true)
fi
name="${resolved%%$'\t'*}"
visibility=""
[ -n "$resolved" ] && [ "$resolved" != "$name" ] && visibility="${resolved#*$'\t'}"

# Key on the resolved identity; an explicit flag is the identity when resolution
# failed (offline). Without either there is nothing stable to cache against.
key="${name:-$repo}"
if [ -n "$key" ]; then
  key="${key//[^A-Za-z0-9_.-]/_}"
  visfile="${state_dir}/repovis-${sid}-${key}"
  if [ -n "$visibility" ]; then
    printf '%s' "$visibility" >"$visfile" 2>/dev/null || true
  elif [ -s "$visfile" ]; then
    visibility=$(cat "$visfile" 2>/dev/null || echo "")
  fi
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
