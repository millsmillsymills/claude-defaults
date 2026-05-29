#!/usr/bin/env bash
# truncate_output per-line size guarantee, driven through jsonl_write.py.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

fail=0
fail_msg() { echo "FAIL: $1" >&2; fail=$((fail+1)); }

line_bytes() { wc -c <"$1" | tr -d ' '; }

# Case 1: both fields short (<=256) but envelope + fields exceed the cap.
# The old per-field loop skipped both and wrote an oversize, unmarked line.
tmp=$(mktemp)
stdout=$(python3 -c 'print("o" * 240, end="")')
stderr=$(python3 -c 'print("e" * 240, end="")')
payload=$(jq -nc --arg o "$stdout" --arg e "$stderr" \
    '{call_id:"c1", ts:"2026-05-29T00:00:00Z", args:{cmd:"x"}, output:{stdout:$o, stderr:$e}}')
echo "$payload" | CLAUDE_LOG_MAX_LINE_BYTES=300 python3 hooks/lib/jsonl_write.py "$tmp"
n=$(line_bytes "$tmp")
# Allow a small marker leeway above the cap.
[ "$n" -le 320 ] || fail_msg "case1: line $n bytes exceeds 300 cap (+leeway)"
grep -qF '_truncated_bytes' "$tmp" || fail_msg "case1: missing _truncated_bytes marker"
python3 -c 'import json,sys; json.loads(open(sys.argv[1]).read())' "$tmp" \
    || fail_msg "case1: written line is not valid JSON"
rm -f "$tmp"

# Case 2: large stdout (existing trimming behaviour) still fits the cap.
tmp=$(mktemp)
big=$(python3 -c 'print("x" * 5000, end="")')
payload=$(jq -nc --arg o "$big" \
    '{call_id:"c2", output:{stdout:$o, stderr:""}}')
echo "$payload" | CLAUDE_LOG_MAX_LINE_BYTES=1024 python3 hooks/lib/jsonl_write.py "$tmp"
n=$(line_bytes "$tmp")
[ "$n" -le 1044 ] || fail_msg "case2: line $n bytes exceeds 1024 cap (+leeway)"
grep -qF '_truncated_bytes' "$tmp" || fail_msg "case2: missing _truncated_bytes marker"
rm -f "$tmp"

# Case 3: small payload under the cap is written unchanged (no marker).
tmp=$(mktemp)
payload='{"call_id":"c3","output":{"stdout":"hi","stderr":""}}'
echo "$payload" | CLAUDE_LOG_MAX_LINE_BYTES=1048576 python3 hooks/lib/jsonl_write.py "$tmp"
if grep -qF '_truncated_bytes' "$tmp"; then
    fail_msg "case3: unexpected _truncated_bytes on a small payload"
fi
python3 -c '
import json, sys
o = json.loads(open(sys.argv[1]).read())
assert o["output"]["stdout"] == "hi", o
' "$tmp" || fail_msg "case3: small payload was modified"
rm -f "$tmp"

if [ "$fail" -eq 0 ]; then
    echo "test-truncate: PASS"
else
    echo "test-truncate: $fail FAILURE(S)"
    exit 1
fi
