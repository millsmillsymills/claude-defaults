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
    # H3: Slack tokens
    'xoxb-12345678901-abcdefghijklmnopqrst|***SLACK_TOKEN***|xoxb-12345678901'
    # H5: modern OpenAI project keys (contain - and _, longer than 80 chars)
    'sk-proj-T3BlbkFJabcdefghijklmnopqrstuvwx|***OPENAI_KEY***|sk-proj-T3BlbkFJ'
    # M1: URL userinfo password shorter than 4 chars
    'postgresql://admin:abc@db.internal/prod|admin:***@|:abc@'
    # M2: lowercase / mixed-case compound secret env vars
    'database_password=hunter2value|***|hunter2value'
    'Db_Password=hunter2value|***|hunter2value'
    # L4: named secret with a value shorter than 3 chars
    'secret=xy|secret=***|=xy'
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

# H4: PEM private key blocks (multiline; needs DOTALL pattern)
pem=$(printf -- '-----BEGIN RSA PRIVATE KEY-----\nMIIEsecretbodyABC\n-----END RSA PRIVATE KEY-----')
pem_out=$(jq -nc --arg v "$pem" '{value:$v}' | python3 hooks/lib/redact.py | jq -r '.value')
echo "$pem_out" | grep -qF '***PRIVATE_KEY***' \
    || fail_msg "PEM key not redacted: $pem_out"
if echo "$pem_out" | grep -qF 'MIIEsecretbodyABC'; then
    fail_msg "PEM key body leaked: $pem_out"
fi

# C1: secrets stored as JSON values under sensitive dict keys (not key=value strings)
keyed='{"password":"plaintextpw","env":{"API_KEY":"plaintextapikey"},"note":"hello world"}'
keyed_out=$(echo "$keyed" | python3 hooks/lib/redact.py)
echo "$keyed_out" | jq -e '.password=="***"' >/dev/null \
    || fail_msg "key-aware: top-level password value not redacted: $keyed_out"
echo "$keyed_out" | jq -e '.env.API_KEY=="***"' >/dev/null \
    || fail_msg "key-aware: nested API_KEY value not redacted: $keyed_out"
echo "$keyed_out" | jq -e '.note=="hello world"' >/dev/null \
    || fail_msg "key-aware: benign key clobbered: $keyed_out"

# L7: invalid JSON must fail fast (exit 1, actionable message).
err=$(printf 'not-json{' | python3 hooks/lib/redact.py 2>&1 >/dev/null)
rc=$?
[ "$rc" -eq 1 ] || fail_msg "invalid JSON did not exit 1 (rc=$rc)"
echo "$err" | grep -qF 'not valid JSON' \
    || fail_msg "invalid JSON missing 'not valid JSON' message: $err"

if [ "$fail" -eq 0 ]; then
    echo "test-redaction: PASS"
else
    echo "test-redaction: $fail FAILURE(S)"
    exit 1
fi
