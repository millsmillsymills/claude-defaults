#!/usr/bin/env bash
# Roundtrip test: isolated $HOME, install, validate, uninstall.
set -uo pipefail
cd "$(dirname "$0")/.."

REPO_DIR="$(pwd)"
TEST_HOME=$(mktemp -d -t claude-defaults-test.XXXXXX)
trap "rm -rf $TEST_HOME" EXIT
export HOME="$TEST_HOME"
mkdir -p "$TEST_HOME/.claude"

# Pre-existing settings.json (machine-specific entries that must survive)
cat > "$TEST_HOME/.claude/settings.json" <<'PRE'
{
  "$schema": "https://json.schemastore.org/claude-code-settings.json",
  "enabledPlugins": {"foo@bar": true, "baz@qux": false},
  "skipAutoPermissionPrompt": true
}
PRE

# Pre-existing skill (must survive)
mkdir -p "$TEST_HOME/.claude/skills/legacy-skill"
echo "# legacy" > "$TEST_HOME/.claude/skills/legacy-skill/SKILL.md"

fail=0
fail_msg() { echo "FAIL: $1" >&2; fail=$((fail+1)); }

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
[ -L "$TEST_HOME/.claude/hooks/safety-block.sh" ] && fail_msg "safety-block.sh still symlinked"
got=$(jq -r '.hooks // "none"' "$TEST_HOME/.claude/settings.json")
[ "$got" = "none" ] || [ "$got" = "null" ] || fail_msg "settings.json hooks block not removed by uninstall"

# P1-2: User's existing custom hooks survive merge.
TEST_HOME2=$(mktemp -d -t claude-defaults-userhook.XXXXXX)
HOME2_OLD="$HOME"
export HOME="$TEST_HOME2"
mkdir -p "$TEST_HOME2/.claude"
cat > "$TEST_HOME2/.claude/settings.json" <<'PRE'
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
got=$(jq -r '.hooks.PreToolUse[]?.hooks[]?.command // ""' "$TEST_HOME2/.claude/settings.json" | grep -c 'safety-block.sh')
[ "$got" -ge 1 ] || fail_msg "P1-2: repo's safety-block.sh missing after merge (count=$got)"

export HOME="$HOME2_OLD"
rm -rf "$TEST_HOME2"

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
cat > "$TEST_HOME4/real-settings.json" <<'PRE'
{"enabledPlugins":{"x@y":true},"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"echo SYMLINK-CUSTOM-HOOK"}]}]}}
PRE
ln -s "$TEST_HOME4/real-settings.json" "$TEST_HOME4/.claude/settings.json"
bash "$REPO_DIR/scripts/install.sh" settings >/dev/null || fail_msg "M4: install with symlinked settings failed"
[ -L "$TEST_HOME4/.claude/settings.json" ] && fail_msg "M4: settings.json still a symlink after install"
got=$(jq -r '.hooks.PreToolUse[]?.hooks[]?.command // ""' "$TEST_HOME4/.claude/settings.json" | grep -c 'SYMLINK-CUSTOM-HOOK')
[ "$got" -ge 1 ] || fail_msg "M4: symlinked user settings discarded (custom hook count=$got)"
got=$(jq -r '.hooks.PreToolUse[]?.hooks[]?.command // ""' "$TEST_HOME4/.claude/settings.json" | grep -c 'safety-block.sh')
[ "$got" -ge 1 ] || fail_msg "M4: template hooks missing after symlink merge (count=$got)"
export HOME="$HOME2_OLD"
rm -rf "$TEST_HOME4"

# M9: --force overwrite of ~/.mcp.json must back up the existing file first.
TEST_HOME5=$(mktemp -d -t claude-defaults-mcp.XXXXXX)
export HOME="$TEST_HOME5"
mkdir -p "$TEST_HOME5/.claude"
echo '{"mcpServers":{"mine":{"command":"foo"}}}' > "$TEST_HOME5/.mcp.json"
bash "$REPO_DIR/scripts/install.sh" --force mcp >/dev/null || fail_msg "M9: --force mcp failed"
mcp_backup=$(cat "$TEST_HOME5/.claude/backups/pre-claude-defaults-"*/mcp.json 2>/dev/null | grep -c 'mine' || true)
[ "$mcp_backup" -ge 1 ] || fail_msg "M9: existing ~/.mcp.json not backed up before --force overwrite"
export HOME="$HOME2_OLD"
rm -rf "$TEST_HOME5"

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
echo '{"mcpServers":{"mine":{"command":"foo"}}}' > "$TEST_HOME7/.mcp.json"
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
echo '{"mcpServers":{"useredit":{"command":"bar"}}}' > "$TEST_HOME8/.mcp.json"
bash "$REPO_DIR/scripts/uninstall.sh" >/dev/null || fail_msg "#39-3: uninstall failed"
[ -f "$TEST_HOME8/.mcp.json" ] || fail_msg "#39-3: user-edited created file deleted by uninstall"
got=$(jq -r '.mcpServers.useredit.command // ""' "$TEST_HOME8/.mcp.json" 2>/dev/null)
[ "$got" = "bar" ] || fail_msg "#39-3: user edit not preserved (got=$got)"
export HOME="$HOME2_OLD"
rm -rf "$TEST_HOME8"

if [ "$fail" -eq 0 ]; then
    echo "test-install: PASS"
else
    echo "test-install: $fail FAILURE(S)"
    exit 1
fi
