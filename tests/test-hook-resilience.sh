#!/usr/bin/env bash
set -euo pipefail

# Tests for the missing-hook safety net: run-hook.sh (runtime wrapper) and
# doctor.sh prune (between-session repair). All run against a temp HOME so the
# real ~/.claude is never touched.
#
# Covers:
#   - run-hook.sh fails OPEN (exit 0) when the named hook is absent
#   - run-hook.sh propagates a blocking hook's exit 2
#   - run-hook.sh re-creates a missing installed symlink from the repo copy
#   - run-hook.sh runs .py hooks via python3 and .sh hooks via bash
#   - doctor.sh --quick prunes a dangling repo-pointing symlink
#   - doctor.sh leaves a foreign (non-repo) dangling symlink untouched

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

# --- Test 2: blocking hook propagates exit 2 ---
echo '{"tool_input":{"command":"rm -rf /"}}' | bash "$WRAP" safety-block.py >/dev/null 2>&1 && rc=0 || rc=$?
[ "$rc" = "2" ] || fail "safety-block.py via wrapper returned $rc (want 2)"
pass "blocking hook propagates exit 2"

# --- Test 3: safe command passes through (exit 0) ---
echo '{"tool_input":{"command":"ls -la"}}' | bash "$WRAP" safety-block.py >/dev/null 2>&1 && rc=0 || rc=$?
[ "$rc" = "0" ] || fail "safe command via wrapper returned $rc (want 0)"
pass "safe command passes through"

# --- Test 4: wrapper recreates a missing installed symlink ---
rm -f "${CLAUDE_DIR}/hooks/safety-block.py"
[ -e "${CLAUDE_DIR}/hooks/safety-block.py" ] && fail "precondition: symlink still present"
echo '{"tool_input":{"command":"ls"}}' | bash "$WRAP" safety-block.py >/dev/null 2>&1 || true
[ -L "${CLAUDE_DIR}/hooks/safety-block.py" ] || fail "wrapper did not recreate the missing symlink"
pass "wrapper recreates a missing installed symlink"

# --- Test 5: doctor --quick prunes a dangling repo-pointing symlink ---
ln -s "${REPO_DIR}/hooks/renamed-away.sh" "${CLAUDE_DIR}/hooks/renamed-away.sh"
[ -L "${CLAUDE_DIR}/hooks/renamed-away.sh" ] || fail "precondition: dangling link not created"
bash "${REPO_DIR}/scripts/doctor.sh" --quick >/dev/null 2>&1 || true
[ -L "${CLAUDE_DIR}/hooks/renamed-away.sh" ] && fail "doctor did not prune dangling repo symlink"
pass "doctor prunes dangling repo-pointing symlink"

# --- Test 6: doctor leaves a foreign dangling symlink untouched ---
ln -s "/nonexistent/foreign/target.sh" "${CLAUDE_DIR}/hooks/foreign.sh"
bash "${REPO_DIR}/scripts/doctor.sh" --quick >/dev/null 2>&1 || true
[ -L "${CLAUDE_DIR}/hooks/foreign.sh" ] || fail "doctor pruned a foreign symlink it should have left"
pass "doctor leaves foreign dangling symlink untouched"

echo ""
echo "test-hook-resilience.sh: all tests passed"
