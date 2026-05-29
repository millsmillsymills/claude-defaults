#!/usr/bin/env bash
# redact-existing-logs.py: preserves file mode, redacts secrets, keeps non-JSON
# and undecodable bytes intact.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

fail=0
fail_msg() { echo "FAIL: $1" >&2; fail=$((fail + 1)); }

workdir=$(mktemp -d)
trap 'rm -rf "$workdir"' EXIT

log="$workdir/tool-calls.jsonl"
printf '%s\n' '{"args":{"command":"export GH=ghp_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}}' >"$log"
printf '%s\n' 'this line is not json' >>"$log"
# Undecodable byte (0xFF is invalid UTF-8) must not abort the run.
printf 'bad-byte:\xff:end\n' >>"$log"
chmod 0644 "$log"

python3 scripts/redact-existing-logs.py "$log" >/dev/null \
    || fail_msg "script exited non-zero"

if grep -qF 'ghp_aaaa' "$log"; then
    fail_msg "secret not redacted"
fi
grep -qF '***GH_TOKEN***' "$log" || fail_msg "redaction marker missing"
grep -qF 'this line is not json' "$log" || fail_msg "non-JSON line not preserved"
# LC_ALL=C + -a: the 0xFF byte is invalid UTF-8, so a locale-aware grep would
# either skip the line or error ("illegal byte sequence"). The byte must survive
# the round-trip verbatim via surrogateescape.
LC_ALL=C grep -qaF 'bad-byte:' "$log" || fail_msg "undecodable line dropped"
LC_ALL=C grep -qaF $'\xff' "$log" || fail_msg "undecodable byte not preserved verbatim"

# File mode must remain 0644 (not tightened to mkstemp's 0600).
mode=$(stat -f '%Lp' "$log" 2>/dev/null || stat -c '%a' "$log")
[ "$mode" = "644" ] || fail_msg "mode changed to $mode (expected 644)"

if [ "$fail" -eq 0 ]; then
    echo "test-redact-existing: PASS"
else
    echo "test-redact-existing: $fail FAILURE(S)"
    exit 1
fi
