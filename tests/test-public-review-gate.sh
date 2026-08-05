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

# Fake gh: for `gh repo view [<owner/repo>] --json nameWithOwner,visibility`,
# print "<nameWithOwner>\t<FAKE_VISIBILITY>". nameWithOwner (resolved from the
# local remote, so it survives offline) comes from the explicit positional repo
# arg if given, else $FAKE_REPO (the cwd identity). An empty FAKE_VISIBILITY
# simulates an offline visibility lookup: identity resolves, visibility does not.
# Everything else is a no-op.
cat >"$BIN/gh" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "repo" ] && [ "${2:-}" = "view" ]; then
  name="${FAKE_REPO:-cwd/repo}"
  vis="${FAKE_VISIBILITY:-}"
  case "${3:-}" in
    --* | "") : ;;
    *)
      # An explicit repo identity (e.g. the owner/repo parsed from a `gh api`
      # path) overrides the cwd identity; derive its visibility from the name so
      # a cross-repo write can be told apart from the cwd repo's visibility.
      name="$3"
      case "$name" in
        *pub*) vis=PUBLIC ;;
        *priv*) vis=PRIVATE ;;
      esac
      ;;
  esac
  printf '%s\t%s' "$name" "$vis"
fi
EOF
chmod +x "$BIN/gh"

state="$TMPHOME/.claude/state"

# === mark-review.sh ===
M="hooks/mark-review.sh"
run_mark() { # agent_type sid
  jq -nc --arg t "$1" --arg s "$2" \
    '{hook_event_name:"SubagentStop",agent_type:$t,session_id:$s}' |
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

# Another hook event is ignored even with a review-shaped payload -- a marker
# must mean a review subagent COMPLETED, not that one was merely spawned.
jq -nc '{hook_event_name:"PostToolUse",tool_name:"Agent",tool_input:{subagent_type:"code-reviewer"},session_id:"M7"}' |
  HOME="$TMPHOME" bash "$M" >/dev/null 2>&1
[ -f "$state/review-standard-M7" ] && fail_msg "M: non-SubagentStop event wrote a marker"

# session_id with path traversal is sanitized into the state dir.
run_mark 'code-reviewer' '../evil'
[ -f "$state/review-standard-___evil" ] || fail_msg "M: did not sanitize sid into state dir"
[ ! -e "$TMPHOME/.claude/evil" ] || fail_msg "M: unsanitized sid escaped state dir"

# === gate-public-review.sh ===
G="hooks/gate-public-review.sh"
G_RC=0
_g_out="$(mktemp "$TMPHOME/g_out.XXXXXX")"
run_gate() { # cmd sid visibility [fake_repo]
  jq -nc --arg c "$1" --arg s "$2" \
    '{tool_name:"Bash",tool_input:{command:$c},session_id:$s}' |
    HOME="$TMPHOME" PATH="$BIN:$PATH" FAKE_VISIBILITY="$3" FAKE_REPO="${4:-cwd/repo}" \
      bash "$G" >"$_g_out" 2>&1
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

# gh api with a field flag but no -X implies a POST -> write -> blocked.
run_gate 'gh api /repos/o/r/issues -f title=x' G11b PUBLIC
[ "$G_RC" = 2 ] || fail_msg "G: gh api -f to /issues (implied POST) should block"

# gh api with -X glued to the method (-XPOST) -> write -> blocked.
run_gate 'gh api -XPOST /repos/o/r/issues -f title=x' G11c PUBLIC
[ "$G_RC" = 2 ] || fail_msg "G: gh api -XPOST (glued) to /issues should block"

# gh api graphql mutation payload -> write -> blocked.
run_gate "gh api graphql -f query='mutation{addComment(input:{}){clientMutationId}}'" G11d PUBLIC
[ "$G_RC" = 2 ] || fail_msg "G: gh api graphql mutation should block"

# gh api graphql read query (no mutation) -> not gated.
run_gate "gh api graphql -f query='query{repository(owner:\"o\"){id}}'" G11e PUBLIC
[ "$G_RC" = 0 ] || fail_msg "G: gh api graphql read query should not be gated"

# gh.exe is matched the same as gh.
run_gate 'gh.exe issue create -t x -b y' G11f PUBLIC
[ "$G_RC" = 2 ] || fail_msg "G: gh.exe write should be gated"

# Unresolved visibility (offline) fails closed and says so.
run_gate 'gh issue create -t x -b y' G12 ''
[ "$G_RC" = 2 ] || fail_msg "G: unresolved visibility should fail closed (exit 2)"
grep -q 'could not be confirmed' "$_g_out" || fail_msg "G: unresolved-visibility message should note the failure"

# jq unavailable -> gate fails closed (cannot parse input -> exit 2).
JQLESS="$(mktemp -d)"
for tool in bash cat sed grep find printf chmod head tr; do
  ln -s "$(command -v "$tool")" "$JQLESS/$tool" 2>/dev/null || true
done
jq -nc '{tool_name:"Bash",tool_input:{command:"gh issue create -t x"},session_id:"G14"}' |
  HOME="$TMPHOME" PATH="$JQLESS" bash "$G" >"$_g_out" 2>&1
G_RC=$?
rm -rf "$JQLESS"
[ "$G_RC" = 2 ] || fail_msg "G: missing jq should fail closed (exit 2)"
grep -q 'jq unavailable' "$_g_out" || fail_msg "G: jq-missing message should name jq"

# Cache helps only when resolution fails: a cached PRIVATE verdict for an identity
# is reused on a later offline call for the SAME identity.
run_gate 'gh issue comment 1 -b hi' G13 PRIVATE priv/repo
[ "$G_RC" = 0 ] || fail_msg "G: first private resolution should allow"
run_gate 'gh issue create -t x -b y' G13 '' priv/repo
[ "$G_RC" = 0 ] || fail_msg "G: cached private identity should stay exempt when offline"

# #128/C1 fix: `gh api` carries its target repo in the URL path, not a --repo
# flag. A write to a PUBLIC repo issued from inside a PRIVATE checkout must
# resolve visibility from the api path (PUBLIC -> block), not from the private
# cwd (which would fail open and let the write out unreviewed).
run_gate 'gh api -X POST /repos/pubowner/pubrepo/issues -f title=x' C1 PRIVATE priv/repo
[ "$G_RC" = 2 ] || fail_msg "C1: gh api write to a public path repo from a private cwd must block"
# Symmetric: when the api path names a PRIVATE repo, the write stays exempt even
# though the cwd repo is public -- proving the path repo, not cwd, is resolved.
run_gate 'gh api -X POST /repos/privowner/privrepo/issues -f title=x' C1b PUBLIC pub/repo
[ "$G_RC" = 0 ] || fail_msg "C1b: gh api write to a private path repo should be exempt"

# #7 fix: a PRIVATE verdict must NOT leak to a different (public) repo identity.
# cd-ing from a private to a public repo re-resolves and blocks.
run_gate 'gh issue comment 1 -b hi' G15 PRIVATE priv/repo
[ "$G_RC" = 0 ] || fail_msg "G: private repo identity should allow"
run_gate 'gh issue create -t x -b y' G15 PUBLIC pub/repo
[ "$G_RC" = 2 ] || fail_msg "G: stale private cache must not exempt a different public repo"

echo "public-review-gate: checks ran"
[ "$fail" -eq 0 ] || {
  echo "FAILED: $fail check(s)" >&2
  exit 1
}
echo "ALL PUBLIC-REVIEW-GATE TESTS PASSED"
