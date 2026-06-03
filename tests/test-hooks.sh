#!/usr/bin/env bash
# Per-hook input/exit-code/log assertions using fixtures/.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

fail=0
fail_msg() {
  echo "FAIL: $1" >&2
  fail=$((fail + 1))
}

# Count files matching the glob args without parsing ls (SC2012-safe);
# an unmatched glob stays literal and is rejected by the existence test.
count_files() {
  local n=0 f
  for f in "$@"; do [ -e "$f" ] && n=$((n + 1)); done
  printf '%s' "$n"
}

# Setup isolated $HOME for log capture
TEST_HOME=$(mktemp -d -t claude-hooks-test.XXXXXX)
trap 'rm -rf "$TEST_HOME"' EXIT
export HOME="$TEST_HOME"
mkdir -p "$TEST_HOME/.claude/logs"

# === safety-block.py (fixture smoke test) ===
# Full pattern/bypass coverage lives in test-guard-hooks.sh; here we only
# confirm the wired hook runs on real fixtures and exits as expected.
echo "  testing safety-block.py"
hooks/safety-block.py <tests/fixtures/tool-input-bash-safe.json
rc=$?
[ "$rc" -eq 0 ] || fail_msg "safety-block.py blocked safe command"
hooks/safety-block.py <tests/fixtures/tool-input-bash-rmrf.json
rc=$?
[ "$rc" -eq 2 ] || fail_msg "safety-block.py did not block rm -rf"
# Malformed JSON and non-object payloads fail open quietly (no error log).
printf 'not json{' | hooks/safety-block.py ||
  fail_msg "safety-block.py did not fail open on malformed JSON"
printf '[]' | hooks/safety-block.py ||
  fail_msg "safety-block.py did not fail open on non-object JSON"
[ -e "$HOME/.claude/logs/hook-errors.log" ] && fail_msg "safety-block.py logged on benign malformed input"
# A scan crash must fail open LOUDLY: exit 0, warn on stderr, and leave a
# durable hook-errors.log entry -- a never-enforced guard must not be silent.
echo "  testing safety-block.py loud fail-open on scan crash"
python3 - <<'PY' 2>/tmp/sb-stderr
import importlib.util, io, sys
spec = importlib.util.spec_from_file_location("sb", "hooks/safety-block.py")
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
def boom(_seg):
    raise RuntimeError("boom")
m._CHECKS = [(boom, "x")]
sys.stdin = io.StringIO('{"tool_input":{"command":"echo hi"}}')
sys.exit(m.main())
PY
rc=$?
[ "$rc" -eq 0 ] || fail_msg "safety-block.py did not fail open on scan crash (rc=$rc)"
[ -s /tmp/sb-stderr ] || fail_msg "safety-block.py scan crash not warned to stderr"
grep -q "safety-block.py scan-error" "$HOME/.claude/logs/hook-errors.log" 2>/dev/null ||
  fail_msg "safety-block.py scan crash not recorded in hook-errors.log"
rm -f /tmp/sb-stderr "$HOME/.claude/logs/hook-errors.log"

# === safety-warn.sh ===
echo "  testing safety-warn.sh"
bash hooks/safety-warn.sh <tests/fixtures/tool-input-edit-env.json 2>/tmp/warn-stderr
rc=$?
[ "$rc" -eq 0 ] || fail_msg "safety-warn.sh exit non-zero on .env"
[ -s /tmp/warn-stderr ] || fail_msg "safety-warn.sh did not warn on .env"
bash hooks/safety-warn.sh <tests/fixtures/tool-input-edit-normal.json 2>/tmp/warn-stderr
rc=$?
[ "$rc" -eq 0 ] || fail_msg "safety-warn.sh exit non-zero on normal file"
[ -s /tmp/warn-stderr ] && fail_msg "safety-warn.sh warned on normal file"
rm -f /tmp/warn-stderr

# safety-warn.sh broader sensitive-path coverage (beyond .env)
echo "  testing safety-warn.sh broader sensitive paths"
warn_paths=(
  "/home/u/.ssh/id_rsa"
  "/etc/ssl/server.pem"
  "/x/private.key"
  "/x/secrets.yaml"
  "/x/credentials.json"
)
for p in "${warn_paths[@]}"; do
  jq -nc --arg f "$p" '{tool_input:{file_path:$f}}' | bash hooks/safety-warn.sh 2>/tmp/warn-stderr
  [ -s /tmp/warn-stderr ] || fail_msg "safety-warn.sh did not warn on $p"
done
# negative: an ordinary file must not warn
jq -nc '{tool_input:{file_path:"/x/notes.txt"}}' | bash hooks/safety-warn.sh 2>/tmp/warn-stderr
[ -s /tmp/warn-stderr ] && fail_msg "safety-warn.sh warned on ordinary file /x/notes.txt"
rm -f /tmp/warn-stderr

# === log-tool-calls.sh ===
echo "  testing log-tool-calls.sh"
# Writer names log files by UTC date; match it so the suite doesn't flake
# when local time and UTC fall on different calendar days.
today=$(date -u +%Y-%m-%d)
log_file="$TEST_HOME/.claude/logs/tool-calls-${today}.jsonl"
bash hooks/log-tool-calls.sh pre <tests/fixtures/tool-input-bash-safe.json
[ -f "$log_file" ] || fail_msg "log-tool-calls.sh did not create log"
last=$(tail -n 1 "$log_file")
echo "$last" | jq -e '.event == "pre" and .tool == "Bash" and .args.command == "git status"' >/dev/null ||
  fail_msg "log-tool-calls.sh pre row malformed: $last"
# MCP parsing
bash hooks/log-tool-calls.sh pre <tests/fixtures/tool-input-mcp-call.json
last=$(tail -n 1 "$log_file")
echo "$last" | jq -e '.mcp_server == "playwright"' >/dev/null ||
  fail_msg "log-tool-calls.sh did not parse MCP server: $last"

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
echo "$last" | jq -e '.event == "post" and .tool == "Bash" and .exit_status == 0 and .duration_ms >= 30' >/dev/null ||
  fail_msg "log-tool-calls.sh post row malformed or duration_ms wrong: $last"
echo "$last" | jq -e '.output.stdout == "paired-test\n"' >/dev/null ||
  fail_msg "log-tool-calls.sh post output not captured: $last"

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
pair_count=$(count_files "${TMPDIR:-/tmp}"/claude-tool-pair-test-xyz-*)
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
pair_count_after=$(count_files "${TMPDIR:-/tmp}"/claude-tool-pair-test-xyz-*)
[ "$pair_count_after" = "0" ] || fail_msg "pair file not cleaned up after post (count=$pair_count_after)"

# Writer names log files by UTC date; query that file directly.
utc_log="$TEST_HOME/.claude/logs/tool-calls-$(date -u +%Y-%m-%d).jsonl"

# === H9: non-zero exit_status is recorded ===
echo "  testing non-zero exit_status"
nz_pre='{"session_id":"nz","cwd":"/tmp","tool_name":"Bash","tool_input":{"command":"false"}}'
nz_post='{"session_id":"nz","cwd":"/tmp","tool_name":"Bash","tool_input":{"command":"false"},"tool_response":{"stdout":"","stderr":"boom","exit_code":1}}'
echo "$nz_pre" | bash hooks/log-tool-calls.sh pre
echo "$nz_post" | bash hooks/log-tool-calls.sh post
last=$(jq -c 'select(.event=="post" and .session_id=="nz")' "$utc_log" | tail -n 1)
echo "$last" | jq -e '.exit_status == 1' >/dev/null ||
  fail_msg "H9: non-zero exit_status not recorded: $last"

# === L8: post with no preceding pre (fresh call_id, duration_ms null) ===
echo "  testing post-without-pre fallback"
np_post='{"session_id":"nopre-unique-xyz","cwd":"/tmp","tool_name":"Bash","tool_input":{"command":"echo lonely"},"tool_response":{"stdout":"lonely\n","exit_code":0}}'
echo "$np_post" | bash hooks/log-tool-calls.sh post
last=$(jq -c 'select(.event=="post" and .session_id=="nopre-unique-xyz")' "$utc_log" | tail -n 1)
echo "$last" | jq -e '(.call_id | type == "string" and length > 0) and .duration_ms == null' >/dev/null ||
  fail_msg "L8: post-without-pre row malformed: $last"

# === concurrent identical-input calls: no fabricated duration, no aliasing ===
# Two pre-events with identical session+input share one pair_path, so the
# second pre's O_TRUNC overwrites the first's call_id/start. The join is only
# ever derived from the legitimately-written pair file: every post duration is
# either a plausible value read from that file or null (pair file gone). With
# the mtime fallback removed, no post can consume a racing call's file, so no
# duration is fabricated from foreign state. Race timing decides how many posts
# observe the file before it is unlinked, so the count of nulls is not asserted.
echo "  testing concurrent identical-input pairing"
conc_pre='{"session_id":"conc-test","cwd":"/tmp","tool_name":"Bash","tool_input":{"command":"echo race"}}'
conc_post='{"session_id":"conc-test","cwd":"/tmp","tool_name":"Bash","tool_input":{"command":"echo race"},"tool_response":{"stdout":"race\n","exit_code":0}}'
echo "$conc_pre" | bash hooks/log-tool-calls.sh pre &
echo "$conc_pre" | bash hooks/log-tool-calls.sh pre &
wait
sleep 0.03
echo "$conc_post" | bash hooks/log-tool-calls.sh post &
echo "$conc_post" | bash hooks/log-tool-calls.sh post &
wait
conc_durations=$(jq -c 'select(.event=="post" and .session_id=="conc-test") | .duration_ms' "$utc_log")
conc_post_count=$(printf '%s\n' "$conc_durations" | grep -c .)
[ "$conc_post_count" = "2" ] || fail_msg "concurrent: expected 2 post rows, got $conc_post_count"
# Every duration is either null (honest unknown) or a plausible non-negative
# integer no larger than the time we actually waited (~2s ceiling). Anything
# else would mean a value was invented or pulled from another call.
while IFS= read -r d; do
  case "$d" in
  null) ;;
  '' | *[!0-9]*) fail_msg "concurrent: implausible duration_ms '$d'" ;;
  *) [ "$d" -le 2000 ] || fail_msg "concurrent: duration_ms too large '$d'" ;;
  esac
done <<<"$conc_durations"
# No leftover pair files for this session after both posts.
conc_leftover=$(count_files "${TMPDIR:-/tmp}"/claude-tool-conc-test-*)
[ "$conc_leftover" = "0" ] || fail_msg "concurrent: pair files leaked (count=$conc_leftover)"

# === post with no pre never aliases a concurrent same-session call (KP-3) ===
# A different-input call's pair file exists; a post whose own pre never ran
# must NOT consume it. The mtime fallback used to; now it reports null.
echo "  testing no-pre post does not alias a sibling pair file"
echo '{"session_id":"alias-test","cwd":"/tmp","tool_name":"Bash","tool_input":{"command":"echo sibling"}}' |
  bash hooks/log-tool-calls.sh pre
alias_post='{"session_id":"alias-test","cwd":"/tmp","tool_name":"Bash","tool_input":{"command":"echo orphan"},"tool_response":{"stdout":"orphan\n","exit_code":0}}'
echo "$alias_post" | bash hooks/log-tool-calls.sh post
alias_dur=$(jq -c 'select(.event=="post" and .session_id=="alias-test") | .duration_ms' "$utc_log" | tail -n 1)
[ "$alias_dur" = "null" ] || fail_msg "alias: orphan post should be null, got '$alias_dur'"
# The sibling's pair file must remain untouched (only its own post may clear it).
alias_leftover=$(count_files "${TMPDIR:-/tmp}"/claude-tool-alias-test-*)
[ "$alias_leftover" = "1" ] || fail_msg "alias: sibling pair file disturbed (count=$alias_leftover)"
rm -f "${TMPDIR:-/tmp}"/claude-tool-alias-test-*

# === M13: oversized output is truncated under the line-byte cap ===
echo "  testing output truncation"
big=$(python3 -c 'print("x" * 5000)')
tr_post=$(jq -nc --arg s "$big" '{session_id:"trunc",cwd:"/tmp",tool_name:"Bash",tool_input:{command:"echo big"},tool_response:{stdout:$s,exit_code:0}}')
echo "$tr_post" | CLAUDE_LOG_MAX_LINE_BYTES=1024 bash hooks/log-tool-calls.sh post
last=$(jq -c 'select(.event=="post" and .session_id=="trunc")' "$utc_log" | tail -n 1)
echo "$last" | jq -e '.output._truncated_bytes > 0 and (.output.stdout | length) < 5000' >/dev/null ||
  fail_msg "M13: output not truncated / marker missing: $last"

# === log-rotate.sh ===
echo "  testing log-rotate.sh"
old="$TEST_HOME/.claude/logs/tool-calls-2025-01-01.jsonl"
touch "$old"
touch -t "$(date -v-100d +%Y%m%d0000 2>/dev/null || date -d '100 days ago' +%Y%m%d0000)" "$old"
CLAUDE_LOG_RETAIN_DAYS=90 bash hooks/log-rotate.sh
[ -f "$old" ] && fail_msg "log-rotate.sh did not prune old log"

# === M12: size-based gzip rotation (+ .N.gz collision bump) ===
echo "  testing log-rotate.sh gzip rotation"
rot_log="$TEST_HOME/.claude/logs/tool-calls-$(date -u +%Y-%m-%d).jsonl"
mkdir -p "$(dirname "$rot_log")"
printf 'first\n' >"$rot_log"
CLAUDE_LOG_ROTATE_BYTES=1 bash hooks/log-rotate.sh
[ -f "${rot_log}.1.gz" ] || fail_msg "M12: rotation did not create .1.gz"
[ -f "$rot_log" ] && fail_msg "M12: original log not removed after rotation"
printf 'second\n' >"$rot_log"
CLAUDE_LOG_ROTATE_BYTES=1 bash hooks/log-rotate.sh
[ -f "${rot_log}.2.gz" ] || fail_msg "M12: collision did not bump to .2.gz"

# === Gzip rotation produces a valid, faithful archive ===
echo "  testing log-rotate.sh gzip integrity"
gz_log="$TEST_HOME/.claude/logs/tool-calls-$(date -u +%Y-%m-%d).jsonl"
rm -f "${gz_log}".*.gz
gz_payload=$(python3 -c 'print("line-" + "x" * 4096)')
printf '%s\n' "$gz_payload" >"$gz_log"
CLAUDE_LOG_ROTATE_BYTES=1 bash hooks/log-rotate.sh
[ -f "$gz_log" ] && fail_msg "original log not removed after gzip rotation"
gz_out="${gz_log}.1.gz"
[ -f "$gz_out" ] || fail_msg "rotation did not create .1.gz"
gzip -t "$gz_out" 2>/dev/null || fail_msg "rotated .gz failed integrity check"
[ -e "${gz_log}.1.gz.tmp" ] && fail_msg "tmp file left behind after rotation"
decompressed=$(gzip -dc "$gz_out" 2>/dev/null)
[ "$decompressed" = "$gz_payload" ] || fail_msg "decompressed content does not match original"

# === Rename-first rotation detaches the archive from the live path ===
echo "  testing log-rotate.sh concurrent-append safety"
cc_log="$TEST_HOME/.claude/logs/tool-calls-$(date -u +%Y-%m-%d).jsonl"
rm -f "${cc_log}".*.gz "${cc_log}".*.rotating "$cc_log"
printf 'old-1\nold-2\n' >"$cc_log"
CLAUDE_LOG_ROTATE_BYTES=1 bash hooks/log-rotate.sh
# A tool call appending right after rotation must land in a fresh today_log,
# never in the file just archived-and-deleted.
printf 'new-after-rotate\n' >>"$cc_log"
grep -q 'new-after-rotate' "$cc_log" || fail_msg "post-rotation line not in fresh log"
cc_gz=""
for f in "${cc_log}".*.gz; do
  [ -e "$f" ] && cc_gz="$f" && break
done
[ -n "$cc_gz" ] || fail_msg "rotation did not produce a .gz"
cc_arch=$(gzip -dc "$cc_gz" 2>/dev/null)
[ "$cc_arch" = "$(printf 'old-1\nold-2')" ] || fail_msg "archive content unexpected"
[ -e "${cc_log}.1.rotating" ] && fail_msg ".rotating left behind on success"

# === A corrupt archive preserves the data instead of destroying it ===
echo "  testing log-rotate.sh data preservation on bad archive"
fl_log="$TEST_HOME/.claude/logs/tool-calls-$(date -u +%Y-%m-%d).jsonl"
rm -f "${fl_log}".*.gz "${fl_log}".*.rotating "$fl_log"
printf 'keep-me\n' >"$fl_log"
# Shadow gzip with a stub: -t (integrity) always fails, -c emits garbage, so
# the rotate sees a bad archive and must keep the data rather than rm it.
fake_bin=$(mktemp -d)
cat >"$fake_bin/gzip" <<'STUB'
#!/usr/bin/env bash
for a in "$@"; do [ "$a" = "-t" ] && exit 1; done
echo "not-a-real-gzip"
exit 0
STUB
chmod +x "$fake_bin/gzip"
PATH="$fake_bin:$PATH" CLAUDE_LOG_ROTATE_BYTES=1 bash hooks/log-rotate.sh
rm -rf "$fake_bin"
survived=""
[ -f "$fl_log" ] && survived=$(cat "$fl_log")
[ -z "$survived" ] && [ -f "${fl_log}.1.rotating" ] && survived=$(cat "${fl_log}.1.rotating")
grep -q 'keep-me' <<<"$survived" || fail_msg "data lost when archive was corrupt"
[ -e "${fl_log}.1.gz" ] && fail_msg "kept a corrupt .gz"
[ -e "${fl_log}.1.gz.tmp" ] && fail_msg "tmp left after failed rotation"
rm -f "${fl_log}".*.rotating "$fl_log"

# === Mid-session rotation fires via the pre path ===
echo "  testing mid-session rotation via pre path"
ms_log="$TEST_HOME/.claude/logs/tool-calls-$(date -u +%Y-%m-%d).jsonl"
rm -f "${ms_log}".*.gz
python3 -c 'open("'"$ms_log"'", "w").write("seed-row\n" * 200)'
# The check is gated to every 100th pre-call; prime the counter to 99 so the
# next pre-call lands on the modulo boundary and triggers the rotation.
echo 99 >"$TEST_HOME/.claude/logs/.rotate-counter"
ms_input='{"session_id":"ms-rotate","cwd":"/tmp","tool_name":"Bash","tool_input":{"command":"echo midsession"}}'
echo "$ms_input" | CLAUDE_LOG_ROTATE_BYTES=64 bash hooks/log-tool-calls.sh pre
ms_gz_count=$(count_files "${ms_log}".*.gz)
[ "$ms_gz_count" -ge 1 ] || fail_msg "mid-session pre call did not rotate oversize log"

# === existing block-rm-rf.sh / block-push-main.sh (regression) ===
echo "  testing legacy block hooks"
bash hooks/block-rm-rf.sh <<<'{"tool_input":{"command":"rm -rf /tmp"}}'
rc=$?
[ "$rc" -eq 2 ] || fail_msg "block-rm-rf.sh regression: did not block"
bash hooks/block-rm-rf.sh <<<'{"tool_input":{"command":"ls -la"}}'
rc=$?
[ "$rc" -eq 0 ] || fail_msg "block-rm-rf.sh regression: blocked safe command"
bash hooks/block-push-main.sh <<<'{"tool_input":{"command":"git push origin main"}}'
rc=$?
[ "$rc" -eq 2 ] || fail_msg "block-push-main.sh regression: did not block"
bash hooks/block-push-main.sh <<<'{"tool_input":{"command":"git push origin feature"}}'
rc=$?
[ "$rc" -eq 0 ] || fail_msg "block-push-main.sh regression: blocked feature push"

if [ "$fail" -eq 0 ]; then
  echo "test-hooks: PASS"
else
  echo "test-hooks: $fail FAILURE(S)"
  exit 1
fi
