#!/usr/bin/env bash
# Public-repo review gate. Covers mark-review.sh (writes per-session review
# markers on review-subagent completion) and gate-public-review.sh (blocks
# issue/PR writes to public repos until both markers exist). A throwaway HOME
# isolates marker files; a fake `gh` on PATH supplies repo visibility without a
# network call. Each case uses a distinct session id so markers/cache do not bleed.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

fail=0
fail_msg() {
  echo "FAIL: $1" >&2
  fail=$((fail + 1))
}

TMPHOME="$(mktemp -d)"
BIN="$(mktemp -d)"
trap 'rm -rf "$TMPHOME" "$BIN"' EXIT

# Fake gh: for `gh repo view ... --json visibility`, print $FAKE_VISIBILITY
# (empty simulates an unresolved/offline repo). Everything else is a no-op.
cat >"$BIN/gh" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *"repo view"*) printf '%s' "${FAKE_VISIBILITY:-}" ;;
  *) : ;;
esac
EOF
chmod +x "$BIN/gh"

state="$TMPHOME/.claude/state"

# === mark-review.sh ===
M="hooks/mark-review.sh"
run_mark() { # subagent_type sid
  jq -nc --arg t "$1" --arg s "$2" \
    '{tool_name:"Task",tool_input:{subagent_type:$t},session_id:$s}' |
    HOME="$TMPHOME" bash "$M" >/dev/null 2>&1
}

run_mark 'code-reviewer' M1
[ -f "$state/review-standard-M1" ] || fail_msg "M: code-reviewer did not write standard marker"
[ ! -f "$state/review-adversarial-M1" ] || fail_msg "M: code-reviewer wrote an adversarial marker"

run_mark 'pr-review-toolkit:silent-failure-hunter' M2
[ -f "$state/review-adversarial-M2" ] || fail_msg "M: silent-failure-hunter did not write adversarial marker"

run_mark 'red-team-reviewer' M3
[ -f "$state/review-adversarial-M3" ] || fail_msg "M: red-team-reviewer did not write adversarial marker"

# Namespace stripped: a plugin-qualified code-reviewer still maps to standard.
run_mark 'pr-review-toolkit:code-reviewer' M4
[ -f "$state/review-standard-M4" ] || fail_msg "M: namespaced code-reviewer did not write standard marker"

# A name that merely reads as security counts as adversarial.
run_mark 'my-security-auditor' M5
[ -f "$state/review-adversarial-M5" ] || fail_msg "M: security-named agent did not write adversarial marker"

# Non-review subagent writes nothing.
run_mark 'general-purpose' M6
[ -f "$state/review-standard-M6" ] && fail_msg "M: general-purpose wrote a standard marker"
[ -f "$state/review-adversarial-M6" ] && fail_msg "M: general-purpose wrote an adversarial marker"

# Non-Task tool is ignored even with a review-shaped payload.
jq -nc '{tool_name:"Bash",tool_input:{subagent_type:"code-reviewer"},session_id:"M7"}' |
  HOME="$TMPHOME" bash "$M" >/dev/null 2>&1
[ -f "$state/review-standard-M7" ] && fail_msg "M: non-Task tool wrote a marker"

# session_id with path traversal is sanitized into the state dir.
run_mark 'code-reviewer' '../evil'
[ -f "$state/review-standard-___evil" ] || fail_msg "M: did not sanitize sid into state dir"
[ ! -e "$TMPHOME/.claude/evil" ] || fail_msg "M: unsanitized sid escaped state dir"

# === gate-public-review.sh ===
G="hooks/gate-public-review.sh"
G_RC=0
_g_out="$(mktemp "$TMPHOME/g_out.XXXXXX")"
run_gate() { # cmd sid visibility
  jq -nc --arg c "$1" --arg s "$2" \
    '{tool_name:"Bash",tool_input:{command:$c},session_id:$s}' |
    HOME="$TMPHOME" PATH="$BIN:$PATH" FAKE_VISIBILITY="$3" bash "$G" >"$_g_out" 2>&1
  G_RC=$?
}

# Public repo, no markers -> blocked.
run_gate 'gh issue create -t x -b y' G1 PUBLIC
[ "$G_RC" = 2 ] || fail_msg "G: public issue create without reviews should block (exit 2)"
grep -q 'adversarial' "$_g_out" || fail_msg "G: block message should name the missing adversarial review"

# Public repo, only the standard marker -> still blocked, names adversarial.
: >"$state/review-standard-G2"
run_gate 'gh pr create -t x -b y' G2 PUBLIC
[ "$G_RC" = 2 ] || fail_msg "G: one marker present should still block"

# Public repo, both markers -> allowed.
: >"$state/review-standard-G3"
: >"$state/review-adversarial-G3"
run_gate 'gh issue create -t x -b y' G3 PUBLIC
[ "$G_RC" = 0 ] || fail_msg "G: both markers present should allow (exit 0)"

# End to end: reviews recorded via mark-review.sh satisfy the gate.
run_mark 'code-reviewer' G4
run_mark 'silent-failure-hunter' G4
run_gate 'gh pr comment 5 -b hello' G4 PUBLIC
[ "$G_RC" = 0 ] || fail_msg "G: marker-writer reviews should satisfy the gate"

# Private repo is exempt even with no markers.
run_gate 'gh issue create -t x -b y' G5 PRIVATE
[ "$G_RC" = 0 ] || fail_msg "G: private repo should be exempt (exit 0)"

# Internal repo is exempt (not world-visible).
run_gate 'gh issue create -t x -b y' G6 INTERNAL
[ "$G_RC" = 0 ] || fail_msg "G: internal repo should be exempt (exit 0)"

# Read-only gh is never gated.
run_gate 'gh issue list' G7 PUBLIC
[ "$G_RC" = 0 ] || fail_msg "G: gh issue list should not be gated"

# Non-gh command is ignored.
run_gate 'echo hi' G8 PUBLIC
[ "$G_RC" = 0 ] || fail_msg "G: non-gh command should not be gated"

# A gh write inside a quoted literal must not trip the gate.
run_gate 'echo "gh issue create -t x"' G9 PUBLIC
[ "$G_RC" = 0 ] || fail_msg "G: quoted gh write literal should not be gated"

# gh api with a mutating method against /issues is a write -> blocked.
run_gate 'gh api -X POST /repos/o/r/issues -f title=x' G10 PUBLIC
[ "$G_RC" = 2 ] || fail_msg "G: gh api POST to /issues should block"

# gh api without a mutating method (a GET) is a read -> not gated.
run_gate 'gh api /repos/o/r/issues' G11 PUBLIC
[ "$G_RC" = 0 ] || fail_msg "G: gh api GET to /issues should not be gated"

# Unresolved visibility (offline) fails closed and says so.
run_gate 'gh issue create -t x -b y' G12 ''
[ "$G_RC" = 2 ] || fail_msg "G: unresolved visibility should fail closed (exit 2)"
grep -q 'could not be confirmed' "$_g_out" || fail_msg "G: unresolved-visibility message should note the failure"

# Visibility is cached per session: a PRIVATE resolution sticks even if a later
# call would see PUBLIC.
run_gate 'gh issue comment 1 -b hi' G13 PRIVATE
[ "$G_RC" = 0 ] || fail_msg "G: first private resolution should allow"
run_gate 'gh issue create -t x -b y' G13 PUBLIC
[ "$G_RC" = 0 ] || fail_msg "G: cached private visibility should keep exemption"

echo "public-review-gate: checks ran"
[ "$fail" -eq 0 ] || {
  echo "FAILED: $fail check(s)" >&2
  exit 1
}
echo "ALL PUBLIC-REVIEW-GATE TESTS PASSED"
