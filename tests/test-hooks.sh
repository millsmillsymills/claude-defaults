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

# === safety-block.sh quote-strip tests (P1-7) ===
echo "  testing safety-block.sh quote-strip"
# Echo of dangerous patterns inside quotes should be ALLOWED (exit 0)
quoted_safe_cases=(
    'echo "rm -rf /tmp/test"'
    "echo 'dd of=/dev/disk0 if=/dev/zero'"
    'echo "this contains rm -rf /Users/foo as text"'
    "printf '%s' 'mkfs.ext4 /dev/sdX'"
)
for cmd in "${quoted_safe_cases[@]}"; do
    in=$(jq -nc --arg c "$cmd" '{tool_name:"Bash", tool_input:{command:$c}}')
    echo "$in" | bash hooks/safety-block.sh
    [ $? -eq 0 ] || fail_msg "safety-block.sh quote-strip: blocked safe-quoted '$cmd'"
done
# Real dangerous commands (not quoted) still BLOCKED
real_danger_cases=(
    'rm -rf /Users/somebody'
    'sudo rm -rf /tmp'
    'dd of=/dev/disk0 if=/dev/zero'
)
for cmd in "${real_danger_cases[@]}"; do
    in=$(jq -nc --arg c "$cmd" '{tool_name:"Bash", tool_input:{command:$c}}')
    echo "$in" | bash hooks/safety-block.sh
    [ $? -eq 2 ] || fail_msg "safety-block.sh quote-strip: failed to block real '$cmd'"
done

# === safety-block.sh broader pattern tests (P1-6) ===
echo "  testing safety-block.sh broader patterns"
extra_block_cases=(
    'sudo rm -rf /tmp/anything'
    'dd of=/dev/disk0 if=/dev/zero'
    'dd of=/dev/sda1 if=/dev/zero'
    'dd of=/dev/nvme0n1 if=/dev/zero'
    'mkfs.ext4 /dev/sda1'
    'wipefs -a /dev/sda'
    ':(){ :|:& };:'
    'chmod -R 777 /'
    'chmod -R 777 ~'
    'git push --force origin main'
    'git push -f origin master'
    'git push --force-with-lease origin production'
)
for cmd in "${extra_block_cases[@]}"; do
    in=$(jq -nc --arg c "$cmd" '{tool_name:"Bash", tool_input:{command:$c}}')
    echo "$in" | bash hooks/safety-block.sh
    [ $? -eq 2 ] || fail_msg "safety-block.sh: failed to block '$cmd'"
done

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

# === log-tool-calls.sh post path test (P1-5) ===
echo "  testing log-tool-calls.sh post path"
post_input='{
  "session_id": "post-test",
  "cwd": "/tmp",
  "tool_name": "Bash",
  "tool_input": {"command": "echo paired-test"}
}'
post_response='{
  "session_id": "post-test",
  "cwd": "/tmp",
  "tool_name": "Bash",
  "tool_input": {"command": "echo paired-test"},
  "tool_response": {"stdout": "paired-test\n", "stderr": "", "exit_code": 0}
}'
echo "$post_input" | bash hooks/log-tool-calls.sh pre
sleep 0.05
echo "$post_response" | bash hooks/log-tool-calls.sh post
last=$(tail -n 1 "$log_file")
echo "$last" | jq -e '.event == "post" and .tool == "Bash" and .exit_status == 0 and .duration_ms >= 30' >/dev/null \
    || fail_msg "log-tool-calls.sh post row malformed or duration_ms wrong: $last"
echo "$last" | jq -e '.output.stdout == "paired-test\n"' >/dev/null \
    || fail_msg "log-tool-calls.sh post output not captured: $last"

# === call_id pairs across pre/post (P1-1) ===
echo "  testing call_id pairing"
cid_input='{
  "session_id": "cid-test",
  "cwd": "/tmp",
  "tool_name": "Bash",
  "tool_input": {"command": "echo cid-pair"}
}'
cid_response='{
  "session_id": "cid-test",
  "cwd": "/tmp",
  "tool_name": "Bash",
  "tool_input": {"command": "echo cid-pair"},
  "tool_response": {"stdout": "cid-pair\n", "exit_code": 0}
}'
echo "$cid_input" | bash hooks/log-tool-calls.sh pre
sleep 0.03
echo "$cid_response" | bash hooks/log-tool-calls.sh post
pre_cid=$(jq -r 'select(.event=="pre" and .session_id=="cid-test") | .call_id' "$log_file" | tail -n 1)
post_cid=$(jq -r 'select(.event=="post" and .session_id=="cid-test") | .call_id' "$log_file" | tail -n 1)
[ -n "$pre_cid" ] && [ "$pre_cid" = "$post_cid" ] || fail_msg "call_id mismatch: pre=$pre_cid post=$post_cid"

# === pair-file round-trip test (P1-8) ===
echo "  testing pair-file round-trip"
pair_input='{
  "session_id": "pair-test-xyz",
  "cwd": "/tmp",
  "tool_name": "Bash",
  "tool_input": {"command": "echo round-trip"}
}'
echo "$pair_input" | bash hooks/log-tool-calls.sh pre
# Pair file should now exist (filename contains hash; check via glob)
pair_count=$(ls "${TMPDIR:-/tmp}"/claude-tool-pair-test-xyz-* 2>/dev/null | wc -l | tr -d ' ')
[ "$pair_count" = "1" ] || fail_msg "pair file not created (count=$pair_count)"
sleep 0.03
pair_response='{
  "session_id": "pair-test-xyz",
  "cwd": "/tmp",
  "tool_name": "Bash",
  "tool_input": {"command": "echo round-trip"},
  "tool_response": {"stdout": "round-trip\n", "exit_code": 0}
}'
echo "$pair_response" | bash hooks/log-tool-calls.sh post
# Pair file should be cleaned up after post
pair_count_after=$(ls "${TMPDIR:-/tmp}"/claude-tool-pair-test-xyz-* 2>/dev/null | wc -l | tr -d ' ')
[ "$pair_count_after" = "0" ] || fail_msg "pair file not cleaned up after post (count=$pair_count_after)"

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
