#!/usr/bin/env bash
# Convention hooks. Hook A (warn-merge-after-pr.sh) is covered here; the Hook B
# (stop-check-clean-repo.sh) and Hook D (safety-warn.sh JSON) sections are added
# in the following commits. Each case synthesizes the hook's stdin JSON and
# asserts on exit code / stdout. A throwaway HOME keeps marker files out of the
# real ~/.claude.
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
_a_out=$(mktemp)
trap 'rm -rf "$TMPHOME" "$_a_out"' EXIT

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

echo "convention-hooks A: checks ran"
[ "$fail" -eq 0 ] || {
  echo "FAILED: $fail check(s)" >&2
  exit 1
}
echo "ALL CONVENTION-HOOK TESTS PASSED"
