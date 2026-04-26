#!/usr/bin/env bash
# Per-hook input/exit-code/log assertions using fixtures/.
set -uo pipefail
cd "$(dirname "$0")/.."

fail=0
fail_msg() { echo "FAIL: $1" >&2; fail=$((fail+1)); }

# Setup isolated $HOME for log capture
TEST_HOME=$(mktemp -d -t claude-hooks-test.XXXXXX)
trap "rm -rf $TEST_HOME" EXIT
export HOME="$TEST_HOME"
mkdir -p "$TEST_HOME/.claude/logs"

# === safety-block.sh ===
echo "  testing safety-block.sh"
bash hooks/safety-block.sh < tests/fixtures/tool-input-bash-safe.json
[ $? -eq 0 ] || fail_msg "safety-block.sh blocked safe command"
bash hooks/safety-block.sh < tests/fixtures/tool-input-bash-rmrf.json
[ $? -eq 2 ] || fail_msg "safety-block.sh did not block rm -rf"

# === safety-warn.sh ===
echo "  testing safety-warn.sh"
bash hooks/safety-warn.sh < tests/fixtures/tool-input-edit-env.json 2>/tmp/warn-stderr
[ $? -eq 0 ] || fail_msg "safety-warn.sh exit non-zero on .env"
[ -s /tmp/warn-stderr ] || fail_msg "safety-warn.sh did not warn on .env"
bash hooks/safety-warn.sh < tests/fixtures/tool-input-edit-normal.json 2>/tmp/warn-stderr
[ $? -eq 0 ] || fail_msg "safety-warn.sh exit non-zero on normal file"
[ -s /tmp/warn-stderr ] && fail_msg "safety-warn.sh warned on normal file"
rm -f /tmp/warn-stderr

# === log-tool-calls.sh ===
echo "  testing log-tool-calls.sh"
today=$(date +%Y-%m-%d)
log_file="$TEST_HOME/.claude/logs/tool-calls-${today}.jsonl"
bash hooks/log-tool-calls.sh pre < tests/fixtures/tool-input-bash-safe.json
[ -f "$log_file" ] || fail_msg "log-tool-calls.sh did not create log"
last=$(tail -n 1 "$log_file")
echo "$last" | jq -e '.event == "pre" and .tool == "Bash" and .args.command == "git status"' >/dev/null \
    || fail_msg "log-tool-calls.sh pre row malformed: $last"
# MCP parsing
bash hooks/log-tool-calls.sh pre < tests/fixtures/tool-input-mcp-call.json
last=$(tail -n 1 "$log_file")
echo "$last" | jq -e '.mcp_server == "playwright"' >/dev/null \
    || fail_msg "log-tool-calls.sh did not parse MCP server: $last"

# === log-rotate.sh ===
echo "  testing log-rotate.sh"
old="$TEST_HOME/.claude/logs/tool-calls-2025-01-01.jsonl"
touch "$old"
touch -t "$(date -v-100d +%Y%m%d0000 2>/dev/null || date -d '100 days ago' +%Y%m%d0000)" "$old"
CLAUDE_LOG_RETAIN_DAYS=90 bash hooks/log-rotate.sh
[ -f "$old" ] && fail_msg "log-rotate.sh did not prune old log"

# === existing block-rm-rf.sh / block-push-main.sh (regression) ===
echo "  testing legacy block hooks"
bash hooks/block-rm-rf.sh <<< '{"tool_input":{"command":"rm -rf /tmp"}}'
[ $? -eq 2 ] || fail_msg "block-rm-rf.sh regression: did not block"
bash hooks/block-rm-rf.sh <<< '{"tool_input":{"command":"ls -la"}}'
[ $? -eq 0 ] || fail_msg "block-rm-rf.sh regression: blocked safe command"
bash hooks/block-push-main.sh <<< '{"tool_input":{"command":"git push origin main"}}'
[ $? -eq 2 ] || fail_msg "block-push-main.sh regression: did not block"
bash hooks/block-push-main.sh <<< '{"tool_input":{"command":"git push origin feature"}}'
[ $? -eq 0 ] || fail_msg "block-push-main.sh regression: blocked feature push"

if [ "$fail" -eq 0 ]; then
    echo "test-hooks: PASS"
else
    echo "test-hooks: $fail FAILURE(S)"
    exit 1
fi
