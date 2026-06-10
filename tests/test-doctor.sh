#!/usr/bin/env bash
# doctor.sh idempotency: on an up-to-date install, a default `doctor.sh` run
# must make no change -- no settings.json rewrite and no new backup dir.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

REPO_DIR="$(pwd)"
TEST_HOME=$(mktemp -d -t claude-defaults-doctor.XXXXXX)
trap 'rm -rf "$TEST_HOME"' EXIT
export HOME="$TEST_HOME"
mkdir -p "$TEST_HOME/.claude"

fail=0
fail_msg() {
  echo "FAIL: $1" >&2
  fail=$((fail + 1))
}

backup_count() {
  find "$TEST_HOME/.claude/backups" -maxdepth 1 -name 'pre-claude-defaults-*' 2>/dev/null | wc -l
}

# Fresh install: settings.json lands in canonical (re-merge-stable) form.
bash "$REPO_DIR/scripts/install.sh" >/dev/null || fail_msg "install.sh exited non-zero"

# #96: a default doctor run on an unchanged install rewrites nothing and backs
# up nothing -- the settings re-merge must take the content-aware no-op skip.
cp "$TEST_HOME/.claude/settings.json" "$TEST_HOME/before.json"
backups_before=$(backup_count)
out=$(bash "$REPO_DIR/scripts/doctor.sh" 2>&1) || fail_msg "#96: doctor.sh exited non-zero"
echo "$out" | grep -q "already up to date" || fail_msg "#96: doctor settings re-merge did not report a no-op skip"
cmp -s "$TEST_HOME/before.json" "$TEST_HOME/.claude/settings.json" || fail_msg "#96: doctor rewrote settings.json on an unchanged install"
[ "$(backup_count)" = "$backups_before" ] || fail_msg "#96: doctor created a backup on an unchanged install"

# Second run accumulates nothing either -- backups stay flat across runs.
bash "$REPO_DIR/scripts/doctor.sh" >/dev/null 2>&1 || fail_msg "#96: second doctor.sh exited non-zero"
[ "$(backup_count)" = "$backups_before" ] || fail_msg "#96: a repeat doctor run created another backup"

# Drift still re-merges: drop a template deny entry, doctor must restore it.
tmpl_has=$(jq -r '[.permissions.deny[]? | select(. == "Bash(rm -rf *)")] | length' "$REPO_DIR/settings.json")
[ "$tmpl_has" = "1" ] || fail_msg "#96: template no longer ships 'Bash(rm -rf *)'; update the drift test"
jq 'del(.permissions.deny[] | select(. == "Bash(rm -rf *)"))' \
  "$TEST_HOME/.claude/settings.json" >"$TEST_HOME/.claude/settings.json.t"
mv "$TEST_HOME/.claude/settings.json.t" "$TEST_HOME/.claude/settings.json"
bash "$REPO_DIR/scripts/doctor.sh" >/dev/null 2>&1 || fail_msg "#96: doctor.sh after drift exited non-zero"
got=$(jq -r '[.permissions.deny[] | select(. == "Bash(rm -rf *)")] | length' "$TEST_HOME/.claude/settings.json")
[ "$got" = "1" ] || fail_msg "#96: doctor did not re-merge drifted settings (count=$got)"

# --quick must never touch settings.json (startup path stays cheap and silent).
cp "$TEST_HOME/.claude/settings.json" "$TEST_HOME/before-quick.json"
backups_before=$(backup_count)
bash "$REPO_DIR/scripts/doctor.sh" --quick >/dev/null 2>&1 || fail_msg "#96: doctor.sh --quick exited non-zero"
cmp -s "$TEST_HOME/before-quick.json" "$TEST_HOME/.claude/settings.json" || fail_msg "#96: --quick rewrote settings.json"
[ "$(backup_count)" = "$backups_before" ] || fail_msg "#96: --quick created a backup"

if [ "$fail" -eq 0 ]; then
  echo "test-doctor: PASS"
else
  echo "test-doctor: $fail FAILURE(S)"
  exit 1
fi
