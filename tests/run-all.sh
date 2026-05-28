#!/usr/bin/env bash
# Run all claude-defaults test scripts. Exit non-zero on any failure.
set -uo pipefail

cd "$(dirname "$0")/.."
TESTS=(
    tests/test-settings-valid.sh
    tests/test-redaction.sh
    tests/test-hooks.sh
    tests/test-guard-hooks.sh
    tests/test-install.sh
)

fail=0
for t in "${TESTS[@]}"; do
    if [ ! -x "$t" ]; then
        echo "SKIP: $t (not executable or missing)"
        continue
    fi
    echo ""
    echo "=== $t ==="
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
