#!/usr/bin/env bash
# Run all claude-defaults test scripts. Exit non-zero on any failure.
set -uo pipefail

cd "$(dirname "$0")/.." || exit 1
TESTS=(
  tests/test-settings-valid.sh
  tests/test-redaction.sh
  tests/test-redact-existing.sh
  tests/test-truncate.sh
  tests/test-hooks.sh
  tests/test-guard-hooks.sh
  tests/test-hook-resilience.sh
  tests/test-install.sh
  tests/test-doctor.sh
  tests/test-statusline.sh
)

fail=0
for t in "${TESTS[@]}"; do
  echo ""
  echo "=== $t ==="
  # A missing/unrunnable test is a hard failure, not a silent skip -- a
  # dropped +x bit must not let the suite report all-green with 0 tests run.
  if [ ! -f "$t" ]; then
    echo "FAIL: $t (missing)"
    fail=$((fail + 1))
    continue
  fi
  if bash "$t"; then
    echo "PASS: $t"
  else
    echo "FAIL: $t"
    fail=$((fail + 1))
  fi
done

echo ""
if [ "$fail" -eq 0 ]; then
  echo "ALL TESTS PASSED"
  exit 0
else
  echo "FAILED: $fail test script(s)"
  exit 1
fi
