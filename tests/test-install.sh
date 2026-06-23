#!/usr/bin/env bash
# Roundtrip test: isolated $HOME, install, validate, uninstall.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

REPO_DIR="$(pwd)"
TEST_HOME=$(mktemp -d -t claude-defaults-test.XXXXXX)
trap 'rm -rf "$TEST_HOME"' EXIT
export HOME="$TEST_HOME"
mkdir -p "$TEST_HOME/.claude"

# Pre-existing settings.json (machine-specific entries that must survive)
cat >"$TEST_HOME/.claude/settings.json" <<'PRE'
{
  "$schema": "https://json.schemastore.org/claude-code-settings.json",
  "enabledPlugins": {"foo@bar": true, "baz@qux": false},
  "skipAutoPermissionPrompt": true
}
PRE

# Pre-existing skill (must survive)
mkdir -p "$TEST_HOME/.claude/skills/legacy-skill"
echo "# legacy" >"$TEST_HOME/.claude/skills/legacy-skill/SKILL.md"

fail=0
fail_msg() {
  echo "FAIL: $1" >&2
  fail=$((fail + 1))
}

# Run installer
bash "$REPO_DIR/scripts/install.sh" >/dev/null || fail_msg "install.sh exited non-zero"

# Run validator
bash "$REPO_DIR/scripts/validate.sh" >/dev/null || fail_msg "validate.sh failed after install"

# enabledPlugins preserved
got=$(jq -r '.enabledPlugins."foo@bar"' "$TEST_HOME/.claude/settings.json")
[ "$got" = "true" ] || fail_msg "enabledPlugins.foo@bar=$got (expected true)"

# skipAutoPermissionPrompt preserved
got=$(jq -r '.skipAutoPermissionPrompt' "$TEST_HOME/.claude/settings.json")
[ "$got" = "true" ] || fail_msg "skipAutoPermissionPrompt=$got"

# Hooks block merged
got=$(jq '.hooks.PreToolUse | length' "$TEST_HOME/.claude/settings.json")
[ "$got" -ge 3 ] || fail_msg "hooks.PreToolUse has only $got entries (expected >=3)"

# Legacy skill survived
[ -d "$TEST_HOME/.claude/skills/legacy-skill" ] || fail_msg "legacy-skill removed"
[ -L "$TEST_HOME/.claude/skills/legacy-skill" ] && fail_msg "legacy-skill became symlink"

# Backup created
ls -d "$TEST_HOME/.claude/backups/pre-claude-defaults-"* >/dev/null 2>&1 || fail_msg "no backup created"

# Idempotent: run install again
bash "$REPO_DIR/scripts/install.sh" >/dev/null || fail_msg "second install.sh exited non-zero"
[ -L "$TEST_HOME/.claude/CLAUDE.md" ] || fail_msg "second install broke CLAUDE.md symlink"

# Uninstall
bash "$REPO_DIR/scripts/uninstall.sh" >/dev/null || fail_msg "uninstall.sh exited non-zero"

# After uninstall: symlinks gone, settings.json restored
[ -L "$TEST_HOME/.claude/CLAUDE.md" ] && fail_msg "CLAUDE.md still symlinked after uninstall"
[ -L "$TEST_HOME/.claude/hooks/safety-block.py" ] && fail_msg "safety-block.py still symlinked"
got=$(jq -r '.hooks // "none"' "$TEST_HOME/.claude/settings.json")
[ "$got" = "none" ] || [ "$got" = "null" ] || fail_msg "settings.json hooks block not removed by uninstall"

# P1-2: User's existing custom hooks survive merge.
TEST_HOME2=$(mktemp -d -t claude-defaults-userhook.XXXXXX)
HOME2_OLD="$HOME"
export HOME="$TEST_HOME2"
mkdir -p "$TEST_HOME2/.claude"
cat >"$TEST_HOME2/.claude/settings.json" <<'PRE'
{
  "$schema": "https://json.schemastore.org/claude-code-settings.json",
  "enabledPlugins": {"foo@bar": true},
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [{"type": "command", "command": "echo MY-CUSTOM-HOOK"}]
      }
    ]
  }
}
PRE

bash "$REPO_DIR/scripts/install.sh" >/dev/null || fail_msg "install with custom hooks exited non-zero"

# User's custom hook must survive the merge
got=$(jq -r '.hooks.PreToolUse[]?.hooks[]?.command // ""' "$TEST_HOME2/.claude/settings.json" | grep -c 'MY-CUSTOM-HOOK')
[ "$got" -ge 1 ] || fail_msg "P1-2: user custom hook lost in merge (count=$got)"

# Repo's hooks must also be present
got=$(jq -r '.hooks.PreToolUse[]?.hooks[]?.command // ""' "$TEST_HOME2/.claude/settings.json" | grep -c 'safety-block.py')
[ "$got" -ge 1 ] || fail_msg "P1-2: repo's safety-block.py missing after merge (count=$got)"

export HOME="$HOME2_OLD"
rm -rf "$TEST_HOME2"

# P1-2b: a user hook under an event the template does NOT define must survive
# the merge untouched (the merge is per-event; only ours-named groups under
# template events are replaced).
TEST_HOME2B=$(mktemp -d -t claude-defaults-userevent.XXXXXX)
export HOME="$TEST_HOME2B"
mkdir -p "$TEST_HOME2B/.claude"
cat >"$TEST_HOME2B/.claude/settings.json" <<'PRE'
{
  "$schema": "https://json.schemastore.org/claude-code-settings.json",
  "hooks": {
    "UserPromptSubmit": [
      {"hooks": [{"type": "command", "command": "echo USER-ONLY-EVENT-HOOK"}]}
    ]
  }
}
PRE
bash "$REPO_DIR/scripts/install.sh" settings >/dev/null || fail_msg "P1-2b: install failed"
got=$(jq -r '.hooks.UserPromptSubmit[]?.hooks[]?.command // ""' "$TEST_HOME2B/.claude/settings.json" | grep -c 'USER-ONLY-EVENT-HOOK')
[ "$got" -ge 1 ] || fail_msg "P1-2b: user-only-event hook lost in merge (count=$got)"
got=$(jq -r '.hooks.PreToolUse[]?.hooks[]?.command // ""' "$TEST_HOME2B/.claude/settings.json" | grep -c 'safety-block.py')
[ "$got" -ge 1 ] || fail_msg "P1-2b: template hooks missing after merge (count=$got)"
export HOME="$HOME2_OLD"
rm -rf "$TEST_HOME2B"

# H8: re-running with --force must not duplicate hook blocks.
TEST_HOME3=$(mktemp -d -t claude-defaults-force.XXXXXX)
export HOME="$TEST_HOME3"
mkdir -p "$TEST_HOME3/.claude"
bash "$REPO_DIR/scripts/install.sh" settings >/dev/null || fail_msg "H8: first settings install failed"
n1=$(jq '.hooks.PreToolUse | length' "$TEST_HOME3/.claude/settings.json")
bash "$REPO_DIR/scripts/install.sh" --force settings >/dev/null || fail_msg "H8: --force settings failed"
n2=$(jq '.hooks.PreToolUse | length' "$TEST_HOME3/.claude/settings.json")
[ "$n1" = "$n2" ] || fail_msg "H8: PreToolUse grew $n1 -> $n2 on --force re-merge"
export HOME="$HOME2_OLD"
rm -rf "$TEST_HOME3"

# M4: a symlinked settings.json must be merged, not discarded.
TEST_HOME4=$(mktemp -d -t claude-defaults-symlink.XXXXXX)
export HOME="$TEST_HOME4"
mkdir -p "$TEST_HOME4/.claude"
cat >"$TEST_HOME4/real-settings.json" <<'PRE'
{"enabledPlugins":{"x@y":true},"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"echo SYMLINK-CUSTOM-HOOK"}]}]}}
PRE
ln -s "$TEST_HOME4/real-settings.json" "$TEST_HOME4/.claude/settings.json"
bash "$REPO_DIR/scripts/install.sh" settings >/dev/null || fail_msg "M4: install with symlinked settings failed"
[ -L "$TEST_HOME4/.claude/settings.json" ] && fail_msg "M4: settings.json still a symlink after install"
got=$(jq -r '.hooks.PreToolUse[]?.hooks[]?.command // ""' "$TEST_HOME4/.claude/settings.json" | grep -c 'SYMLINK-CUSTOM-HOOK')
[ "$got" -ge 1 ] || fail_msg "M4: symlinked user settings discarded (custom hook count=$got)"
got=$(jq -r '.hooks.PreToolUse[]?.hooks[]?.command // ""' "$TEST_HOME4/.claude/settings.json" | grep -c 'safety-block.py')
[ "$got" -ge 1 ] || fail_msg "M4: template hooks missing after symlink merge (count=$got)"
export HOME="$HOME2_OLD"
rm -rf "$TEST_HOME4"

# M9: --force overwrite of ~/.mcp.json must back up the existing file first.
TEST_HOME5=$(mktemp -d -t claude-defaults-mcp.XXXXXX)
export HOME="$TEST_HOME5"
mkdir -p "$TEST_HOME5/.claude"
echo '{"mcpServers":{"mine":{"command":"foo"}}}' >"$TEST_HOME5/.mcp.json"
bash "$REPO_DIR/scripts/install.sh" --force mcp >/dev/null || fail_msg "M9: --force mcp failed"
mcp_backup=$(cat "$TEST_HOME5/.claude/backups/pre-claude-defaults-"*/mcp.json 2>/dev/null | grep -c 'mine' || true)
[ "$mcp_backup" -ge 1 ] || fail_msg "M9: existing ~/.mcp.json not backed up before --force overwrite"
export HOME="$HOME2_OLD"
rm -rf "$TEST_HOME5"

# #117: --force mcp through a SYMLINKED ~/.mcp.json must not write through the
# link and clobber its target; it backs up the target, then replaces the link
# with a fresh real file.
TEST_HOME5B=$(mktemp -d -t claude-defaults-mcpsym.XXXXXX)
export HOME="$TEST_HOME5B"
mkdir -p "$TEST_HOME5B/.claude"
echo '{"mcpServers":{"precious":{"command":"keep"}}}' >"$TEST_HOME5B/precious.json"
ln -s "$TEST_HOME5B/precious.json" "$TEST_HOME5B/.mcp.json"
bash "$REPO_DIR/scripts/install.sh" --force mcp >/dev/null || fail_msg "#117: --force mcp over symlink failed"
got=$(jq -r '.mcpServers.precious.command // ""' "$TEST_HOME5B/precious.json" 2>/dev/null)
[ "$got" = "keep" ] || fail_msg "#117: symlink target was clobbered (got=$got)"
[ -L "$TEST_HOME5B/.mcp.json" ] && fail_msg "#117: ~/.mcp.json still a symlink after --force"
[ -f "$TEST_HOME5B/.mcp.json" ] || fail_msg "#117: ~/.mcp.json not created as a real file"
bk=$(cat "$TEST_HOME5B/.claude/backups/pre-claude-defaults-"*/mcp.json 2>/dev/null | grep -c 'precious' || true)
[ "$bk" -ge 1 ] || fail_msg "#117: symlink target content not backed up"
export HOME="$HOME2_OLD"
rm -rf "$TEST_HOME5B"

# #127: mcp WITHOUT --force over a DANGLING ~/.mcp.json symlink must skip. `-f`
# follows the link and reads false for a dead target, so the early guard must
# also test `-L`; otherwise the symlink-replacement block destructively replaces
# the link without --force.
TEST_HOME5C=$(mktemp -d -t claude-defaults-mcpdangle.XXXXXX)
export HOME="$TEST_HOME5C"
mkdir -p "$TEST_HOME5C/.claude"
ln -s "$TEST_HOME5C/does-not-exist.json" "$TEST_HOME5C/.mcp.json"
bash "$REPO_DIR/scripts/install.sh" mcp >/dev/null || fail_msg "#127: mcp over dangling symlink failed"
[ -L "$TEST_HOME5C/.mcp.json" ] || fail_msg "#127: dangling symlink replaced without --force"
[ "$(readlink "$TEST_HOME5C/.mcp.json")" = "$TEST_HOME5C/does-not-exist.json" ] || fail_msg "#127: dangling symlink target changed"
[ -e "$TEST_HOME5C/does-not-exist.json" ] && fail_msg "#127: file written through dangling symlink"
export HOME="$HOME2_OLD"
rm -rf "$TEST_HOME5C"

# M7/M8: uninstall must reverse files install created fresh (no prior backup).
TEST_HOME6=$(mktemp -d -t claude-defaults-reverse.XXXXXX)
export HOME="$TEST_HOME6"
mkdir -p "$TEST_HOME6/.claude"
bash "$REPO_DIR/scripts/install.sh" settings mcp >/dev/null || fail_msg "M7/M8: fresh install failed"
[ -f "$TEST_HOME6/.claude/settings.json" ] || fail_msg "M7: settings.json not created"
[ -f "$TEST_HOME6/.mcp.json" ] || fail_msg "M8: .mcp.json not created"
bash "$REPO_DIR/scripts/uninstall.sh" >/dev/null || fail_msg "M7/M8: uninstall failed"
[ -f "$TEST_HOME6/.claude/settings.json" ] && fail_msg "M7: fresh-created settings.json left behind after uninstall"
[ -f "$TEST_HOME6/.mcp.json" ] && fail_msg "M8: fresh-created ~/.mcp.json left behind after uninstall"
export HOME="$HOME2_OLD"
rm -rf "$TEST_HOME6"

# #39-1: a pre-existing ~/.mcp.json is backed up into the snapshot dir, but
# uninstall must NOT leave a stray ~/.claude/mcp.json behind from restoring it.
TEST_HOME7=$(mktemp -d -t claude-defaults-strayy.XXXXXX)
export HOME="$TEST_HOME7"
mkdir -p "$TEST_HOME7/.claude"
echo '{"mcpServers":{"mine":{"command":"foo"}}}' >"$TEST_HOME7/.mcp.json"
bash "$REPO_DIR/scripts/install.sh" --force mcp settings >/dev/null || fail_msg "#39-1: install failed"
bash "$REPO_DIR/scripts/uninstall.sh" >/dev/null || fail_msg "#39-1: uninstall failed"
[ -e "$TEST_HOME7/.claude/mcp.json" ] && fail_msg "#39-1: stray ~/.claude/mcp.json left after uninstall"
# Original ~/.mcp.json content must be restored, not removed.
got=$(jq -r '.mcpServers.mine.command // ""' "$TEST_HOME7/.mcp.json" 2>/dev/null)
[ "$got" = "foo" ] || fail_msg "#39-1: ~/.mcp.json not restored to original (got=$got)"
export HOME="$HOME2_OLD"
rm -rf "$TEST_HOME7"

# #39-3: a `created` file the user edits post-install must be preserved by
# uninstall (checksum guard), not silently deleted.
TEST_HOME8=$(mktemp -d -t claude-defaults-edited.XXXXXX)
export HOME="$TEST_HOME8"
mkdir -p "$TEST_HOME8/.claude"
bash "$REPO_DIR/scripts/install.sh" mcp >/dev/null || fail_msg "#39-3: install failed"
[ -f "$TEST_HOME8/.mcp.json" ] || fail_msg "#39-3: .mcp.json not created"
echo '{"mcpServers":{"useredit":{"command":"bar"}}}' >"$TEST_HOME8/.mcp.json"
bash "$REPO_DIR/scripts/uninstall.sh" >/dev/null || fail_msg "#39-3: uninstall failed"
[ -f "$TEST_HOME8/.mcp.json" ] || fail_msg "#39-3: user-edited created file deleted by uninstall"
got=$(jq -r '.mcpServers.useredit.command // ""' "$TEST_HOME8/.mcp.json" 2>/dev/null)
[ "$got" = "bar" ] || fail_msg "#39-3: user edit not preserved (got=$got)"
export HOME="$HOME2_OLD"
rm -rf "$TEST_HOME8"

# #17: a --force settings re-run on already-merged settings must not duplicate
# entries under ANY hook event (not just PreToolUse). Covers the dedup intent.
TEST_HOME7=$(mktemp -d -t claude-defaults-dedup.XXXXXX)
export HOME="$TEST_HOME7"
mkdir -p "$TEST_HOME7/.claude"
bash "$REPO_DIR/scripts/install.sh" settings >/dev/null || fail_msg "#17: first settings install failed"
for ev in PreToolUse PostToolUse Stop SessionEnd; do
  before=$(jq "[.hooks.${ev}[]?.hooks[]?] | length" "$TEST_HOME7/.claude/settings.json")
  bash "$REPO_DIR/scripts/install.sh" --force settings >/dev/null || fail_msg "#17: --force settings failed ($ev)"
  after=$(jq "[.hooks.${ev}[]?.hooks[]?] | length" "$TEST_HOME7/.claude/settings.json")
  [ "$before" = "$after" ] || fail_msg "#17: ${ev} hook count grew $before -> $after on --force re-merge"
done
export HOME="$HOME2_OLD"
rm -rf "$TEST_HOME7"

# #71: the idempotency guard is content-aware. A re-run with no change is a
# true no-op (skip, no re-backup); a re-run after the live file drifts from the
# template re-merges and propagates the missing entry.
TEST_HOME8=$(mktemp -d -t claude-defaults-idem.XXXXXX)
export HOME="$TEST_HOME8"
mkdir -p "$TEST_HOME8/.claude"
bash "$REPO_DIR/scripts/install.sh" settings >/dev/null || fail_msg "#71: first settings install failed"

# No-op: re-running without changes skips and creates no new backup.
backup_count() { find "$TEST_HOME8/.claude/backups" -maxdepth 1 -name 'pre-claude-defaults-*' 2>/dev/null | wc -l; }
backups_before=$(backup_count)
cp "$TEST_HOME8/.claude/settings.json" "$TEST_HOME8/before.json"
out=$(bash "$REPO_DIR/scripts/install.sh" settings 2>&1) || fail_msg "#71: no-op re-install failed"
echo "$out" | grep -q "already up to date" || fail_msg "#71: unchanged re-run did not report a no-op skip"
[ "$(backup_count)" = "$backups_before" ] || fail_msg "#71: no-op re-run created a backup"
cmp -s "$TEST_HOME8/before.json" "$TEST_HOME8/.claude/settings.json" || fail_msg "#71: no-op re-run rewrote settings.json"

# Propagate: drop a template deny entry to mimic a stale install predating a
# template addition; a plain re-run must restore it (not silently skip). Guard
# that the template still ships this entry, so the test fails loudly rather than
# silently degrading to a no-op if the template ever drops it.
tmpl_has=$(jq -r '[.permissions.deny[]? | select(. == "Bash(rm -rf *)")] | length' "$REPO_DIR/settings.json")
[ "$tmpl_has" = "1" ] || fail_msg "#71: template no longer ships 'Bash(rm -rf *)'; update the drift test"
jq 'del(.permissions.deny[] | select(. == "Bash(rm -rf *)"))' \
  "$TEST_HOME8/.claude/settings.json" >"$TEST_HOME8/.claude/settings.json.t"
mv "$TEST_HOME8/.claude/settings.json.t" "$TEST_HOME8/.claude/settings.json"
out=$(bash "$REPO_DIR/scripts/install.sh" settings 2>&1) || fail_msg "#71: re-merge after drift failed"
echo "$out" | grep -q "merged settings" || fail_msg "#71: drifted re-run skipped instead of re-merging"
got=$(jq -r '[.permissions.deny[] | select(. == "Bash(rm -rf *)")] | length' "$TEST_HOME8/.claude/settings.json")
[ "$got" = "1" ] || fail_msg "#71: template deny entry not propagated on re-run (count=$got)"
export HOME="$HOME2_OLD"
rm -rf "$TEST_HOME8"

# #42: validate.sh smoke test — fresh install exits 0; a tampered install
# (removed hook symlink) exits non-zero.
TEST_HOME9=$(mktemp -d -t claude-defaults-validate.XXXXXX)
export HOME="$TEST_HOME9"
mkdir -p "$TEST_HOME9/.claude"
bash "$REPO_DIR/scripts/install.sh" >/dev/null || fail_msg "#42: fresh install failed"
bash "$REPO_DIR/scripts/validate.sh" >/dev/null || fail_msg "#42: validate.sh non-zero on fresh install"
rm -f "$TEST_HOME9/.claude/hooks/safety-block.py"
bash "$REPO_DIR/scripts/validate.sh" >/dev/null && fail_msg "#42: validate.sh exited 0 on tampered install"
export HOME="$HOME2_OLD"
rm -rf "$TEST_HOME9"

# #55: a partial restore failure must surface as a non-zero exit, not a
# stderr-only warning automation can't detect. Inject a failure by replacing an
# installed symlink with an unwritable regular file at a path uninstall must
# restore from backup; the restoring cp then fails.
if [ "$(id -u)" -ne 0 ]; then
  TEST_HOME10=$(mktemp -d -t claude-defaults-restorefail.XXXXXX)
  export HOME="$TEST_HOME10"
  mkdir -p "$TEST_HOME10/.claude"
  # Pre-existing real file so install backs it up before symlinking.
  echo "original statusline" >"$TEST_HOME10/.claude/statusline.sh"
  bash "$REPO_DIR/scripts/install.sh" >/dev/null || fail_msg "#55: install failed"
  # Swap the installed symlink for an unwritable file; uninstall's symlink
  # sweep skips non-symlinks, so the restore step hits it and cp fails.
  rm -f "$TEST_HOME10/.claude/statusline.sh"
  echo "blocker" >"$TEST_HOME10/.claude/statusline.sh"
  chmod 000 "$TEST_HOME10/.claude/statusline.sh"
  if bash "$REPO_DIR/scripts/uninstall.sh" >/dev/null 2>&1; then
    fail_msg "#55: uninstall exited 0 despite a failed restore"
  fi
  chmod 644 "$TEST_HOME10/.claude/statusline.sh" 2>/dev/null || true
  export HOME="$HOME2_OLD"
  rm -rf "$TEST_HOME10"
else
  echo "  SKIP #55 restore-failure test (running as root; mode 000 is bypassed)"
fi

# #87-jq: with jq absent, settings install must refuse -- warn, exit 0, and
# create nothing (never clobber existing settings or write a non-canonical
# copy). Build a PATH mirroring the real one minus jq so the in-function guard
# fires while every other tool install.sh needs stays available.
TEST_HOME11=$(mktemp -d -t claude-defaults-nojq.XXXXXX)
export HOME="$TEST_HOME11"
mkdir -p "$TEST_HOME11/.claude"
nojq_bin=$(mktemp -d -t claude-defaults-nojqbin.XXXXXX)
IFS=:
for d in $PATH; do
  [ -d "$d" ] || continue
  for f in "$d"/*; do
    [ -e "$f" ] || continue
    b=$(basename "$f")
    [ "$b" = "jq" ] && continue
    [ -e "$nojq_bin/$b" ] || ln -s "$f" "$nojq_bin/$b" 2>/dev/null
  done
done
unset IFS
out=$(PATH="$nojq_bin" bash "$REPO_DIR/scripts/install.sh" settings 2>&1)
rc=$?
[ "$rc" -eq 0 ] || fail_msg "#87-jq: install exited $rc with jq absent (expected 0)"
echo "$out" | grep -q "cannot install settings" || fail_msg "#87-jq: no refusal warning when jq absent"
[ -e "$TEST_HOME11/.claude/settings.json" ] && fail_msg "#87-jq: settings.json created despite jq absent"
rm -rf "$nojq_bin"
export HOME="$HOME2_OLD"
rm -rf "$TEST_HOME11"

# #87-sym: a symlinked settings.json already byte-identical to its own merge is
# a true no-op -- the link must survive (not be converted to a plain file) and
# no backup is taken. Produce canonical content via a fresh install, then point
# a symlink at it and re-run.
TEST_HOME12=$(mktemp -d -t claude-defaults-symnoop.XXXXXX)
export HOME="$TEST_HOME12"
mkdir -p "$TEST_HOME12/.claude"
bash "$REPO_DIR/scripts/install.sh" settings >/dev/null || fail_msg "#87-sym: seed install failed"
mv "$TEST_HOME12/.claude/settings.json" "$TEST_HOME12/.claude/real-settings.json"
ln -s "$TEST_HOME12/.claude/real-settings.json" "$TEST_HOME12/.claude/settings.json"
sym_before=$(find "$TEST_HOME12/.claude/backups" -maxdepth 1 -name 'pre-claude-defaults-*' 2>/dev/null | wc -l)
out=$(bash "$REPO_DIR/scripts/install.sh" settings 2>&1) || fail_msg "#87-sym: re-install over symlink failed"
echo "$out" | grep -q "already up to date" || fail_msg "#87-sym: up-to-date symlink did not skip as a no-op"
[ -L "$TEST_HOME12/.claude/settings.json" ] || fail_msg "#87-sym: no-op converted the symlink into a plain file"
sym_after=$(find "$TEST_HOME12/.claude/backups" -maxdepth 1 -name 'pre-claude-defaults-*' 2>/dev/null | wc -l)
[ "$sym_before" = "$sym_after" ] || fail_msg "#87-sym: no-op symlink re-run created a backup"
export HOME="$HOME2_OLD"
rm -rf "$TEST_HOME12"

# #87-stop: a stale install carrying only the prompt-type Stop hook must not
# duplicate it on re-merge -- the unique collapse keeps the Stop group at one.
TEST_HOME13=$(mktemp -d -t claude-defaults-stopdedup.XXXXXX)
export HOME="$TEST_HOME13"
mkdir -p "$TEST_HOME13/.claude"
jq '{hooks: {Stop: .hooks.Stop}}' "$REPO_DIR/settings.json" >"$TEST_HOME13/.claude/settings.json"
bash "$REPO_DIR/scripts/install.sh" settings >/dev/null || fail_msg "#87-stop: install over Stop-only settings failed"
got=$(jq '[.hooks.Stop[]?] | length' "$TEST_HOME13/.claude/settings.json")
[ "$got" = "1" ] || fail_msg "#87-stop: Stop hook group duplicated on re-merge (count=$got)"
export HOME="$HOME2_OLD"
rm -rf "$TEST_HOME13"

# #87-force: --force over a byte-identical file must still take the rewrite path
# (backup + "merged settings"), never the content-aware skip, and must not
# duplicate entries.
TEST_HOME14=$(mktemp -d -t claude-defaults-forcenoop.XXXXXX)
export HOME="$TEST_HOME14"
mkdir -p "$TEST_HOME14/.claude"
bash "$REPO_DIR/scripts/install.sh" settings >/dev/null || fail_msg "#87-force: seed install failed"
before=$(jq '[.hooks.PreToolUse[]?.hooks[]?] | length' "$TEST_HOME14/.claude/settings.json")
out=$(bash "$REPO_DIR/scripts/install.sh" --force settings 2>&1) || fail_msg "#87-force: --force re-install failed"
echo "$out" | grep -q "merged settings" || fail_msg "#87-force: --force on identical file skipped instead of rewriting"
echo "$out" | grep -q "already up to date" && fail_msg "#87-force: --force took the no-op skip path"
ls -d "$TEST_HOME14/.claude/backups/pre-claude-defaults-"* >/dev/null 2>&1 || fail_msg "#87-force: --force rewrite created no backup"
after=$(jq '[.hooks.PreToolUse[]?.hooks[]?] | length' "$TEST_HOME14/.claude/settings.json")
[ "$before" = "$after" ] || fail_msg "#87-force: PreToolUse entries grew $before -> $after under --force"
export HOME="$HOME2_OLD"
rm -rf "$TEST_HOME14"

if [ "$fail" -eq 0 ]; then
  echo "test-install: PASS"
else
  echo "test-install: $fail FAILURE(S)"
  exit 1
fi
