#!/usr/bin/env bash
set -uo pipefail

# Verify claude-defaults installation.
# Checks expected symlinks, real files, log directory, executability.
#
# Usage: ./scripts/validate.sh
# Exit 0 = all checks pass, exit 1 = issues found

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CLAUDE_DIR="${HOME}/.claude"
errors=0

pass() { printf "  \033[32mOK\033[0m  %s\n" "$1"; }
fail() { printf "  \033[31mFAIL\033[0m  %s\n" "$1"; ((errors++)) || true; }
warn() { printf "  \033[33mWARN\033[0m  %s\n" "$1"; }

echo "claude-defaults validation"
echo "  repo:   $REPO_DIR"
echo "  target: $CLAUDE_DIR"
echo ""

# Required tools
echo "--- tools ---"
if command -v jq >/dev/null 2>&1; then pass "jq installed"; else fail "jq not installed"; fi
if command -v python3 >/dev/null 2>&1; then pass "python3 installed"; else fail "python3 not installed"; fi

# settings.json: real file, valid JSON, has hooks
echo "--- settings ---"
if [ -L "${CLAUDE_DIR}/settings.json" ]; then
    fail "${CLAUDE_DIR}/settings.json is a symlink (should be a real file from jq-merge)"
elif [ -f "${CLAUDE_DIR}/settings.json" ]; then
    pass "${CLAUDE_DIR}/settings.json is a real file"
    if python3 -m json.tool < "${CLAUDE_DIR}/settings.json" >/dev/null 2>&1; then
        pass "settings.json is valid JSON"
    else
        fail "settings.json is invalid JSON"
    fi
    # Hooks block present
    for hook_name in safety-block.sh safety-warn.sh log-tool-calls.sh log-rotate.sh; do
        if jq -r '.. | objects | .command? // empty' "${CLAUDE_DIR}/settings.json" 2>/dev/null | grep -q "$hook_name"; then
            pass "settings.json wires $hook_name"
        else
            fail "settings.json does NOT wire $hook_name"
        fi
    done
else
    fail "${CLAUDE_DIR}/settings.json missing"
fi

# Symlinked content
echo "--- symlinks ---"
declare -a EXPECTED_SYMLINKS=(
    "${CLAUDE_DIR}/CLAUDE.md|${REPO_DIR}/claude-md-template.md"
    "${CLAUDE_DIR}/statusline.sh|${REPO_DIR}/scripts/statusline.sh"
    "${CLAUDE_DIR}/hooks/safety-block.sh|${REPO_DIR}/hooks/safety-block.sh"
    "${CLAUDE_DIR}/hooks/safety-warn.sh|${REPO_DIR}/hooks/safety-warn.sh"
    "${CLAUDE_DIR}/hooks/log-tool-calls.sh|${REPO_DIR}/hooks/log-tool-calls.sh"
    "${CLAUDE_DIR}/hooks/log-rotate.sh|${REPO_DIR}/hooks/log-rotate.sh"
    "${CLAUDE_DIR}/hooks/block-rm-rf.sh|${REPO_DIR}/hooks/block-rm-rf.sh"
    "${CLAUDE_DIR}/hooks/block-push-main.sh|${REPO_DIR}/hooks/block-push-main.sh"
    "${CLAUDE_DIR}/hooks/lib/redact.py|${REPO_DIR}/hooks/lib/redact.py"
    "${CLAUDE_DIR}/hooks/lib/jsonl-write.py|${REPO_DIR}/hooks/lib/jsonl-write.py"
    "${CLAUDE_DIR}/hooks/lib/common.sh|${REPO_DIR}/hooks/lib/common.sh"
    "${CLAUDE_DIR}/commands/review-pr.md|${REPO_DIR}/commands/review-pr.md"
    "${CLAUDE_DIR}/commands/fix-issue.md|${REPO_DIR}/commands/fix-issue.md"
    "${CLAUDE_DIR}/commands/merge-dependabot.md|${REPO_DIR}/commands/merge-dependabot.md"
)
for entry in "${EXPECTED_SYMLINKS[@]}"; do
    path="${entry%|*}"
    expected="${entry#*|}"
    if [ -L "$path" ]; then
        actual=$(readlink "$path")
        if [ "$actual" = "$expected" ]; then
            pass "$path -> $expected"
        else
            fail "$path -> $actual (expected $expected)"
        fi
    else
        fail "$path is not a symlink"
    fi
done

# Logs dir is real
echo "--- logs ---"
if [ -L "${CLAUDE_DIR}/logs" ]; then
    fail "${CLAUDE_DIR}/logs is a symlink (should be a real directory)"
elif [ -d "${CLAUDE_DIR}/logs" ]; then
    pass "${CLAUDE_DIR}/logs is a real directory"
else
    fail "${CLAUDE_DIR}/logs missing"
fi

# Hook executability (through symlinks)
echo "--- executable ---"
for hook in safety-block safety-warn log-tool-calls log-rotate block-rm-rf block-push-main; do
    f="${CLAUDE_DIR}/hooks/${hook}.sh"
    if [ -x "$f" ]; then pass "$f executable"; else fail "$f not executable"; fi
done
[ -x "${CLAUDE_DIR}/statusline.sh" ] && pass "statusline.sh executable" || fail "statusline.sh not executable"

# MCP config
echo "--- mcp ---"
if [ -f "${HOME}/.mcp.json" ]; then
    if jq empty "${HOME}/.mcp.json" 2>/dev/null; then
        pass "${HOME}/.mcp.json valid JSON"
    else
        fail "${HOME}/.mcp.json invalid JSON"
    fi
    if grep -q "your-.*-here" "${HOME}/.mcp.json" 2>/dev/null; then
        warn "${HOME}/.mcp.json contains placeholder values"
    fi
else
    warn "${HOME}/.mcp.json missing (run install.sh mcp to install)"
fi

echo ""
if [ "$errors" -gt 0 ]; then
    echo "FAILED: $errors issue(s)"
    exit 1
else
    echo "PASSED: All checks OK"
    exit 0
fi
