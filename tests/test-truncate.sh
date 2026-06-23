#!/usr/bin/env bash
# truncate_output per-line size guarantee, driven through jsonl_write.py.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

fail=0
fail_msg() {
  echo "FAIL: $1" >&2
  fail=$((fail + 1))
}

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
python3 -c 'import json,sys; json.loads(open(sys.argv[1]).read())' "$tmp" ||
  fail_msg "case1: written line is not valid JSON"
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

# Case 4: the non-trimmable envelope (here a large args) alone exceeds the cap.
# Emptying stdout/stderr cannot save it, so the line is emitted oversize but
# honestly flagged with _truncated_oversize -- _truncated_bytes must never
# imply a cap that wasn't met.
tmp=$(mktemp)
bigargs=$(python3 -c 'print("a" * 2000, end="")')
payload=$(jq -nc --arg a "$bigargs" \
  '{call_id:"c4", ts:"2026-05-29T00:00:00Z", args:{cmd:$a}, output:{stdout:"oo", stderr:"ee"}}')
echo "$payload" | CLAUDE_LOG_MAX_LINE_BYTES=300 python3 hooks/lib/jsonl_write.py "$tmp"
python3 -c '
import json, sys
o = json.loads(open(sys.argv[1]).read())
assert o["output"].get("_truncated_oversize") is True, o
' "$tmp" || fail_msg "case4: envelope-over-cap not flagged _truncated_oversize"
python3 -c 'import json,sys; json.loads(open(sys.argv[1]).read())' "$tmp" ||
  fail_msg "case4: oversize line is not valid JSON"
rm -f "$tmp"

# Case 5: truncating in the middle of a multibyte char must still yield valid
# UTF-8 JSON (decode errors='replace'), not a broken line.
tmp=$(mktemp)
euros=$(python3 -c 'print("€" * 1000, end="")')
payload=$(jq -nc --arg o "$euros" '{call_id:"c5", output:{stdout:$o, stderr:""}}')
echo "$payload" | CLAUDE_LOG_MAX_LINE_BYTES=512 python3 hooks/lib/jsonl_write.py "$tmp"
n=$(line_bytes "$tmp")
[ "$n" -le 600 ] || fail_msg "case5: line $n bytes exceeds 512 cap (+leeway)"
python3 -c 'import json,sys; json.loads(open(sys.argv[1]).read())' "$tmp" ||
  fail_msg "case5: multibyte-boundary truncation produced invalid JSON"
rm -f "$tmp"

# Case 6 (#116): a large `args` on a pre row is trimmed to the cap. Previously
# truncate_output only touched output.{stdout,stderr}, so args bypassed the cap.
tmp=$(mktemp)
bigc=$(python3 -c 'print("x" * 5000, end="")')
payload=$(jq -nc --arg c "$bigc" '{call_id:"c6", event:"pre", args:{content:$c}}')
echo "$payload" | CLAUDE_LOG_MAX_LINE_BYTES=1024 python3 hooks/lib/jsonl_write.py "$tmp"
n=$(line_bytes "$tmp")
[ "$n" -le 1044 ] || fail_msg "case6: args not trimmed, line $n bytes exceeds 1024 cap"
grep -qF '_truncated_bytes' "$tmp" || fail_msg "case6: missing _truncated_bytes on large args"
rm -f "$tmp"

# Case 7 (#116): a freshly created log file is 0600 and its dir 0700, so other
# local users cannot read command args/output.
statmode() { stat -f '%Lp' "$1" 2>/dev/null || stat -c '%a' "$1"; }
tmpd=$(mktemp -d)
logf="$tmpd/sub/tool.jsonl"
echo '{"call_id":"c7","output":{"stdout":"hi","stderr":""}}' |
  python3 hooks/lib/jsonl_write.py "$logf"
[ "$(statmode "$logf")" = "600" ] ||
  fail_msg "case7: log file mode $(statmode "$logf") (want 600)"
[ "$(statmode "$tmpd/sub")" = "700" ] ||
  fail_msg "case7: log dir mode $(statmode "$tmpd/sub") (want 700)"
rm -rf "$tmpd"

if [ "$fail" -eq 0 ]; then
  echo "test-truncate: PASS"
else
  echo "test-truncate: $fail FAILURE(S)"
  exit 1
fi
