#!/usr/bin/env bash
# Stop hook (command type): nudge to commit/clean up before finishing, gated to
# avoid false positives. Fires at most once per session (marker), exit 2 to
# force one continue; exit 0 otherwise. See docs/HOOKS.md.
#
# Gates (all required to nudge): cwd is a git work tree; the tree is dirty; and
# this session's transcript shows a mutating file tool (Edit/Write/MultiEdit/
# NotebookEdit), so pre-existing dirt in read-only sessions is never nagged.
set -uo pipefail

input=$(cat)
cwd=$(printf '%s' "$input" | jq -r '.cwd // ""' 2>/dev/null || echo "")
sid=$(printf '%s' "$input" | jq -r '.session_id // ""' 2>/dev/null || echo "")
transcript=$(printf '%s' "$input" | jq -r '.transcript_path // ""' 2>/dev/null || echo "")
[ -n "$cwd" ] || exit 0
[ -n "$sid" ] || sid="unknown"

state_dir="${HOME}/.claude/state"
mkdir -p "$state_dir" 2>/dev/null || true
find "$state_dir" -name 'clean-nudged-*' -type f -mtime +7 -delete 2>/dev/null || true
nudged="${state_dir}/clean-nudged-${sid}"

# Already nudged this session -> allow the stop (loop-safe; no stop_hook_active).
[ -f "$nudged" ] && exit 0

git -C "$cwd" rev-parse --is-inside-work-tree >/dev/null 2>&1 || exit 0
[ -n "$(git -C "$cwd" status --porcelain 2>/dev/null)" ] || exit 0

[ -n "$transcript" ] && [ -f "$transcript" ] || exit 0
grep -Eq '"name":[[:space:]]*"(Edit|Write|MultiEdit|NotebookEdit)"' "$transcript" 2>/dev/null || exit 0

: >"$nudged" 2>/dev/null || true
cat >&2 <<'MSG'
PR-workflow convention: this session left uncommitted changes in the working
tree. Commit local work via a PR and clean up the repo before finishing, or
stop again if the work-in-progress tree is intentional.
MSG
exit 2
