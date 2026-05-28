#!/usr/bin/env bash
# Comprehensive redaction coverage including adversarial backtracking inputs.
set -uo pipefail
cd "$(dirname "$0")/.."

fail=0
fail_msg() { echo "FAIL: $1" >&2; fail=$((fail+1)); }

run_redact() {
    local input="$1"
    python3 hooks/lib/redact.py <<<"$input"
}

# Each case: (input_value, must_appear_in_output, must_NOT_appear_in_output)
declare -a cases=(
    'eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.AbCdEfGh|***JWT***|eyJhbGciOiJIUzI1NiJ9'
    'AKIAIOSFODNN7EXAMPLE|***AWS_KEY***|AKIAIOSFODNN7EXAMPLE'
    'ghp_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa|***GH_TOKEN***|ghp_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
    'sk-ant-api03-xyzABC123|***ANTHROPIC_KEY***|sk-ant-api03'
    'sk-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa|***OPENAI_KEY***|sk-aaaaaaaaaaaaaaaaaaaa'
    'password=hunter2|password=***|hunter2'
    'TOKEN=secret-value|TOKEN=***|secret-value'
    '--token=mytoken|--token=***|mytoken'
    'Authorization: Bearer xyz|Authorization: ***|Bearer xyz'
    # P1-4: extended patterns (compound env vars, URL userinfo, GH PATs, AWS STS)
    'export DB_PASSWORD=hunter2|DB_PASSWORD=***|hunter2'
    'AWS_SECRET_ACCESS_KEY=wJalrXUtnFEMIK7MDENGbPxRfiCYEXAMPLEKEY|AWS_SECRET_ACCESS_KEY=***|wJalrXUtnFEMI'
    'APP_SECRET_KEY=very-secret-app-key|APP_SECRET_KEY=***|very-secret-app-key'
    'psql postgresql://admin:SuperSecret123@db.internal/prod|admin:***@|SuperSecret123'
    'github_pat_11ABCDEFG1234567890abcdefghijklmnop|***GH_PAT***|github_pat_11ABCDEFG'
    'ASIAIOSFODNN7EXAMPLE|***AWS_STS_KEY***|ASIAIOSFODNN7EXAMPLE'
)

for c in "${cases[@]}"; do
    inp="${c%%|*}"
    rest="${c#*|}"
    must="${rest%%|*}"
    mustnot="${rest##*|}"
    payload=$(jq -nc --arg v "$inp" '{value: $v}')
    out=$(echo "$payload" | python3 hooks/lib/redact.py)
    val=$(echo "$out" | jq -r '.value')
    if ! echo "$val" | grep -qF -e "$must"; then
        fail_msg "input=$inp -> $val (missing $must)"
    fi
    if echo "$val" | grep -qF -e "$mustnot"; then
        fail_msg "input=$inp -> $val (still contains $mustnot)"
    fi
done

# Adversarial backtracking input — must complete fast
adversarial=$(python3 -c 'print("a" * 5000 + "@" + "b" * 5000)')
payload=$(jq -nc --arg v "$adversarial" '{value: $v}')
# Portable 5s timeout: GNU `timeout`/`gtimeout` if available, else Python wrapper.
if command -v timeout >/dev/null 2>&1; then
    TIMEOUT_BIN="timeout"
elif command -v gtimeout >/dev/null 2>&1; then
    TIMEOUT_BIN="gtimeout"
else
    TIMEOUT_BIN=""
fi
SECONDS=0
if [ -n "$TIMEOUT_BIN" ]; then
    echo "$payload" | "$TIMEOUT_BIN" 5s python3 hooks/lib/redact.py >/dev/null \
        || fail_msg "redact.py timed out on adversarial input"
else
    echo "$payload" | python3 -c '
import subprocess, sys
try:
    sys.exit(subprocess.run([sys.executable, "hooks/lib/redact.py"],
                            stdin=sys.stdin, timeout=5).returncode)
except subprocess.TimeoutExpired:
    sys.exit(124)
' >/dev/null || fail_msg "redact.py timed out on adversarial input"
fi
[ "$SECONDS" -lt 5 ] || fail_msg "redact.py took $SECONDS s (too slow)"

# Recursive structure
nested='{"a":{"b":["password=foo", "ok"]}}'
out=$(echo "$nested" | python3 hooks/lib/redact.py)
echo "$out" | jq -e '.a.b[0] | test("\\*\\*\\*")' >/dev/null \
    || fail_msg "nested redaction failed: $out"

# H11: redact-existing-logs.py re-redacts a captured log in place.
tmplog=$(mktemp)
printf '%s\n' '{"args":{"command":"export GH=ghp_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}}' > "$tmplog"
printf '%s\n' 'this line is not json' >> "$tmplog"
python3 scripts/redact-existing-logs.py "$tmplog" >/dev/null
if grep -qF 'ghp_aaaa' "$tmplog"; then
    fail_msg "H11: secret not redacted in log file"
fi
grep -qF '***GH_TOKEN***' "$tmplog" || fail_msg "H11: redaction marker missing in log file"
grep -qF 'this line is not json' "$tmplog" || fail_msg "H11: non-JSON line not preserved"
rm -f "$tmplog"

if [ "$fail" -eq 0 ]; then
    echo "test-redaction: PASS"
else
    echo "test-redaction: $fail FAILURE(S)"
    exit 1
fi
