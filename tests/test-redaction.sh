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
    # #3: Stripe secret keys (underscore form, distinct from OpenAI sk-)
    'sk_live_4eC39HqLyjWDarjtT1zdp7dc|***STRIPE_KEY***|sk_live_4eC39HqLyjWDarjtT1zdp7dc'
    'sk_test_4eC39HqLyjWDarjtT1zdp7dc|***STRIPE_KEY***|sk_test_4eC39HqLyjWDarjtT1zdp7dc'
    # #3: Stripe false positive — too short / wrong shape, must be preserved
    'sk_live_short|sk_live_short|***'
    # #3: Twilio API key SID (SK + 32 lowercase hex)
    'SKabcdef0123456789abcdef0123456789|***TWILIO_KEY***|SKabcdef0123456789abcdef0123456789'
    # #3: Twilio API key SID false positive — uppercase hex letters, not [a-f0-9]
    'SKABCDEF0123456789ABCDEF0123456789|SKABCDEF0123456789ABCDEF0123456789|***'
    # #3: Twilio Account SID (AC + 32 lowercase hex)
    'ACabcdef0123456789abcdef0123456789|***TWILIO_SID***|ACabcdef0123456789abcdef0123456789'
    # #3: Twilio Account SID false positive — too short, must be preserved
    'ACabcdef0123|ACabcdef0123|***'
    # #3: SendGrid API keys (SG.<22>.<43>)
    'SG.abcdefghijklmnopqrstuv.abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQ|***SENDGRID_KEY***|SG.abcdefghijklmnopqrstuv'
    # #3: SendGrid false positive — wrong segment lengths, must be preserved
    'SG.tooshort.alsotooshort|SG.tooshort.alsotooshort|***'
    # #38: Slack refresh (xoxe-) and app-level (xapp-) tokens
    'xoxe-1-abcdefghijklmnopqrst|***SLACK_TOKEN***|xoxe-1-abcdefghij'
    'xapp-1-A012345678-9876543210-abcdef|***SLACK_APP_TOKEN***|xapp-1-A012345678'
    # #38: key-aware over-match — value patterns still fire on real secrets
    'aws_secret_access_key=wJalrXUtnFEMIK7MDENGbPxRfiCYEXAMPLEKEY|aws_secret_access_key=***|wJalrXUtnFEMI'
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

# #38: key-aware match anchored to the key suffix — keys merely CONTAINING a
# secret word (analytics telemetry) must keep their values; trailing-segment
# secret keys must still be redacted.
anchored='{"csrf_token_count":5,"bearer_count":3,"last_authorization_at":"2026-01-01","aws_secret_access_key":"wJalrXUtnFEMI"}'
anchored_out=$(echo "$anchored" | python3 hooks/lib/redact.py)
echo "$anchored_out" | jq -e '.csrf_token_count==5' >/dev/null \
    || fail_msg "#38: csrf_token_count over-matched: $anchored_out"
echo "$anchored_out" | jq -e '.bearer_count==3' >/dev/null \
    || fail_msg "#38: bearer_count over-matched: $anchored_out"
echo "$anchored_out" | jq -e '.last_authorization_at=="2026-01-01"' >/dev/null \
    || fail_msg "#38: last_authorization_at over-matched: $anchored_out"
echo "$anchored_out" | jq -e '.aws_secret_access_key=="***"' >/dev/null \
    || fail_msg "#38: aws_secret_access_key value not redacted: $anchored_out"

# #50: camelCase secret keys end in the secret word with no `_`/`-` separator.
# The suffix anchor must still catch them, or AWS/OAuth/Stripe SDK payloads
# (secretAccessKey, accessToken, refreshToken, clientSecret, ...) leak verbatim.
camel='{"secretAccessKey":"wJalrXUtnFEMI","accessToken":"ya29.AAAA","refreshToken":"1//abcdef","clientSecret":"cs_live_x","sessionToken":"st_x","bearerToken":"bt_x","authToken":"at_x"}'
camel_out=$(echo "$camel" | python3 hooks/lib/redact.py)
for k in secretAccessKey accessToken refreshToken clientSecret sessionToken bearerToken authToken; do
    echo "$camel_out" | jq -e --arg k "$k" '.[$k]=="***"' >/dev/null \
        || fail_msg "#50: camelCase secret key $k not redacted: $camel_out"
done
# camelCase analytics keys ending in a non-secret word must survive.
camel_neg='{"accessTokenCount":7,"lastAuthorizationAt":"2026-01-01","tokenizer":"gpt"}'
camel_neg_out=$(echo "$camel_neg" | python3 hooks/lib/redact.py)
echo "$camel_neg_out" | jq -e '.accessTokenCount==7' >/dev/null \
    || fail_msg "#50: accessTokenCount over-matched: $camel_neg_out"
echo "$camel_neg_out" | jq -e '.lastAuthorizationAt=="2026-01-01"' >/dev/null \
    || fail_msg "#50: lastAuthorizationAt over-matched: $camel_neg_out"
echo "$camel_neg_out" | jq -e '.tokenizer=="gpt"' >/dev/null \
    || fail_msg "#50: tokenizer over-matched: $camel_neg_out"

# #3: GCP service-account private keys are PEM blocks — covered by the existing
# DOTALL PRIVATE KEY pattern, no dedicated pattern needed.
gcp_pem=$(printf -- '-----BEGIN PRIVATE KEY-----\nMIIEvgIBADANBgkqGCPserviceacct\n-----END PRIVATE KEY-----')
gcp_out=$(jq -nc --arg v "$gcp_pem" '{value:$v}' | python3 hooks/lib/redact.py | jq -r '.value')
echo "$gcp_out" | grep -qF '***PRIVATE_KEY***' \
    || fail_msg "#3: GCP PEM key not redacted: $gcp_out"
if echo "$gcp_out" | grep -qF 'MIIEvgIBADANBgkqGCPserviceacct'; then
    fail_msg "#3: GCP PEM key body leaked: $gcp_out"
fi

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
