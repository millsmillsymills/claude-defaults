#!/usr/bin/env bash
# Convention hooks. Hooks A (warn-merge-after-pr.sh), B
# (stop-check-clean-repo.sh), and D (safety-warn.sh JSON) are covered here. Each
# case synthesizes the hook's stdin JSON and asserts on exit code / stdout. A
# throwaway HOME keeps marker files out of the real ~/.claude.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

fail=0
fail_msg() {
  echo "FAIL: $1" >&2
  fail=$((fail + 1))
}

TMPHOME="$(mktemp -d)"
trap 'rm -rf "$TMPHOME"' EXIT

# === Hook A: warn-merge-after-pr.sh ===
A="hooks/warn-merge-after-pr.sh"
A_RC=0
# All temp files/dirs below live under $TMPHOME so the single trap cleans them.
_a_out="$(mktemp "$TMPHOME/a_out.XXXXXX")"

# run_a cmd sid — runs the hook, sets A_RC in the current shell, writes output
# to $_a_out. Read output from that file instead of via command substitution so
# A_RC propagates to the parent (command substitution creates a subshell).
run_a() {
  jq -nc --arg c "$1" --arg s "$2" \
    '{tool_name:"Bash",tool_input:{command:$c},session_id:$s}' |
    HOME="$TMPHOME" bash "$A" >"$_a_out" 2>/dev/null
  A_RC=$?
}

# create sets a per-session marker, exits 0, emits nothing.
run_a 'gh pr create -t x -b y' 'S1'
[ "$A_RC" = 0 ] || fail_msg "A: create did not exit 0"
[ ! -s "$_a_out" ] || fail_msg "A: create should emit no advisory"
[ -f "$TMPHOME/.claude/state/pr-created-S1" ] || fail_msg "A: create did not set marker"

# merge in the same session emits additionalContext, still exits 0.
run_a 'gh pr merge 12 --squash' 'S1'
[ "$A_RC" = 0 ] || fail_msg "A: merge did not exit 0"
jq -e '.hookSpecificOutput.additionalContext' "$_a_out" >/dev/null 2>&1 ||
  fail_msg "A: merge with marker did not emit additionalContext"

# merge in a fresh session (no marker) is silent.
run_a 'gh pr merge 12 --squash' 'S2'
[ "$A_RC" = 0 ] || fail_msg "A: merge no-marker did not exit 0"
[ ! -s "$_a_out" ] || fail_msg "A: merge without marker should be silent"

# `gh pr create` inside a quoted literal must not set a marker. Trailing args
# after `create` keep the regex from self-rejecting, so scrubbing is the only
# thing preventing a false-positive marker here.
run_a 'echo "gh pr create -t foo"' 'S4'
[ -f "$TMPHOME/.claude/state/pr-created-S4" ] && fail_msg "A: quoted create set a marker"

# A path-traversal session_id must be sanitized: the marker stays inside the
# state dir (unsafe chars -> _) and nothing escapes to a parent directory.
run_a 'gh pr create -t x -b y' '../evil'
[ -f "$TMPHOME/.claude/state/pr-created-___evil" ] || fail_msg "A: did not sanitize sid into state dir"
[ ! -e "$TMPHOME/.claude/evil" ] || fail_msg "A: unsanitized sid escaped state dir"

# Conservative stance: an unquoted `gh pr merge` literal still triggers the
# advisory once a marker exists -- the scrubber only strips quoted strings, and
# the hook prefers warning too often to missing a real merge.
run_a 'gh pr create -t x -b y' 'S5'
run_a 'echo gh pr merge' 'S5'
jq -e '.hookSpecificOutput.additionalContext' "$_a_out" >/dev/null 2>&1 ||
  fail_msg "A: unquoted merge literal with marker should still warn (conservative)"

# === Hook B: stop-check-clean-repo.sh ===
B="hooks/stop-check-clean-repo.sh"

mk_repo() { # -> echoes a fresh repo path with one commit
  local r
  r="$(mktemp -d "$TMPHOME/repo.XXXXXX")"
  git -C "$r" init -q
  git -C "$r" config user.email t@example.com
  git -C "$r" config user.name tester
  echo one >"$r/file"
  git -C "$r" add file
  git -C "$r" commit -qm init
  printf '%s' "$r"
}

mk_transcript() { # tool_name -> echoes a transcript path containing one tool_use
  local t
  t="$(mktemp "$TMPHOME/tr.XXXXXX")"
  printf '%s\n' "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"tool_use\",\"name\":\"$1\"}]}}" >"$t"
  printf '%s' "$t"
}

run_b() { # cwd sid transcript -> echoes exit code
  jq -nc --arg c "$1" --arg s "$2" --arg t "$3" \
    '{cwd:$c,session_id:$s,transcript_path:$t,hook_event_name:"Stop"}' |
    HOME="$TMPHOME" bash "$B" >/dev/null 2>&1
  echo $?
}

# dirty tree + a mutating-tool transcript -> nudge once (exit 2), then exit 0.
repo="$(mk_repo)"
echo two >>"$repo/file" # make it dirty
tr_edit="$(mk_transcript Edit)"
[ "$(run_b "$repo" B1 "$tr_edit")" = 2 ] || fail_msg "B: dirty+Edit should nudge (exit 2)"
[ "$(run_b "$repo" B1 "$tr_edit")" = 0 ] || fail_msg "B: second call same session should allow stop (exit 0)"

# clean tree -> no nudge.
git -C "$repo" commit -qam two
[ "$(run_b "$repo" B2 "$tr_edit")" = 0 ] || fail_msg "B: clean tree should not nudge"

# dirty tree but read-only transcript (no mutating tool) -> no nudge.
echo three >>"$repo/file"
tr_read="$(mk_transcript Read)"
[ "$(run_b "$repo" B3 "$tr_read")" = 0 ] || fail_msg "B: dirty+read-only should not nudge"

# non-repo cwd -> no nudge.
nonrepo="$(mktemp -d "$TMPHOME/nonrepo.XXXXXX")"
[ "$(run_b "$nonrepo" B4 "$tr_edit")" = 0 ] || fail_msg "B: non-repo cwd should not nudge"

# === Hook C: cleanup-session-markers.sh removes this session's markers ===
C="hooks/cleanup-session-markers.sh"

run_c() { # sid -> runs the SessionEnd cleanup hook
  jq -nc --arg s "$1" '{session_id:$s,hook_event_name:"SessionEnd"}' |
    HOME="$TMPHOME" bash "$C" >/dev/null 2>&1
}

# Seed markers for two sessions; cleanup of C1 removes only C1's markers.
: >"$TMPHOME/.claude/state/pr-created-C1"
: >"$TMPHOME/.claude/state/clean-nudged-C1"
: >"$TMPHOME/.claude/state/pr-created-C2"
run_c C1
[ ! -e "$TMPHOME/.claude/state/pr-created-C1" ] || fail_msg "C: did not remove pr-created marker"
[ ! -e "$TMPHOME/.claude/state/clean-nudged-C1" ] || fail_msg "C: did not remove clean-nudged marker"
[ -e "$TMPHOME/.claude/state/pr-created-C2" ] || fail_msg "C: removed another session's marker"

# === Hook D: safety-warn.sh now emits JSON additionalContext (not stderr) ===
D="hooks/safety-warn.sh"

run_d() { # file_path -> stdout
  jq -nc --arg f "$1" '{tool_name:"Write",tool_input:{file_path:$f}}' | bash "$D"
}

out=$(run_d '/tmp/project/.env')
printf '%s' "$out" | jq -e '.hookSpecificOutput.additionalContext' >/dev/null 2>&1 ||
  fail_msg "D: sensitive path did not emit additionalContext"

out=$(run_d '/tmp/project/notes.txt')
[ -z "$out" ] || fail_msg "D: benign path should emit nothing"

# === Hook E: enforce-session-worktree.sh -- peer-session worktree guard ===
E="hooks/enforce-session-worktree.sh"
_e_out="$(mktemp "$TMPHOME/e_out.XXXXXX")"

# A throwaway git repo acts as the shared main checkout.
E_REPO="$TMPHOME/repo"
git init -q "$E_REPO" 2>/dev/null

run_e() { # mode sid cwd
  jq -nc --arg s "$2" --arg d "$3" '{session_id:$s, cwd:$d}' |
    HOME="$TMPHOME" bash "$E" "$1" >"$_e_out" 2>/dev/null
}

e_marker() { find "$TMPHOME/.claude/state" -name 'worktree-owner-*' 2>/dev/null | head -1; }

# First session claims the marker silently.
run_e start E1 "$E_REPO"
[ -n "$(e_marker)" ] || fail_msg "E: first session did not claim owner marker"
[ ! -s "$_e_out" ] || fail_msg "E: first session should emit nothing"

# Same session again: silent reclaim, no advisory.
run_e start E1 "$E_REPO"
[ ! -s "$_e_out" ] || fail_msg "E: owner re-start should emit nothing"

# A second session in the same checkout gets the worktree advisory.
run_e start E2 "$E_REPO"
jq -e '.hookSpecificOutput.additionalContext' "$_e_out" >/dev/null 2>&1 ||
  fail_msg "E: parallel session did not get worktree advisory"

# The advisory does not steal ownership; end from the owner releases it.
run_e end E1 "$E_REPO"
[ -z "$(e_marker)" ] || fail_msg "E: end did not release owner marker"

# After release the next session claims cleanly and silently.
run_e start E2 "$E_REPO"
[ ! -s "$_e_out" ] || fail_msg "E: post-release claim should emit nothing"
run_e end E2 "$E_REPO"

# Outside a git repo: no marker, no output.
run_e start E3 "$TMPHOME"
[ -z "$(e_marker)" ] || fail_msg "E: non-repo cwd should not claim a marker"
[ ! -s "$_e_out" ] || fail_msg "E: non-repo cwd should emit nothing"

echo "convention-hooks: checks ran"
[ "$fail" -eq 0 ] || {
  echo "FAILED: $fail check(s)" >&2
  exit 1
}
echo "ALL CONVENTION-HOOK TESTS PASSED"
