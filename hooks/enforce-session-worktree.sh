#!/usr/bin/env bash
# Peer-session worktree guard. Complements force-worktree-isolation.sh: that hook
# isolates file-mutating SUBAGENTS (Agent/Task) into worktrees; this one covers
# separately-launched PEER `claude` sessions that would otherwise share one main
# checkout (branch flips, stray untracked files, half-committed state).
#
# Modes (arg 1): "start" (SessionStart) | "end" (SessionEnd).
#   start: the FIRST session in a repo's MAIN working tree claims an owner marker
#          in ~/.claude/state. A later session that starts in the SAME main
#          checkout while that marker is fresh is a parallel session -- it is told,
#          up front, to create/switch to its own git worktree before editing.
#   end:   release any marker this session owned, so the next session in that
#          checkout is not wrongly treated as parallel.
#
# Advisory only -- never blocks. A stale marker (owner crashed without a
# SessionEnd) at worst tells a lone session to use a worktree it does not need;
# a hard block keyed on liveness would wrongly lock out a legitimate solo
# session, which is worse. Errs toward worktrees on purpose. Sessions already in
# a linked worktree, or outside any git repo, are never touched. See docs/HOOKS.md.
set -uo pipefail

mode="${1:-start}"
input=$(cat 2>/dev/null || true)
sid=$(printf '%s' "$input" | jq -r '.session_id // ""' 2>/dev/null || echo "")
[ -n "$sid" ] || sid="unknown"
# session_id is untrusted input; sanitize before it reaches a filesystem path.
sid="${sid//[^A-Za-z0-9_-]/_}"

state_dir="${HOME}/.claude/state"
mkdir -p "$state_dir" 2>/dev/null || true

if [ "$mode" = "end" ]; then
  # Release every main-checkout marker recorded to this session.
  for f in "${state_dir}"/worktree-owner-*; do
    [ -f "$f" ] || continue
    owner=$(cut -d' ' -f1 "$f" 2>/dev/null || echo "")
    [ "$owner" = "$sid" ] && rm -f "$f" 2>/dev/null || true
  done
  exit 0
fi

# --- start mode ---
cwd=$(printf '%s' "$input" | jq -r '.cwd // ""' 2>/dev/null || echo "")
[ -n "$cwd" ] || exit 0

# Must be inside a git repo's MAIN working tree. A linked worktree's git-dir is
# under .git/worktrees/ -- such a session is already isolated, so leave it alone.
gitdir=$(git -C "$cwd" rev-parse --git-dir 2>/dev/null) || exit 0
case "$gitdir" in *"/worktrees/"*) exit 0 ;; esac
toplevel=$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null) || exit 0
[ -n "$toplevel" ] || exit 0

# Backstop sweep for owners that crashed without a SessionEnd (normal release is
# the "end" mode above). Anything older than a day is certainly dead.
find "$state_dir" -name 'worktree-owner-*' -type f -mtime +1 -delete 2>/dev/null || true

key="${toplevel//[^A-Za-z0-9_-]/_}"
marker="${state_dir}/worktree-owner-${key}"
now=$(date +%s 2>/dev/null || echo 0)
stale=21600 # 6h: a fresh marker means another session is genuinely active

claim() { printf '%s %s\n' "$sid" "$now" >"$marker" 2>/dev/null || true; }

if [ -f "$marker" ]; then
  owner=$(cut -d' ' -f1 "$marker" 2>/dev/null || echo "")
  ts=$(cut -d' ' -f2 "$marker" 2>/dev/null || echo 0)
  case "$ts" in '' | *[!0-9]*) ts=0 ;; esac
  age=$((now - ts))
  # Reclaim if we already own it, the owner field is empty, or it is stale.
  if [ "$owner" = "$sid" ] || [ -z "$owner" ] || [ "$age" -gt "$stale" ] || [ "$age" -lt 0 ]; then
    claim
    exit 0
  fi
  # Fresh marker held by a different, live session -> this is a parallel one.
  reason="A parallel Claude session already owns this checkout (${toplevel}). Standing user instruction: parallel sessions MUST work in their own git worktree. Before ANY Edit/Write, create and switch to your own worktree -- e.g. \`git worktree add ../$(basename "$toplevel")-<branch> -b <branch>\` (or the EnterWorktree tool) -- and do all file work there; do NOT edit this shared main checkout. If you are certain no other session is active, delete ${marker} and proceed."
  if command -v jq >/dev/null 2>&1; then
    jq -nc --arg c "$reason" \
      '{hookSpecificOutput:{hookEventName:"SessionStart",additionalContext:$c}}'
  fi
  exit 0
fi

# No marker -> this session is the primary owner of the main checkout.
claim
exit 0
