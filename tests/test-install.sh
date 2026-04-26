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

if [ "$fail" -eq 0 ]; then
    echo "test-install: PASS"
else
    echo "test-install: $fail FAILURE(S)"
    exit 1
fi
