#!/usr/bin/env bash
# statusline.sh must render (exit 0, non-empty) for every session shape:
# git repo, non-git dir, non-existent dir, multi-word model, empty/invalid stdin.
set -uo pipefail
cd "$(dirname "$0")/.."

fail=0
fail_msg() { echo "FAIL: $1" >&2; fail=$((fail + 1)); }

run_statusline() { bash scripts/statusline.sh 2>&1; }

# H6: a non-existent current_dir must not crash (git vars were unbound).
json='{"workspace":{"current_dir":"/nonexistent-dir-xyz"},"model":{"display_name":"Opus"}}'
out=$(printf '%s' "$json" | run_statusline)
rc=$?
[ "$rc" -eq 0 ] || fail_msg "non-existent dir: exit $rc"
[ -n "$out" ] || fail_msg "non-existent dir: empty output"

# H6: a real non-git directory must not crash under set -e (git rev-parse fails).
tmpd=$(mktemp -d)
json=$(jq -nc --arg d "$tmpd" '{workspace:{current_dir:$d},model:{display_name:"Opus"}}')
out=$(printf '%s' "$json" | run_statusline)
rc=$?
[ "$rc" -eq 0 ] || fail_msg "non-git dir: exit $rc"
[ -n "$out" ] || fail_msg "non-git dir: empty output"
rmdir "$tmpd" 2>/dev/null || true

# H7: a multi-word model name must not shift later TSV fields onto cost.
json='{"workspace":{"current_dir":"/tmp"},"model":{"display_name":"Claude Opus 4"},"cost":{"total_cost_usd":1.23}}'
out=$(printf '%s' "$json" | run_statusline)
echo "$out" | grep -qF 'Opus 4' || fail_msg "multi-word model mangled: $out"
echo "$out" | grep -qF '$1.23' || fail_msg "cost shifted by model split: $out"

# M10: empty stdin must degrade gracefully, not exit non-zero.
out=$(printf '' | run_statusline)
rc=$?
[ "$rc" -eq 0 ] || fail_msg "empty stdin: exit $rc"

# M10: invalid JSON must degrade gracefully, not exit non-zero.
out=$(printf 'not json {' | run_statusline)
rc=$?
[ "$rc" -eq 0 ] || fail_msg "invalid JSON stdin: exit $rc"

if [ "$fail" -eq 0 ]; then
  echo "test-statusline: PASS"
else
  echo "test-statusline: $fail FAILURE(S)"
  exit 1
fi
