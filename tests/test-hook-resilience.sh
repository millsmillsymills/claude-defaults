#!/usr/bin/env bash
set -euo pipefail

# Tests for the missing-hook safety net: run-hook.sh (runtime wrapper) and
# doctor.sh prune/repair (between-session). All run against a temp HOME so the
# real ~/.claude is never touched.

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"

TMP_HOME="$(mktemp -d)"
trap 'rm -rf "$TMP_HOME"' EXIT
export HOME="$TMP_HOME"
CLAUDE_DIR="${TMP_HOME}/.claude"

pass() { echo "PASS: $1"; }
fail() {
  echo "FAIL: $1" >&2
  exit 1
}

# Install into the temp HOME so run-hook.sh resolves its repo dir and the
# installed symlinks exist.
"${REPO_DIR}/scripts/install.sh" hooks >/dev/null 2>&1
WRAP="${CLAUDE_DIR}/hooks/run-hook.sh"
[ -x "$WRAP" ] || [ -L "$WRAP" ] || fail "run-hook.sh not installed"

# --- Test 1: missing hook fails open (exit 0, warns on stderr) ---
out=$(echo '{}' | bash "$WRAP" no-such-hook.sh 2>&1) && rc=0 || rc=$?
[ "$rc" = "0" ] || fail "missing hook returned $rc (want 0)"
echo "$out" | grep -q "not found" || fail "missing hook did not warn"
pass "missing hook fails open with warning"

# --- Test 2: no hook name fails open (exit 0) ---
bash "$WRAP" </dev/null >/dev/null 2>&1 && rc=0 || rc=$?
[ "$rc" = "0" ] || fail "no-args wrapper returned $rc (want 0)"
pass "no hook name fails open"

# --- Test 3: blocking .py hook propagates exit 2 (python3 dispatch) ---
echo '{"tool_input":{"command":"rm -rf /"}}' | bash "$WRAP" safety-block.py >/dev/null 2>&1 && rc=0 || rc=$?
[ "$rc" = "2" ] || fail "safety-block.py via wrapper returned $rc (want 2)"
pass "blocking .py hook propagates exit 2"

# --- Test 4: safe command passes through (exit 0) ---
echo '{"tool_input":{"command":"ls -la"}}' | bash "$WRAP" safety-block.py >/dev/null 2>&1 && rc=0 || rc=$?
[ "$rc" = "0" ] || fail "safe command via wrapper returned $rc (want 0)"
pass "safe command passes through"

# --- Test 5: a second blocking .py hook propagates exit 2 via the wrapper ---
echo '{"tool_input":{"command":"rm -rf /tmp/x"}}' | bash "$WRAP" block-rm-rf.py >/dev/null 2>&1 && rc=0 || rc=$?
[ "$rc" = "2" ] || fail "block-rm-rf.py via wrapper returned $rc (want 2)"
pass "blocking .py hook propagates exit 2 (block-rm-rf)"

# --- Test 6: wrapper still runs the hook when the installed link is missing,
#             WITHOUT mutating the install (link repair is doctor's job) ---
rm -f "${CLAUDE_DIR}/hooks/safety-block.py"
[ -e "${CLAUDE_DIR}/hooks/safety-block.py" ] && fail "precondition: link still present"
echo '{"tool_input":{"command":"rm -rf /"}}' | bash "$WRAP" safety-block.py >/dev/null 2>&1 && rc=0 || rc=$?
[ "$rc" = "2" ] || fail "wrapper did not run repo hook when link missing (rc=$rc, want 2)"
[ -e "${CLAUDE_DIR}/hooks/safety-block.py" ] && fail "wrapper recreated the link (should leave repair to doctor)"
pass "wrapper runs repo hook when link missing, without relinking"

# --- Test 7: doctor --quick recreates the missing security symlink ---
bash "${REPO_DIR}/scripts/doctor.sh" --quick >/dev/null 2>&1 || true
[ -L "${CLAUDE_DIR}/hooks/safety-block.py" ] || fail "doctor did not recreate missing symlink"
pass "doctor recreates missing symlink"

# --- Test 8: a security .py hook with python3 unavailable logs a durable skip ---
# Build a PATH dir with the utils the wrapper needs (bash, mkdir, date, readlink,
# dirname) but deliberately NOT python3, so `command -v python3` fails and the
# security-skip branch fires. An empty PATH would break bash itself (exit 127).
rm -f "${CLAUDE_DIR}/logs/hook-errors.log"
nopy_bin="$(mktemp -d)"
for u in bash mkdir date readlink dirname; do
  src="$(command -v "$u")" && ln -s "$src" "${nopy_bin}/${u}"
done
out=$(echo '{}' | PATH="$nopy_bin" "${nopy_bin}/bash" "$WRAP" safety-block.py 2>&1) && rc=0 || rc=$?
rm -rf "$nopy_bin"
[ "$rc" = "0" ] || fail "python3-missing security hook returned $rc (want 0)"
echo "$out" | grep -q "SECURITY hook" || fail "no stderr warning on security skip"
grep -q "safety-block.py" "${CLAUDE_DIR}/logs/hook-errors.log" 2>/dev/null ||
  fail "security skip not recorded in hook-errors.log"
pass "security hook skip is logged durably and warned"

# --- Test 9: doctor --quick prunes a dangling repo-pointing symlink ---
ln -s "${REPO_DIR}/hooks/renamed-away.sh" "${CLAUDE_DIR}/hooks/renamed-away.sh"
[ -L "${CLAUDE_DIR}/hooks/renamed-away.sh" ] || fail "precondition: dangling link not created"
bash "${REPO_DIR}/scripts/doctor.sh" --quick >/dev/null 2>&1 || true
[ -L "${CLAUDE_DIR}/hooks/renamed-away.sh" ] && fail "doctor did not prune dangling repo symlink"
pass "doctor prunes dangling repo-pointing symlink"

# --- Test 10: doctor leaves a foreign (non-repo) dangling symlink untouched ---
ln -s "/nonexistent/foreign/target.sh" "${CLAUDE_DIR}/hooks/foreign.sh"
bash "${REPO_DIR}/scripts/doctor.sh" --quick >/dev/null 2>&1 || true
[ -L "${CLAUDE_DIR}/hooks/foreign.sh" ] || fail "doctor pruned a foreign symlink it should have left"
pass "doctor leaves foreign dangling symlink untouched"

# --- Test 11: doctor default (non-quick) collapses duplicated hook groups ---
"${REPO_DIR}/scripts/install.sh" settings >/dev/null 2>&1
dup_before=$(jq '[.hooks.PreToolUse[]] | length' "${CLAUDE_DIR}/settings.json")
# Inject a duplicate PreToolUse group to simulate the pre-fix drift.
jq '.hooks.PreToolUse += [.hooks.PreToolUse[0]]' "${CLAUDE_DIR}/settings.json" >"${CLAUDE_DIR}/settings.tmp"
mv "${CLAUDE_DIR}/settings.tmp" "${CLAUDE_DIR}/settings.json"
dup_after=$(jq '[.hooks.PreToolUse[]] | length' "${CLAUDE_DIR}/settings.json")
[ "$dup_after" -gt "$dup_before" ] || fail "precondition: duplicate not injected"
bash "${REPO_DIR}/scripts/doctor.sh" >/dev/null 2>&1 || true
collapsed=$(jq '[.hooks.PreToolUse[]] | length' "${CLAUDE_DIR}/settings.json")
[ "$collapsed" = "$dup_before" ] || fail "doctor did not collapse duplicate groups ($collapsed != $dup_before)"
pass "doctor default re-merge collapses duplicated hook groups"

echo ""
echo "test-hook-resilience.sh: all tests passed"
