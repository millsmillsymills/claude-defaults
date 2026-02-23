#!/usr/bin/env bash
set -euo pipefail

# Verify claude-defaults installation.
# Checks that all expected files exist, are valid, and have no placeholders.
#
# Usage: ./scripts/validate.sh
# Exit 0 = all checks pass, exit 1 = issues found

errors=0

pass() { printf "  \033[32mOK\033[0m  %s\n" "$1"; }
fail() { printf "  \033[31mFAIL\033[0m  %s\n" "$1"; ((errors++)); }
warn() { printf "  \033[33mWARN\033[0m  %s\n" "$1"; }

echo "claude-defaults validation"
echo ""

# Required tools
echo "--- tools ---"
if command -v jq >/dev/null 2>&1; then
    pass "jq installed"
else
    fail "jq not installed (required by hooks and statusline)"
fi

# Required files
echo "--- files ---"
for f in \
    ~/.claude/settings.json \
    ~/.claude/CLAUDE.md \
    ~/.claude/statusline.sh \
    ~/.claude/commands/review-pr.md \
    ~/.claude/commands/fix-issue.md \
    ~/.claude/commands/merge-dependabot.md \
    ~/.mcp.json; do
    if [ -f "$f" ]; then
        pass "$f"
    else
        fail "$f missing"
    fi
done

# Optional files
echo "--- optional ---"
for f in \
    ~/.claude/hooks/block-rm-rf.sh \
    ~/.claude/hooks/block-push-main.sh \
    ~/.claude/hooks/enforce-package-manager.sh \
    ~/.claude/hooks/log-bash-commands.sh; do
    if [ -f "$f" ]; then
        pass "$f"
    else
        warn "$f not installed"
    fi
done

# JSON validity
echo "--- json ---"
for f in ~/.claude/settings.json ~/.mcp.json; do
    if [ -f "$f" ]; then
        if jq empty "$f" 2>/dev/null; then
            pass "$f is valid JSON"
        else
            fail "$f is invalid JSON"
        fi
    fi
done

# Placeholder detection
echo "--- placeholders ---"
for f in ~/.mcp.json ~/.claude/settings.json; do
    if [ -f "$f" ]; then
        if grep -q "your-.*-here" "$f" 2>/dev/null; then
            fail "$f contains unreplaced placeholder values"
        else
            pass "$f has no placeholders"
        fi
    fi
done

# Executable permissions
echo "--- permissions ---"
for f in ~/.claude/statusline.sh; do
    if [ -f "$f" ]; then
        if [ -x "$f" ]; then
            pass "$f is executable"
        else
            fail "$f is not executable"
        fi
    fi
done

echo ""
if [ "$errors" -gt 0 ]; then
    echo "FAILED: $errors issue(s) found"
    exit 1
else
    echo "PASSED: All checks OK"
    exit 0
fi
