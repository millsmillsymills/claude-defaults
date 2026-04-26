# Centralize Claude Code Config — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Evolve the existing `millsmillsymills/claude-defaults` GitHub repo into a single source of truth for global Claude Code config — adds rich JSONL tool/MCP logging, expanded safety hooks, anti-rationalization Stop hook, Go to the CLAUDE.md style guide, and switches from copy-based install to a hybrid (symlinks for content + jq-merge for `settings.json`).

**Architecture:** Hybrid distribution — `~/.claude/CLAUDE.md`, `commands/<each>.md`, `hooks/<each>.sh`, `hooks/lib/<each>`, `agents/<each>.md`, `skills/<each>/`, and `statusline.sh` become per-file/per-skill symlinks pointing into the repo. `~/.claude/settings.json` stays a real file populated by jq-merging `<repo>/settings.json` over the existing local one (preserves `enabledPlugins`, `extraKnownMarketplaces`, `skipAutoPermissionPrompt`). Logging hook fires on `PreToolUse|PostToolUse` matcher `*` and writes redacted JSONL to `~/.claude/logs/`.

**Tech Stack:** Bash (hooks, install/validate/uninstall/test scripts), Python 3 (`hooks/lib/redact.py`, `hooks/lib/jsonl-write.py`), jq (JSON manipulation in shell), Claude Code's native hook system, GitHub for hosting.

**Spec:** `docs/superpowers/specs/2026-04-26-centralize-claude-config-design.md`

**Working directory:** `~/Desktop/Projects/claude-defaults/` (currently a near-empty local dir; Task 1 clones the GitHub remote over it while preserving the spec).

---

## File Structure

| Path (in repo) | New / Modify | Purpose |
|---|---|---|
| `settings.json` | Modify | Add `hooks` block + extend `permissions.allow` |
| `claude-md-template.md` | Modify | Add Go section + output preferences + comments policy |
| `scripts/install.sh` | Modify | Hybrid install: symlinks + jq-merge + per-skill skill symlinks + log dir |
| `scripts/uninstall.sh` | Create | Reverse install, restore latest backup |
| `scripts/validate.sh` | Modify | Verify symlinks, log dir, hook executability, settings hooks block |
| `hooks/safety-block.sh` | Create | PreToolUse Bash — extended destructive-pattern blocks |
| `hooks/safety-warn.sh` | Create | PreToolUse Edit\|Write — warn on sensitive paths |
| `hooks/log-tool-calls.sh` | Create | PreToolUse + PostToolUse `*` → redacted JSONL |
| `hooks/log-rotate.sh` | Create | SessionEnd — gzip-rotate large logs, prune old |
| `hooks/lib/redact.py` | Create | Secret-pattern redaction (JWT, AWS, GH, Anthropic, OpenAI, password=, etc.) |
| `hooks/lib/jsonl-write.py` | Create | Atomic JSON-line append with 1 MB truncation |
| `hooks/lib/common.sh` | Create | Shared bash helpers (script_dir, jq extractors) |
| `tests/run-all.sh` | Create | Runs all four test scripts; exit non-zero on any fail |
| `tests/test-install.sh` | Create | install/uninstall idempotency in isolated `$HOME` |
| `tests/test-hooks.sh` | Create | Per-hook input/exit-code/log assertions |
| `tests/test-redaction.sh` | Create | Secret-pattern coverage + adversarial backtracking |
| `tests/test-settings-valid.sh` | Create | settings.json parses + hook paths exist |
| `tests/fixtures/*.json` | Create | Mock Claude hook stdin JSON for each tool |
| `agents/.gitkeep` | Create | Scaffold (empty global agents dir) |
| `skills/.gitkeep` | Create | Scaffold (empty global skills dir) |
| `docs/HOOKS.md` | Create | Every hook documented + matcher cheatsheet |
| `docs/LOGGING.md` | Create | Schema, jq query examples, rotation, redaction patterns |
| `docs/PROMOTION-RATIONALE.md` | Create | Why nothing promoted from `resurgent/.claude/` |
| `README.md` | Modify | New sections: Logging, Anti-rationalization, Updated install instructions |
| `docs/superpowers/specs/2026-04-26-centralize-claude-config-design.md` | (preserved) | The brainstorm spec — already exists locally |

---

## Task 1: Foundation — clone GitHub repo over local dir, preserving spec

**Files:**
- Preserve: `~/Desktop/Projects/claude-defaults/.claude/settings.local.json`
- Preserve: `~/Desktop/Projects/claude-defaults/docs/superpowers/specs/2026-04-26-centralize-claude-config-design.md`
- Create: `~/Desktop/Projects/claude-defaults/.git/` (via clone)

- [ ] **Step 1: Stage local-only files aside**

```bash
STAGE_DIR="/tmp/claude-defaults-stage-$(date +%s)"
mkdir -p "$STAGE_DIR"
cd ~/Desktop/Projects/claude-defaults
# Move every visible and dotfile entry except none-existent .git
for entry in .[!.]* * 2>/dev/null; do
    [ -e "$entry" ] || continue
    mv "$entry" "$STAGE_DIR/"
done
# Verify dir is now empty
ls -la
```

Expected: only `.` and `..` in the directory listing. `$STAGE_DIR` contains `.claude/`, `docs/`, and any other local-only content.

- [ ] **Step 2: Clone GitHub repo into the now-empty dir**

```bash
git clone https://github.com/millsmillsymills/claude-defaults.git ~/Desktop/Projects/claude-defaults
cd ~/Desktop/Projects/claude-defaults
git status
git log --oneline -5
```

Expected: clone completes, `git status` shows clean working tree on `main`, log shows the existing commits (most recent dated 2026-02-23).

- [ ] **Step 3: Restore preserved files from stage dir**

```bash
# Recreate spec dir and restore spec
mkdir -p docs/superpowers/specs
mv "$STAGE_DIR/docs/superpowers/specs/2026-04-26-centralize-claude-config-design.md" \
   docs/superpowers/specs/

# Restore .claude/settings.local.json
mkdir -p .claude
mv "$STAGE_DIR/.claude/settings.local.json" .claude/

# Move plans dir if it was created
if [ -d "$STAGE_DIR/docs/superpowers/plans" ]; then
    mkdir -p docs/superpowers/plans
    mv "$STAGE_DIR/docs/superpowers/plans/"* docs/superpowers/plans/
fi

# Verify nothing else lingers in stage
ls -la "$STAGE_DIR"
```

Expected: spec and settings.local.json back in place; stage dir contains only directory shells (no remaining files we needed to keep).

- [ ] **Step 4: Create feature branch and commit the spec**

```bash
git checkout -b feat/centralize-config
git status   # spec + plans should show as untracked
git add docs/superpowers/specs/2026-04-26-centralize-claude-config-design.md \
        docs/superpowers/plans/2026-04-26-centralize-claude-config.md
# Add to .gitignore: .claude/settings.local.json (Claude Code state, not config)
echo ".claude/settings.local.json" >> .gitignore
git add .gitignore
git commit -m "docs: add centralization design spec and implementation plan"
```

Expected: commit succeeds; `git log --oneline -3` shows our new commit on top of `main`.

- [ ] **Step 5: Sanity-check baseline tests still pass**

```bash
bash scripts/validate.sh || true   # may fail since we haven't installed yet — that's fine
# Just verify the script runs without syntax errors:
bash -n scripts/install.sh && echo "install.sh: syntax OK"
bash -n scripts/validate.sh && echo "validate.sh: syntax OK"
bash -n scripts/statusline.sh && echo "statusline.sh: syntax OK"
```

Expected: all three "syntax OK" lines printed. validate.sh may fail with missing files (that's expected — we haven't installed).

---

## Task 2: Create `hooks/lib/redact.py` (TDD)

**Files:**
- Create: `hooks/lib/redact.py`
- Test: `tests/test-redaction.sh` (full version in Task 17; minimal smoke here)

- [ ] **Step 1: Write the failing test (inline Python smoke)**

```bash
mkdir -p hooks/lib
cat > /tmp/test_redact_smoke.py <<'PY'
import sys, json, subprocess
cases = [
    ("Bearer eyJhbGc.eyJzdWI.AbCd", "***JWT***"),
    ("AKIAIOSFODNN7EXAMPLE", "***AWS_KEY***"),
    ("ghp_abcdef1234567890ABCDEF1234567890abcdef", "***GH_TOKEN***"),
    ("sk-ant-api03-xyzABC", "***ANTHROPIC_KEY***"),
    ("password=hunter2", "password=***"),
    ("--token=mysecret", "--token=***"),
    ("Authorization: Bearer xyz", "Authorization: ***"),
    ("safe text with no secrets", "safe text with no secrets"),
]
fail = 0
for inp, expected_substr in cases:
    payload = json.dumps({"value": inp})
    out = subprocess.run(
        [sys.executable, "hooks/lib/redact.py"],
        input=payload, capture_output=True, text=True, timeout=5
    )
    if out.returncode != 0:
        print(f"FAIL (exit {out.returncode}): {inp}", file=sys.stderr); fail += 1; continue
    result = json.loads(out.stdout)["value"]
    if expected_substr not in result:
        print(f"FAIL: {inp!r} -> {result!r} (expected to contain {expected_substr!r})", file=sys.stderr)
        fail += 1
sys.exit(0 if fail == 0 else 1)
PY
python3 /tmp/test_redact_smoke.py
```

Expected: FAIL — `hooks/lib/redact.py` doesn't exist yet (subprocess returns non-zero or python errors).

- [ ] **Step 2: Implement `hooks/lib/redact.py`**

```python
#!/usr/bin/env python3
"""Redact secret patterns from JSON values.

Reads a JSON value from stdin, walks it recursively, replaces secret-like
substrings inside any string with REDACTED markers, and writes the
modified JSON to stdout.

Patterns covered:
  - JWT tokens (eyJ...eyJ...sig)
  - AWS access keys (AKIA + 16 chars)
  - GitHub personal/OAuth/server/user tokens (gh[opsu]_...)
  - Anthropic API keys (sk-ant-...)
  - OpenAI API keys (sk-... 48 chars)
  - key=value with key in {password, passwd, secret, token, api_key, api-key,
    bearer, authorization}
  - --flag=value with flag in {password, token, secret, api-key, api_key}

Usage: python3 redact.py < input.json > output.json
"""
import json
import re
import sys

# Compiled patterns (bounded to avoid catastrophic backtracking).
_PATTERNS: list[tuple[re.Pattern[str], str]] = [
    # JWT (three base64url segments separated by dots, first two start with eyJ)
    (re.compile(r"eyJ[A-Za-z0-9_\-]{4,}\.eyJ[A-Za-z0-9_\-]{4,}\.[A-Za-z0-9_\-]{4,}"),
     "***JWT***"),
    # AWS access key
    (re.compile(r"\bAKIA[0-9A-Z]{16}\b"), "***AWS_KEY***"),
    # GitHub tokens (ghp_, gho_, ghs_, ghu_)
    (re.compile(r"\bgh[opsu]_[A-Za-z0-9]{36,}\b"), "***GH_TOKEN***"),
    # Anthropic API keys
    (re.compile(r"\bsk-ant-[A-Za-z0-9_\-]{8,}\b"), "***ANTHROPIC_KEY***"),
    # OpenAI keys (sk- followed by 40+ base62 chars; bounded)
    (re.compile(r"\bsk-[A-Za-z0-9]{40,80}\b"), "***OPENAI_KEY***"),
    # key=value secrets (case-insensitive key)
    (re.compile(
        r"(?i)\b(password|passwd|secret|token|api[_-]?key|bearer|authorization)"
        r"(\s*[:=]\s*)([^\s,;'\"]{3,})"
    ), r"\1\2***"),
    # --flag=value CLI secrets
    (re.compile(
        r"(--(?:password|token|secret|api[_-]?key))(=)([^\s,;'\"]{3,})"
    ), r"\1\2***"),
]


def redact_string(s: str) -> str:
    for pattern, replacement in _PATTERNS:
        s = pattern.sub(replacement, s)
    return s


def redact_value(v):
    if isinstance(v, str):
        return redact_string(v)
    if isinstance(v, list):
        return [redact_value(x) for x in v]
    if isinstance(v, dict):
        return {k: redact_value(val) for k, val in v.items()}
    return v


def main() -> int:
    try:
        data = json.load(sys.stdin)
    except json.JSONDecodeError as exc:
        print(f"redact: input is not valid JSON: {exc}", file=sys.stderr)
        return 1
    redacted = redact_value(data)
    json.dump(redacted, sys.stdout)
    return 0


if __name__ == "__main__":
    sys.exit(main())
```

```bash
chmod +x hooks/lib/redact.py
```

- [ ] **Step 3: Run smoke test to verify pass**

```bash
python3 /tmp/test_redact_smoke.py && echo "redact.py PASS"
rm /tmp/test_redact_smoke.py
```

Expected: "redact.py PASS" printed; exit code 0.

- [ ] **Step 4: Commit**

```bash
git add hooks/lib/redact.py
git commit -m "feat(hooks): add redact.py for secret-pattern redaction in tool logs"
```

---

## Task 3: Create `hooks/lib/jsonl-write.py` (TDD)

**Files:**
- Create: `hooks/lib/jsonl-write.py`

- [ ] **Step 1: Write the failing test**

```bash
cat > /tmp/test_jsonl_smoke.py <<'PY'
import os, sys, json, subprocess, tempfile, threading

with tempfile.TemporaryDirectory() as td:
    log = os.path.join(td, "out.jsonl")

    # Test 1: basic write
    payload = json.dumps({"hello": "world", "n": 1})
    r = subprocess.run([sys.executable, "hooks/lib/jsonl-write.py", log],
                       input=payload, capture_output=True, text=True, timeout=5)
    assert r.returncode == 0, f"basic write exit {r.returncode}: {r.stderr}"
    with open(log) as f:
        line = f.readline().rstrip("\n")
    parsed = json.loads(line)
    assert parsed == {"hello": "world", "n": 1}, f"got {parsed}"
    print("test 1 (basic write): PASS")

    # Test 2: large output truncation
    huge = "X" * (2 * 1024 * 1024)  # 2 MB
    payload = json.dumps({"output": {"stdout": huge, "stderr": ""}})
    r = subprocess.run([sys.executable, "hooks/lib/jsonl-write.py", log],
                       input=payload, capture_output=True, text=True, timeout=10)
    assert r.returncode == 0, f"truncation exit {r.returncode}: {r.stderr}"
    with open(log) as f:
        lines = f.readlines()
    assert len(lines) == 2, f"expected 2 lines, got {len(lines)}"
    parsed = json.loads(lines[1])
    assert "_truncated_bytes" in parsed.get("output", {}), f"missing truncation marker: {parsed}"
    assert len(lines[1]) <= 1024 * 1024 + 4096, f"line too big: {len(lines[1])}"
    print("test 2 (truncation): PASS")

    # Test 3: concurrent appends are atomic
    def writer(i):
        subprocess.run([sys.executable, "hooks/lib/jsonl-write.py", log],
                       input=json.dumps({"i": i}), text=True, timeout=10, check=True)
    threads = [threading.Thread(target=writer, args=(i,)) for i in range(50)]
    [t.start() for t in threads]
    [t.join() for t in threads]
    with open(log) as f:
        new_lines = f.readlines()[2:]  # skip earlier 2 lines
    assert len(new_lines) == 50, f"expected 50 lines, got {len(new_lines)}"
    seen = set()
    for line in new_lines:
        obj = json.loads(line)
        seen.add(obj["i"])
    assert seen == set(range(50)), f"missing iterations: {set(range(50)) - seen}"
    print("test 3 (concurrent): PASS")

print("all tests PASS")
PY
python3 /tmp/test_jsonl_smoke.py
```

Expected: FAIL — `hooks/lib/jsonl-write.py` doesn't exist yet.

- [ ] **Step 2: Implement `hooks/lib/jsonl-write.py`**

```python
#!/usr/bin/env python3
"""Atomic-append a JSON object to a JSONL file with size truncation.

Reads JSON from stdin, ensures the serialized line is <= max bytes (truncating
inside output.stdout/output.stderr if needed), writes a single line via one
O_APPEND syscall (atomic on macOS APFS for the line sizes we produce).

Usage: python3 jsonl-write.py <output-file>

Env:
  CLAUDE_LOG_MAX_LINE_BYTES   max bytes per line (default 1048576 = 1 MB)

Exit codes:
  0   success, OR ENOSPC (silently dropped)
  1   fatal error (bad JSON, missing arg, permission denied)
"""
import errno
import json
import os
import sys

DEFAULT_MAX = 1024 * 1024  # 1 MB


def _truncate_output(obj: dict, max_bytes: int) -> dict:
    """If serialized JSON would exceed max_bytes, trim output.stdout/stderr."""
    serialized = json.dumps(obj, ensure_ascii=False)
    overhead = len((serialized + "\n").encode("utf-8")) - max_bytes
    if overhead <= 0:
        return obj

    output = obj.get("output")
    if not isinstance(output, dict):
        # Nothing structured to trim; truncate anything we can find.
        return obj

    truncated_total = 0
    for key in ("stdout", "stderr"):
        v = output.get(key)
        if not isinstance(v, str):
            continue
        encoded = v.encode("utf-8")
        if len(encoded) <= 256:
            continue
        # Reserve ~256 bytes of context, drop the middle.
        keep = max(256, len(encoded) - max(0, overhead - truncated_total))
        if keep < len(encoded):
            output[key] = encoded[:keep].decode("utf-8", errors="replace")
            truncated_total += len(encoded) - keep
        # Re-check size.
        serialized = json.dumps(obj, ensure_ascii=False)
        if len((serialized + "\n").encode("utf-8")) <= max_bytes:
            break

    if truncated_total > 0:
        output["_truncated_bytes"] = truncated_total

    return obj


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: jsonl-write.py <output-file>", file=sys.stderr)
        return 1
    out_path = sys.argv[1]
    max_bytes = int(os.environ.get("CLAUDE_LOG_MAX_LINE_BYTES", DEFAULT_MAX))

    try:
        obj = json.load(sys.stdin)
    except json.JSONDecodeError as exc:
        print(f"jsonl-write: stdin is not valid JSON: {exc}", file=sys.stderr)
        return 1

    obj = _truncate_output(obj, max_bytes)
    line = json.dumps(obj, ensure_ascii=False) + "\n"
    encoded = line.encode("utf-8")

    os.makedirs(os.path.dirname(out_path) or ".", exist_ok=True)
    try:
        fd = os.open(out_path, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o644)
        try:
            os.write(fd, encoded)
        finally:
            os.close(fd)
    except OSError as exc:
        if exc.errno == errno.ENOSPC:
            # Disk full — silently drop the line; never break a tool call.
            return 0
        print(f"jsonl-write: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
```

```bash
chmod +x hooks/lib/jsonl-write.py
```

- [ ] **Step 3: Run test to verify pass**

```bash
python3 /tmp/test_jsonl_smoke.py && echo "jsonl-write.py PASS"
rm /tmp/test_jsonl_smoke.py
```

Expected: all three sub-tests PASS, "all tests PASS" printed; exit 0.

- [ ] **Step 4: Commit**

```bash
git add hooks/lib/jsonl-write.py
git commit -m "feat(hooks): add jsonl-write.py with atomic append + 1MB truncation"
```

---

## Task 4: Create `hooks/lib/common.sh` (shared bash helpers)

**Files:**
- Create: `hooks/lib/common.sh`

- [ ] **Step 1: Write the smoke test**

```bash
cat > /tmp/test_common_sh.sh <<'BASH'
#!/usr/bin/env bash
set -euo pipefail

# Source common.sh
source hooks/lib/common.sh

# Test 1: SCRIPT_DIR_OF resolves through symlinks
ln -sf "$(pwd)/hooks/lib/common.sh" /tmp/common_link.sh
resolved=$(SCRIPT_DIR_OF /tmp/common_link.sh)
expected="$(pwd)/hooks/lib"
if [ "$resolved" = "$expected" ]; then
    echo "test 1 (script_dir resolve): PASS"
else
    echo "test 1 FAIL: got '$resolved', expected '$expected'" >&2
    exit 1
fi
rm /tmp/common_link.sh

# Test 2: claude_logs_dir returns expected path
got=$(claude_logs_dir)
expected="${HOME}/.claude/logs"
if [ "$got" = "$expected" ]; then
    echo "test 2 (logs dir): PASS"
else
    echo "test 2 FAIL: got '$got', expected '$expected'" >&2
    exit 1
fi

# Test 3: extract_jq_field returns value or null
input='{"session_id":"abc123","tool_name":"Bash"}'
got=$(echo "$input" | extract_jq_field '.session_id')
[ "$got" = "abc123" ] || { echo "test 3a FAIL: got '$got'" >&2; exit 1; }
got=$(echo "$input" | extract_jq_field '.missing')
[ "$got" = "null" ] || { echo "test 3b FAIL: got '$got'" >&2; exit 1; }
echo "test 3 (jq extract): PASS"

echo "all tests PASS"
BASH
bash /tmp/test_common_sh.sh
```

Expected: FAIL — `hooks/lib/common.sh` doesn't exist or `SCRIPT_DIR_OF` is undefined.

- [ ] **Step 2: Implement `hooks/lib/common.sh`**

```bash
#!/usr/bin/env bash
# Shared helpers for claude-defaults hooks.
#
# Source from a hook script:
#     SCRIPT_DIR=$(SCRIPT_DIR_OF "${BASH_SOURCE[0]}")
#     source "${SCRIPT_DIR}/lib/common.sh"
#
# Functions:
#   SCRIPT_DIR_OF <path>    - absolute dir of <path>, resolving symlinks
#   claude_logs_dir         - prints ~/.claude/logs
#   ensure_logs_dir         - mkdir -p the logs dir, idempotent
#   extract_jq_field <jq>   - reads stdin, runs jq with the expression,
#                             prints "null" on missing/empty (no error)

SCRIPT_DIR_OF() {
    local target="$1"
    # readlink -f is GNU; macOS lacks it. Use a portable fallback.
    if command -v greadlink >/dev/null 2>&1; then
        dirname "$(greadlink -f "$target")"
    elif readlink -f / >/dev/null 2>&1; then
        dirname "$(readlink -f "$target")"
    else
        # macOS-portable: cd into dir, follow symlink one level
        local link
        link=$(readlink "$target" || echo "$target")
        case "$link" in
            /*) dirname "$link" ;;
            *)  cd "$(dirname "$target")" && cd "$(dirname "$link")" && pwd ;;
        esac
    fi
}

claude_logs_dir() {
    echo "${HOME}/.claude/logs"
}

ensure_logs_dir() {
    mkdir -p "$(claude_logs_dir)" 2>/dev/null || true
}

extract_jq_field() {
    local expr="$1"
    jq -r "${expr} // \"null\"" 2>/dev/null || echo "null"
}
```

- [ ] **Step 3: Run test to verify pass**

```bash
bash /tmp/test_common_sh.sh && echo "common.sh PASS"
rm /tmp/test_common_sh.sh
```

Expected: all three tests PASS; "all tests PASS"; exit 0.

- [ ] **Step 4: Commit**

```bash
git add hooks/lib/common.sh
git commit -m "feat(hooks): add common.sh shared helpers (script_dir, jq extract)"
```

---

## Task 5: Create `hooks/log-tool-calls.sh` (TDD)

**Files:**
- Create: `hooks/log-tool-calls.sh`

- [ ] **Step 1: Write the smoke test**

```bash
cat > /tmp/test_log_tool_calls.sh <<'BASH'
#!/usr/bin/env bash
set -euo pipefail

LOG_DIR=$(mktemp -d)
export HOME="$LOG_DIR"
mkdir -p "$LOG_DIR/.claude/logs"

today=$(date +%Y-%m-%d)
log_file="$LOG_DIR/.claude/logs/tool-calls-${today}.jsonl"

# Test 1: pre call
pre_input='{
  "session_id": "test-session",
  "cwd": "/tmp/foo",
  "tool_name": "Bash",
  "tool_input": {"command": "git status"}
}'
echo "$pre_input" | bash hooks/log-tool-calls.sh pre
[ -f "$log_file" ] || { echo "test 1 FAIL: log file not created" >&2; exit 1; }
line=$(head -n 1 "$log_file")
echo "$line" | python3 -c '
import json, sys
o = json.loads(sys.stdin.read())
assert o["event"] == "pre", o
assert o["tool"] == "Bash", o
assert o["session_id"] == "test-session", o
assert o["cwd"] == "/tmp/foo", o
assert o["args"]["command"] == "git status", o
assert "call_id" in o, o
print("test 1 (pre row): PASS")
'

# Test 2: redaction of secrets in args
secret_input='{
  "session_id": "test-session",
  "cwd": "/tmp/foo",
  "tool_name": "Bash",
  "tool_input": {"command": "curl -H Authorization: Bearer ghp_abcdef1234567890ABCDEF1234567890abcdef api.example.com"}
}'
echo "$secret_input" | bash hooks/log-tool-calls.sh pre
last=$(tail -n 1 "$log_file")
echo "$last" | python3 -c '
import json, sys
o = json.loads(sys.stdin.read())
cmd = o["args"]["command"]
assert "ghp_abcdef" not in cmd, f"token leaked: {cmd}"
assert "***GH_TOKEN***" in cmd or "***" in cmd, f"not redacted: {cmd}"
print("test 2 (redaction): PASS")
'

# Test 3: MCP server parsing
mcp_input='{
  "session_id": "test-session",
  "cwd": "/tmp/foo",
  "tool_name": "mcp__playwright__browser_click",
  "tool_input": {"selector": "#submit"}
}'
echo "$mcp_input" | bash hooks/log-tool-calls.sh pre
last=$(tail -n 1 "$log_file")
echo "$last" | python3 -c '
import json, sys
o = json.loads(sys.stdin.read())
assert o["mcp_server"] == "playwright", o
print("test 3 (mcp parse): PASS")
'

# Test 4: post call computes duration
# First, write a pre call and capture call_id
pre_input='{
  "session_id": "test-session",
  "cwd": "/tmp/foo",
  "tool_name": "Bash",
  "tool_input": {"command": "sleep 0.1"}
}'
echo "$pre_input" | bash hooks/log-tool-calls.sh pre
sleep 0.15
post_input='{
  "session_id": "test-session",
  "cwd": "/tmp/foo",
  "tool_name": "Bash",
  "tool_input": {"command": "sleep 0.1"},
  "tool_response": {"stdout": "", "stderr": "", "exit_code": 0}
}'
echo "$post_input" | bash hooks/log-tool-calls.sh post
last=$(tail -n 1 "$log_file")
echo "$last" | python3 -c '
import json, sys
o = json.loads(sys.stdin.read())
assert o["event"] == "post", o
assert o["exit_status"] == 0, o
assert o["duration_ms"] >= 100, o
print("test 4 (post + duration): PASS")
'

echo "all tests PASS"
BASH
bash /tmp/test_log_tool_calls.sh
```

Expected: FAIL — `hooks/log-tool-calls.sh` doesn't exist.

- [ ] **Step 2: Implement `hooks/log-tool-calls.sh`**

```bash
#!/usr/bin/env bash
# PreToolUse + PostToolUse hook: append a redacted JSON line per tool call.
#
# Wire up in settings.json:
#   PreToolUse  -> matcher "*" -> command "$HOME/.claude/hooks/log-tool-calls.sh pre"
#   PostToolUse -> matcher "*" -> command "$HOME/.claude/hooks/log-tool-calls.sh post"
#
# Reads Claude Code hook stdin JSON, extracts metadata, redacts secrets via
# lib/redact.py, and atomic-appends one JSONL line via lib/jsonl-write.py.
#
# Pre call writes start time to ${TMPDIR}/claude-tool-${call_id}; post call
# reads it for duration_ms and deletes the temp file.
#
# Logging failures NEVER break a tool call -- everything is wrapped to exit 0.

set -uo pipefail

EVENT="${1:-pre}"
[ "$EVENT" = "pre" ] || [ "$EVENT" = "post" ] || EVENT="pre"

# Resolve our own location through symlink chain.
SCRIPT_DIR=$(cd "$(dirname "$(readlink "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")")" 2>/dev/null && pwd) || \
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="${SCRIPT_DIR}/lib"

# Read stdin once, reuse.
INPUT=$(cat)

LOG_DIR="${HOME}/.claude/logs"
mkdir -p "$LOG_DIR" 2>/dev/null || true
LOG_FILE="${LOG_DIR}/tool-calls-$(date +%Y-%m-%d).jsonl"

# Extract common fields (default to "null" / "unknown" on missing).
session_id=$(echo "$INPUT" | jq -r '.session_id // "unknown"' 2>/dev/null || echo "unknown")
cwd=$(echo "$INPUT" | jq -r '.cwd // "unknown"' 2>/dev/null || echo "unknown")
tool=$(echo "$INPUT" | jq -r '.tool_name // "unknown"' 2>/dev/null || echo "unknown")

# Parse mcp_server from tool name (mcp__<server>__<method>).
if [[ "$tool" == mcp__* ]]; then
    mcp_server=$(echo "$tool" | sed -E 's/^mcp__([^_]+(_[^_]+)*?)__.*/\1/')
else
    mcp_server="null"
fi

# call_id: nanosecond-ish timestamp + PID. macOS `date` has no %N, use python.
call_id=$(python3 -c 'import time, os; print(f"{int(time.time()*1_000_000):d}-{os.getpid()}")')
ts=$(python3 -c 'import datetime; print(datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="milliseconds").replace("+00:00","Z"))')

if [ "$EVENT" = "pre" ]; then
    # Capture start time for duration calculation later.
    echo "$call_id $(python3 -c 'import time; print(time.time())')" > "${TMPDIR:-/tmp}/claude-tool-${call_id}" 2>/dev/null || true

    args=$(echo "$INPUT" | jq -c '.tool_input // {}' 2>/dev/null || echo "{}")
    if [ "$mcp_server" = "null" ]; then
        mcp_field='null'
    else
        mcp_field=$(printf '%s' "$mcp_server" | jq -R -s '.|gsub("\n$";"")')
    fi
    payload=$(jq -nc \
        --arg ts "$ts" \
        --arg sid "$session_id" \
        --arg cwd "$cwd" \
        --arg cid "$call_id" \
        --arg tool "$tool" \
        --argjson mcp "$mcp_field" \
        --argjson args "$args" \
        '{ts:$ts, session_id:$sid, cwd:$cwd, event:"pre", call_id:$cid, tool:$tool, mcp_server:$mcp, args:$args}')
else
    # Post call.
    # Find the most recent matching pre-row for this session+tool to compute duration.
    # Simpler approach: scan recent temp files for the same session and tool that haven't been claimed.
    start_file=""
    start_time=""
    for f in "${TMPDIR:-/tmp}"/claude-tool-*; do
        [ -f "$f" ] || continue
        # Match by session if present; else just take the most recent.
        line=$(cat "$f" 2>/dev/null) || continue
        start_file="$f"
        start_time=$(echo "$line" | awk '{print $2}')
        break
    done
    if [ -n "$start_time" ]; then
        end_time=$(python3 -c 'import time; print(time.time())')
        duration_ms=$(python3 -c "print(int(($end_time - $start_time) * 1000))")
        rm -f "$start_file" 2>/dev/null || true
    else
        duration_ms=0
    fi

    exit_status=$(echo "$INPUT" | jq -r '.tool_response.exit_code // .tool_response.exitCode // 0' 2>/dev/null || echo 0)
    output=$(echo "$INPUT" | jq -c '.tool_response // {}' 2>/dev/null || echo "{}")
    if [ "$mcp_server" = "null" ]; then
        mcp_field='null'
    else
        mcp_field=$(printf '%s' "$mcp_server" | jq -R -s '.|gsub("\n$";"")')
    fi
    payload=$(jq -nc \
        --arg ts "$ts" \
        --arg sid "$session_id" \
        --arg cwd "$cwd" \
        --arg cid "$call_id" \
        --arg tool "$tool" \
        --argjson mcp "$mcp_field" \
        --argjson exit "$exit_status" \
        --argjson dur "$duration_ms" \
        --argjson output "$output" \
        '{ts:$ts, session_id:$sid, cwd:$cwd, event:"post", call_id:$cid, tool:$tool, mcp_server:$mcp, exit_status:$exit, duration_ms:$dur, output:$output}')
fi

# Pipe through redaction then atomic write. Never let logging break a tool call.
{
    echo "$payload" | python3 "${LIB_DIR}/redact.py" | python3 "${LIB_DIR}/jsonl-write.py" "$LOG_FILE"
} >/dev/null 2>&1 || true

exit 0
```

```bash
chmod +x hooks/log-tool-calls.sh
```

- [ ] **Step 3: Run test to verify pass**

```bash
bash /tmp/test_log_tool_calls.sh && echo "log-tool-calls.sh PASS"
rm /tmp/test_log_tool_calls.sh
```

Expected: tests 1-4 each PASS; "all tests PASS"; exit 0.

- [ ] **Step 4: Commit**

```bash
git add hooks/log-tool-calls.sh
git commit -m "feat(hooks): add log-tool-calls.sh — JSONL log of every Pre/Post tool call"
```

---

## Task 6: Create `hooks/log-rotate.sh` (TDD)

**Files:**
- Create: `hooks/log-rotate.sh`

- [ ] **Step 1: Write the smoke test**

```bash
cat > /tmp/test_log_rotate.sh <<'BASH'
#!/usr/bin/env bash
set -euo pipefail

TEST_HOME=$(mktemp -d)
export HOME="$TEST_HOME"
LOG_DIR="$TEST_HOME/.claude/logs"
mkdir -p "$LOG_DIR"

today=$(date +%Y-%m-%d)
huge_log="$LOG_DIR/tool-calls-${today}.jsonl"
old_log="$LOG_DIR/tool-calls-2025-01-01.jsonl"

# Test 1: huge file gets gzipped
truncate -s 200M "$huge_log" 2>/dev/null || dd if=/dev/zero of="$huge_log" bs=1M count=200 2>/dev/null
CLAUDE_LOG_ROTATE_BYTES=104857600 bash hooks/log-rotate.sh   # 100 MB threshold
if [ ! -f "$huge_log" ] && ls "$LOG_DIR/tool-calls-${today}.jsonl"*.gz >/dev/null 2>&1; then
    echo "test 1 (rotate >100MB): PASS"
else
    echo "test 1 FAIL: huge log not rotated. dir contents:" >&2
    ls -la "$LOG_DIR" >&2
    exit 1
fi

# Test 2: old file gets pruned
touch "$old_log"
# Set mtime to 100 days ago.
touch -t "$(date -v-100d +%Y%m%d0000 2>/dev/null || date -d '100 days ago' +%Y%m%d0000)" "$old_log"
CLAUDE_LOG_RETAIN_DAYS=90 bash hooks/log-rotate.sh
if [ ! -f "$old_log" ]; then
    echo "test 2 (prune >90d): PASS"
else
    echo "test 2 FAIL: old log not deleted" >&2
    exit 1
fi

echo "all tests PASS"
BASH
bash /tmp/test_log_rotate.sh
```

Expected: FAIL — `hooks/log-rotate.sh` doesn't exist.

- [ ] **Step 2: Implement `hooks/log-rotate.sh`**

```bash
#!/usr/bin/env bash
# SessionEnd hook: gzip-rotate today's log if too big, prune old logs.
#
# Wire up in settings.json:
#   SessionEnd -> command "$HOME/.claude/hooks/log-rotate.sh"
#
# Env:
#   CLAUDE_LOG_ROTATE_BYTES   max bytes before gzip rotation (default 100MB)
#   CLAUDE_LOG_RETAIN_DAYS    days to keep logs (default 90)

set -uo pipefail

LOG_DIR="${HOME}/.claude/logs"
[ -d "$LOG_DIR" ] || exit 0

ROTATE_BYTES="${CLAUDE_LOG_ROTATE_BYTES:-104857600}"   # 100 MB
RETAIN_DAYS="${CLAUDE_LOG_RETAIN_DAYS:-90}"

today_log="${LOG_DIR}/tool-calls-$(date +%Y-%m-%d).jsonl"

# Rotate today's log if too big.
if [ -f "$today_log" ]; then
    size=$(stat -f%z "$today_log" 2>/dev/null || stat -c%s "$today_log" 2>/dev/null || echo 0)
    if [ "$size" -ge "$ROTATE_BYTES" ]; then
        n=1
        while [ -e "${today_log}.${n}.gz" ]; do
            n=$((n + 1))
        done
        gzip -c "$today_log" > "${today_log}.${n}.gz" && rm "$today_log"
    fi
fi

# Prune old logs.
find "$LOG_DIR" -name 'tool-calls-*.jsonl*' -type f -mtime +"$RETAIN_DAYS" -delete 2>/dev/null || true

exit 0
```

```bash
chmod +x hooks/log-rotate.sh
```

- [ ] **Step 3: Run test to verify pass**

```bash
bash /tmp/test_log_rotate.sh && echo "log-rotate.sh PASS"
rm /tmp/test_log_rotate.sh
```

Expected: tests 1-2 PASS; "all tests PASS"; exit 0.

- [ ] **Step 4: Commit**

```bash
git add hooks/log-rotate.sh
git commit -m "feat(hooks): add log-rotate.sh — gzip+prune logs on SessionEnd"
```

---

## Task 7: Create `hooks/safety-block.sh` (TDD)

**Files:**
- Create: `hooks/safety-block.sh`

- [ ] **Step 1: Write the smoke test**

```bash
cat > /tmp/test_safety_block.sh <<'BASH'
#!/usr/bin/env bash
set -uo pipefail

run_hook() {
    local cmd="$1"
    local input
    input=$(jq -nc --arg c "$cmd" '{tool_name:"Bash", tool_input:{command:$c}}')
    echo "$input" | bash hooks/safety-block.sh
    return $?
}

# Should BLOCK (exit 2)
blocks=(
    "rm -rf /"
    "rm -rf /Users/foo"
    "rm -rf ~"
    "rm -rf \$HOME/Documents"
    "sudo rm -rf /tmp"
    "dd of=/dev/disk0 if=/dev/zero"
    "dd of=/dev/sda1 if=/dev/zero"
    "dd of=/dev/nvme0n1 if=/dev/zero"
    "mkfs.ext4 /dev/sda1"
    "wipefs -a /dev/sda"
    ":(){ :|:& };:"
    "chmod -R 777 /"
    "chmod -R 777 ~"
    "git push --force origin main"
    "git push -f origin master"
    "git push --force-with-lease origin production"
)

# Should ALLOW (exit 0)
allows=(
    "git status"
    "ls -la"
    "rm /tmp/file.txt"
    "rm -r /tmp/build"
    "find . -name '*.pyc' -delete"
    "git push origin feature-branch"
    "git push origin HEAD:my-pr"
    "chmod +x script.sh"
    "dd if=/dev/random of=/tmp/random.bin bs=1k count=1"
)

fail=0
for cmd in "${blocks[@]}"; do
    run_hook "$cmd"
    rc=$?
    if [ "$rc" != "2" ]; then
        echo "FAIL (should BLOCK): '$cmd' exit=$rc" >&2
        fail=$((fail+1))
    fi
done
for cmd in "${allows[@]}"; do
    run_hook "$cmd"
    rc=$?
    if [ "$rc" != "0" ]; then
        echo "FAIL (should ALLOW): '$cmd' exit=$rc" >&2
        fail=$((fail+1))
    fi
done

if [ "$fail" = "0" ]; then
    echo "all ${#blocks[@]} blocks + ${#allows[@]} allows PASS"
else
    echo "FAILED: $fail cases" >&2
    exit 1
fi
BASH
bash /tmp/test_safety_block.sh
```

Expected: FAIL — `hooks/safety-block.sh` doesn't exist.

- [ ] **Step 2: Implement `hooks/safety-block.sh`**

```bash
#!/usr/bin/env bash
# PreToolUse hook (matcher: Bash): block catastrophic destructive commands.
# Exit 2 with explanation = block; exit 0 = allow.
#
# Note: existing hooks/block-rm-rf.sh and hooks/block-push-main.sh remain
# wired up alongside this one for back-compat. This script covers patterns
# they don't (dd, mkfs, fork bombs, sudo rm, force-push variants, chmod 777).

set -uo pipefail

CMD=$(jq -r '.tool_input.command // ""' 2>/dev/null || echo "")
[ -n "$CMD" ] || exit 0

block() {
    echo "BLOCKED: $1" >&2
    exit 2
}

# rm -rf against root or home
if echo "$CMD" | grep -qE '(^|[[:space:]])rm[[:space:]]+(-[a-zA-Z]*r[a-zA-Z]*f|-[a-zA-Z]*f[a-zA-Z]*r)[a-zA-Z]*[[:space:]]+(/$|/[[:space:]]|/Users(/|[[:space:]])|~([[:space:]/]|$)|\$HOME)'; then
    block "rm -rf against root, /Users, ~, or \$HOME. Use 'trash' or a specific path."
fi

# sudo rm -rf anything
if echo "$CMD" | grep -qE '(^|[[:space:]])sudo[[:space:]]+rm[[:space:]]+-[a-zA-Z]*r[a-zA-Z]*f'; then
    block "sudo rm -rf is too dangerous. Run targeted deletes manually if truly needed."
fi

# dd writing to a disk device
if echo "$CMD" | grep -qE '(^|[[:space:]])dd[[:space:]].*of=/dev/(disk|sd|nvme|rdisk)'; then
    block "dd writing to /dev/disk*, /dev/sd*, /dev/nvme*, or /dev/rdisk* destroys the disk. Refusing."
fi

# Filesystem creation / wipe
if echo "$CMD" | grep -qE '(^|[[:space:]])(mkfs(\.|[[:space:]])|wipefs[[:space:]])'; then
    block "mkfs/wipefs against any device wipes data. Refusing."
fi

# fdisk/parted with write subcommands (rough)
if echo "$CMD" | grep -qE '(^|[[:space:]])(fdisk[[:space:]]+(-w|/dev/)|parted[[:space:]]+/dev/.*[[:space:]](mklabel|mkpart|rm|resizepart))'; then
    block "fdisk/parted write operation. Refusing."
fi

# Fork bomb
if echo "$CMD" | grep -qE ':\(\)\{[[:space:]]*:[[:space:]]*\|[[:space:]]*:[[:space:]]*&[[:space:]]*\}'; then
    block "fork bomb pattern detected."
fi

# chmod -R 777 against / or ~
if echo "$CMD" | grep -qE '(^|[[:space:]])chmod[[:space:]]+(-[a-zA-Z]*R|-R[a-zA-Z]*)[[:space:]]+777[[:space:]]+(/$|/[[:space:]]|~([[:space:]/]|$)|\$HOME)'; then
    block "chmod -R 777 against / or ~ is destructive (loses original perms). Refusing."
fi

# Force-push variants to protected branches
if echo "$CMD" | grep -qE '(^|[[:space:]])git[[:space:]]+push[[:space:]]+(--force(-with-lease)?|-f)[[:space:]]+[A-Za-z0-9_./-]+[[:space:]]+(main|master|production|prod)([[:space:]]|$)'; then
    block "force-push to main/master/production. Use a feature branch and PR."
fi

if echo "$CMD" | grep -qE '(^|[[:space:]])git[[:space:]]+push[[:space:]]+[A-Za-z0-9_./-]+[[:space:]]+(--force(-with-lease)?|-f)'; then
    block "git push --force/--force-with-lease/-f detected. Use feature branches."
fi

exit 0
```

```bash
chmod +x hooks/safety-block.sh
```

- [ ] **Step 3: Run test to verify pass**

```bash
bash /tmp/test_safety_block.sh && echo "safety-block.sh PASS"
rm /tmp/test_safety_block.sh
```

Expected: "all 16 blocks + 9 allows PASS"; exit 0.

- [ ] **Step 4: Commit**

```bash
git add hooks/safety-block.sh
git commit -m "feat(hooks): add safety-block.sh — extended destructive-command blocks"
```

---

## Task 8: Create `hooks/safety-warn.sh` (TDD)

**Files:**
- Create: `hooks/safety-warn.sh`

- [ ] **Step 1: Write the smoke test**

```bash
cat > /tmp/test_safety_warn.sh <<'BASH'
#!/usr/bin/env bash
set -uo pipefail

run_hook() {
    local fp="$1"
    local input
    input=$(jq -nc --arg p "$fp" '{tool_name:"Edit", tool_input:{file_path:$p}}')
    echo "$input" | bash hooks/safety-warn.sh 2>/tmp/warn_stderr
    return $?
}

# Should warn (exit 0, stderr non-empty)
warns=(
    "/Users/me/.env"
    "/path/to/.env.production"
    "/etc/credentials.json"
    "/some/dir/secrets.yaml"
    "/secrets.yml"
    "/Users/me/.ssh/id_rsa"
    "/path/cert.pem"
    "/path/key.pem"
    "/path/server.key"
    "/path/cred.p12"
)

# Should NOT warn (exit 0, stderr empty)
quiets=(
    "/Users/me/code/foo.py"
    "/tmp/notes.md"
    "/etc/hosts.allow"
    "/path/.envoy.yaml"  # not .env
)

fail=0
for fp in "${warns[@]}"; do
    run_hook "$fp"
    rc=$?
    [ "$rc" = "0" ] || { echo "FAIL (warn should exit 0): $fp exit=$rc" >&2; fail=$((fail+1)); }
    if [ ! -s /tmp/warn_stderr ]; then
        echo "FAIL (warn should print to stderr): $fp" >&2
        fail=$((fail+1))
    fi
done
for fp in "${quiets[@]}"; do
    run_hook "$fp"
    rc=$?
    [ "$rc" = "0" ] || { echo "FAIL (quiet should exit 0): $fp exit=$rc" >&2; fail=$((fail+1)); }
    if [ -s /tmp/warn_stderr ]; then
        echo "FAIL (quiet should be silent): $fp stderr=$(cat /tmp/warn_stderr)" >&2
        fail=$((fail+1))
    fi
done
rm -f /tmp/warn_stderr

if [ "$fail" = "0" ]; then
    echo "all ${#warns[@]} warns + ${#quiets[@]} quiets PASS"
else
    echo "FAILED: $fail" >&2; exit 1
fi
BASH
bash /tmp/test_safety_warn.sh
```

Expected: FAIL — `hooks/safety-warn.sh` doesn't exist.

- [ ] **Step 2: Implement `hooks/safety-warn.sh`**

```bash
#!/usr/bin/env bash
# PreToolUse hook (matcher: Edit|Write): warn (no block) on sensitive paths.
# Exit 0 always; stderr is shown to Claude as a nudge.
#
# Hard reads/writes to many of these paths are already blocked by the deny
# rules in settings.json. This hook adds visibility for paths that slip past
# (custom locations, project-specific .env files, etc.).

set -uo pipefail

FP=$(jq -r '.tool_input.file_path // ""' 2>/dev/null || echo "")
[ -n "$FP" ] || exit 0

if echo "$FP" | grep -qE '(\.env(\.[^/]+)?$|/credentials([._-][^/]+)?(\.[a-z]+)?$|secrets?\.(json|ya?ml)$|\.pem$|\.key$|id_rsa(\.|$)|\.p12$|\.pfx$|\.gpg$)'; then
    cat >&2 <<'WARN'
WARNING: editing a sensitive-looking file. Verify it's in .gitignore.
Never hardcode secrets — use env vars or a secrets manager. Run `git status`
after editing to confirm the file won't be committed.
WARN
fi

exit 0
```

```bash
chmod +x hooks/safety-warn.sh
```

- [ ] **Step 3: Run test to verify pass**

```bash
bash /tmp/test_safety_warn.sh && echo "safety-warn.sh PASS"
rm /tmp/test_safety_warn.sh
```

Expected: "all 10 warns + 4 quiets PASS"; exit 0.

- [ ] **Step 4: Commit**

```bash
git add hooks/safety-warn.sh
git commit -m "feat(hooks): add safety-warn.sh — soft warning on sensitive Edit/Write"
```

---

## Task 9: Extend `settings.json` — wire hooks + extend permissions

**Files:**
- Modify: `settings.json`

- [ ] **Step 1: Write the failing test**

```bash
cat > /tmp/test_settings_hooks.sh <<'BASH'
#!/usr/bin/env bash
set -uo pipefail

# Test 1: file is valid JSON
python3 -m json.tool < settings.json >/dev/null 2>&1 || { echo "FAIL: not valid JSON" >&2; exit 1; }
echo "test 1 (JSON valid): PASS"

# Test 2: privacy env vars preserved
got=$(jq -r '.env.DISABLE_TELEMETRY' settings.json)
[ "$got" = "1" ] || { echo "FAIL: DISABLE_TELEMETRY=$got" >&2; exit 1; }
echo "test 2 (env preserved): PASS"

# Test 3: existing deny rules preserved
got=$(jq '.permissions.deny | length' settings.json)
[ "$got" -ge 30 ] || { echo "FAIL: only $got deny rules" >&2; exit 1; }
echo "test 3 (deny preserved): PASS"

# Test 4: log-tool-calls referenced in PreToolUse and PostToolUse
got=$(jq '[.hooks.PreToolUse[]?.hooks[]?.command // ""] | map(select(test("log-tool-calls.sh"))) | length' settings.json)
[ "$got" -ge 1 ] || { echo "FAIL: log-tool-calls.sh not in PreToolUse" >&2; exit 1; }
got=$(jq '[.hooks.PostToolUse[]?.hooks[]?.command // ""] | map(select(test("log-tool-calls.sh"))) | length' settings.json)
[ "$got" -ge 1 ] || { echo "FAIL: log-tool-calls.sh not in PostToolUse" >&2; exit 1; }
echo "test 4 (log hook wired): PASS"

# Test 5: safety-block.sh and safety-warn.sh wired
jq '.hooks.PreToolUse[]?.hooks[]?.command // ""' settings.json | grep -q safety-block.sh || { echo "FAIL: safety-block not wired" >&2; exit 1; }
jq '.hooks.PreToolUse[]?.hooks[]?.command // ""' settings.json | grep -q safety-warn.sh || { echo "FAIL: safety-warn not wired" >&2; exit 1; }
echo "test 5 (safety hooks wired): PASS"

# Test 6: Stop hook with anti-rationalization prompt
got=$(jq -r '.hooks.Stop[0].hooks[0].type // ""' settings.json)
[ "$got" = "prompt" ] || { echo "FAIL: Stop hook type=$got" >&2; exit 1; }
jq -r '.hooks.Stop[0].hooks[0].prompt // ""' settings.json | grep -q "rationalizing" || { echo "FAIL: anti-rationalization prompt missing" >&2; exit 1; }
echo "test 6 (anti-rationalization Stop): PASS"

# Test 7: SessionEnd log-rotate
jq '.hooks.SessionEnd[]?.hooks[]?.command // ""' settings.json | grep -q log-rotate.sh || { echo "FAIL: log-rotate not wired" >&2; exit 1; }
echo "test 7 (log-rotate wired): PASS"

# Test 8: permissions.allow includes Go and rg
got=$(jq -r '.permissions.allow[] // ""' settings.json | grep -c '^Bash(go:')
[ "$got" -ge 1 ] || { echo "FAIL: Bash(go:*) not in allow" >&2; exit 1; }
got=$(jq -r '.permissions.allow[] // ""' settings.json | grep -c '^Bash(rg:')
[ "$got" -ge 1 ] || { echo "FAIL: Bash(rg:*) not in allow" >&2; exit 1; }
echo "test 8 (allow extended): PASS"

echo "all tests PASS"
BASH
bash /tmp/test_settings_hooks.sh
```

Expected: tests 1-3 may pass (existing settings.json has them), tests 4-8 FAIL (we haven't extended yet).

- [ ] **Step 2: Read current settings.json**

```bash
cat settings.json
```

Expected: shows the existing JSON with `$schema`, `cleanupPeriodDays`, `env`, `enableAllProjectMcpServers`, `alwaysThinkingEnabled`, `permissions.deny`, two existing PreToolUse hooks (block-rm-rf and block-push-main), `statusLine`.

- [ ] **Step 3: Replace `settings.json` with extended version**

```json
{
  "$schema": "https://json.schemastore.org/claude-code-settings.json",
  "cleanupPeriodDays": 365,
  "env": {
    "DISABLE_TELEMETRY": "1",
    "DISABLE_ERROR_REPORTING": "1",
    "CLAUDE_CODE_DISABLE_FEEDBACK_SURVEY": "1",
    "CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS": "1"
  },
  "enableAllProjectMcpServers": false,
  "alwaysThinkingEnabled": true,
  "permissions": {
    "deny": [
      "Bash(rm -rf *)",
      "Bash(rm -fr *)",
      "Bash(sudo *)",
      "Bash(mkfs *)",
      "Bash(dd *)",
      "Bash(curl *|bash*)",
      "Bash(wget *|bash*)",
      "Bash(git push --force*)",
      "Bash(git push *--force*)",
      "Bash(git reset --hard*)",

      "Edit(~/.bashrc)",
      "Edit(~/.zshrc)",
      "Edit(~/.ssh/**)",

      "Write(~/.bashrc)",
      "Write(~/.zshrc)",
      "Write(~/.ssh/**)",
      "Write(~/.gnupg/**)",
      "Write(~/.aws/**)",
      "Write(~/.config/gh/**)",
      "Write(~/.git-credentials)",
      "Write(~/.npmrc)",
      "Write(~/.pypirc)",

      "Read(~/.ssh/**)",
      "Read(~/.gnupg/**)",
      "Read(~/.aws/**)",
      "Read(~/.azure/**)",
      "Read(~/.config/gh/**)",
      "Read(~/.git-credentials)",
      "Read(~/.docker/config.json)",
      "Read(~/.kube/**)",
      "Read(~/.npmrc)",
      "Read(~/.npm/**)",
      "Read(~/.pypirc)",
      "Read(~/.gem/credentials)",
      "Read(~/Library/Keychains/**)",
      "Read(~/Library/Application Support/**/metamask*/**)",
      "Read(~/Library/Application Support/**/electrum*/**)",
      "Read(~/Library/Application Support/**/exodus*/**)",
      "Read(~/Library/Application Support/**/phantom*/**)",
      "Read(~/Library/Application Support/**/solflare*/**)"
    ],
    "allow": [
      "Bash(rg:*)", "Bash(grep:*)", "Bash(sed:*)", "Bash(awk:*)", "Bash(jq:*)", "Bash(yq:*)",
      "Bash(fd:*)", "Bash(bat:*)", "Bash(eza:*)", "Bash(ls:*)", "Bash(cat:*)", "Bash(head:*)",
      "Bash(tail:*)", "Bash(wc:*)", "Bash(sort:*)", "Bash(uniq:*)", "Bash(tr:*)", "Bash(cut:*)",
      "Bash(realpath:*)", "Bash(basename:*)", "Bash(dirname:*)", "Bash(which:*)", "Bash(env)",
      "Bash(printenv:*)", "Bash(pwd)", "Bash(test:*)", "Bash([:*)", "Bash(date)",
      "Bash(git:*)", "Bash(gh:*)",
      "Bash(python3:*)", "Bash(uv:*)", "Bash(ruff:*)", "Bash(ty:*)", "Bash(pytest:*)",
      "Bash(node:*)", "Bash(npx:*)", "Bash(pnpm:*)", "Bash(oxlint:*)", "Bash(oxfmt:*)", "Bash(vitest:*)",
      "Bash(go:*)", "Bash(gofmt:*)", "Bash(golangci-lint:*)",
      "Bash(cargo:*)", "Bash(rustc:*)",
      "Bash(shellcheck:*)", "Bash(shfmt:*)", "Bash(actionlint:*)", "Bash(zizmor:*)", "Bash(prek:*)",
      "Bash(make:*)", "Bash(trash:*)"
    ]
  },
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          {
            "type": "command",
            "command": "CMD=$(jq -r '.tool_input.command'); if echo \"$CMD\" | grep -qE 'rm[[:space:]]+-[^[:space:]]*r[^[:space:]]*f'; then echo 'BLOCKED: Use trash instead of rm -rf' >&2; exit 2; fi"
          },
          {
            "type": "command",
            "command": "CMD=$(jq -r '.tool_input.command'); if echo \"$CMD\" | grep -qE 'git[[:space:]]+push[[:space:]]+[a-zA-Z_-]+[[:space:]]+(main|master)([[:space:]]|$)'; then echo 'BLOCKED: Use feature branches, not direct push to main' >&2; exit 2; fi"
          },
          {
            "type": "command",
            "command": "$HOME/.claude/hooks/safety-block.sh"
          }
        ]
      },
      {
        "matcher": "Edit|Write",
        "hooks": [
          {
            "type": "command",
            "command": "$HOME/.claude/hooks/safety-warn.sh"
          }
        ]
      },
      {
        "matcher": "*",
        "hooks": [
          {
            "type": "command",
            "command": "$HOME/.claude/hooks/log-tool-calls.sh pre"
          }
        ]
      }
    ],
    "PostToolUse": [
      {
        "matcher": "*",
        "hooks": [
          {
            "type": "command",
            "command": "$HOME/.claude/hooks/log-tool-calls.sh post"
          }
        ]
      }
    ],
    "Stop": [
      {
        "hooks": [
          {
            "type": "prompt",
            "prompt": "Review the assistant's final response. Reject it if the assistant is rationalizing incomplete work. Common patterns: claiming issues are 'pre-existing' or 'out of scope' to avoid fixing them, saying there are 'too many issues' to address all of them, deferring work to a 'follow-up' that was not requested, listing problems without fixing them and calling that done, or skipping test/lint failures with excuses. If the response shows any of these patterns, respond {\"ok\": false, \"reason\": \"You are rationalizing incomplete work. [specific issue]. Go back and finish.\"}. If the work is genuinely complete, respond {\"ok\": true}."
          }
        ]
      }
    ],
    "SessionEnd": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "$HOME/.claude/hooks/log-rotate.sh"
          }
        ]
      }
    ]
  },
  "statusLine": {
    "type": "command",
    "command": "~/.claude/statusline.sh"
  }
}
```

Use Write to overwrite `settings.json` with the JSON above.

- [ ] **Step 4: Run test to verify pass**

```bash
bash /tmp/test_settings_hooks.sh && echo "settings.json PASS"
rm /tmp/test_settings_hooks.sh
```

Expected: tests 1-8 PASS; "all tests PASS"; exit 0.

- [ ] **Step 5: Commit**

```bash
git add settings.json
git commit -m "feat(settings): wire log/safety/anti-rat/log-rotate hooks; extend allow list"
```

---

## Task 10: Extend `claude-md-template.md` — add Go, output prefs, comments policy

**Files:**
- Modify: `claude-md-template.md`

- [ ] **Step 1: Write a smoke test**

```bash
cat > /tmp/test_claude_md.sh <<'BASH'
#!/usr/bin/env bash
set -uo pipefail

f="claude-md-template.md"

# Section: Go (between Rust and Bash)
grep -q '^### Go$' "$f" || { echo "FAIL: missing '### Go' section" >&2; exit 1; }
echo "test 1 (Go section): PASS"

# Subsection: Output preferences
grep -q '^### Output preferences$' "$f" || { echo "FAIL: missing 'Output preferences' subsection" >&2; exit 1; }
echo "test 2 (Output preferences): PASS"

# Subsection: Comments policy (in Code Quality)
grep -q '^### Comments policy$' "$f" || { echo "FAIL: missing 'Comments policy'" >&2; exit 1; }
echo "test 3 (Comments policy): PASS"

# Pointer footer
grep -q "claude-defaults/docs/HOOKS.md" "$f" || { echo "FAIL: missing pointer to HOOKS.md" >&2; exit 1; }
grep -q "claude-defaults/docs/LOGGING.md" "$f" || { echo "FAIL: missing pointer to LOGGING.md" >&2; exit 1; }
echo "test 4 (pointer footer): PASS"

# Existing sections intact
grep -q '^### Python$' "$f" || { echo "FAIL: existing Python section gone" >&2; exit 1; }
grep -q '^### Rust$' "$f" || { echo "FAIL: existing Rust section gone" >&2; exit 1; }
echo "test 5 (existing sections intact): PASS"

echo "all tests PASS"
BASH
bash /tmp/test_claude_md.sh
```

Expected: tests 1-4 FAIL; test 5 PASS.

- [ ] **Step 2: Add the Go section between Rust and Bash**

Find the exact location to insert. The existing template has `### Rust` followed by `### Bash`. Use Edit:

```
old_string: ### Bash

All scripts must start with `set -euo pipefail`. Lint: `shellcheck script.sh && shfmt -d script.sh`
new_string: ### Go

Runtime: latest stable Go (via system install or `gobrew`)

| purpose | tool |
|---------|------|
| build & deps | `go build`, `go mod tidy` |
| lint | `golangci-lint run` |
| format | `gofmt -s -w` (or `goimports -w`) |
| test | `go test ./... -race -count=1` |
| static check | `go vet ./...` |

**Style:**
- Standard `gofmt` formatting -- no opinions, no debate
- Wrap errors with `fmt.Errorf("op: %w", err)`; check with `errors.Is`/`errors.As`
- Table-driven tests (`tests := []struct{...}{}`); subtests via `t.Run(tc.name, ...)`
- Never `panic` in libraries; return errors
- Accept interfaces, return concrete types
- Avoid empty interface (`any`) at API boundaries
- No `init()` for non-trivial logic; prefer explicit constructors
- Pin dependencies via `go.sum`; run `go mod tidy` after dep changes

**Concurrency:**
- Use `context.Context` for cancellation; pass as first arg
- `errgroup.Group` for parallel work that can fail
- No goroutines without a clear lifetime owner

### Bash

All scripts must start with `set -euo pipefail`. Lint: `shellcheck script.sh && shfmt -d script.sh`
```

- [ ] **Step 3: Add Output preferences and Comments policy subsections**

Find the existing `## Workflow` section. Insert new subsection at the start:

```
old_string: ## Workflow

### Before committing
new_string: ## Workflow

### Output preferences

- Terse responses; no trailing summaries; no preamble
- One-sentence updates between tool calls when something interesting happens; silence is wrong, narration is wrong
- No emojis unless explicitly requested
- Match response shape to task complexity -- a simple question gets a one-line answer, not headers and sections
- End-of-turn summary: one or two sentences max

### Before committing
```

Then find the `## Code Quality` section's `### Comments` subsection and rename + extend:

```
old_string: ### Comments

Code should be self-documenting. No commented-out code -- delete it. If you need a comment to explain WHAT the code does, refactor the code instead.
new_string: ### Comments policy

Default to no comments. Only add when the WHY is non-obvious -- a hidden constraint, a subtle invariant, a workaround for a specific bug, behavior that would surprise a reader. If removing the comment wouldn't confuse a future reader, don't write it.

Don't explain WHAT the code does -- well-named identifiers already do that. Don't reference the current task, fix, or callers ("used by X", "added for the Y flow", "handles the case from issue #123") -- those belong in the PR description and rot as the codebase evolves.

No commented-out code -- delete it. Code should be self-documenting; if you need a comment to explain what code does, refactor instead.
```

- [ ] **Step 4: Add pointer footer**

Append to the end of the file:

```bash
cat >> claude-md-template.md <<'MD'

---

## Local infrastructure references

This Claude Code installation is managed from `~/Desktop/Projects/claude-defaults/`. For details on what hooks fire and what gets logged:

- **Hooks reference:** `~/Desktop/Projects/claude-defaults/docs/HOOKS.md`
- **Logging schema and queries:** `~/Desktop/Projects/claude-defaults/docs/LOGGING.md`
- **Tool-call log files:** `~/.claude/logs/tool-calls-YYYY-MM-DD.jsonl`

Per-project overrides go in the project's own `.claude/settings.local.json` and `CLAUDE.md`.
MD
```

- [ ] **Step 5: Run test to verify pass**

```bash
bash /tmp/test_claude_md.sh && echo "claude-md-template.md PASS"
rm /tmp/test_claude_md.sh
```

Expected: tests 1-5 PASS; "all tests PASS"; exit 0.

- [ ] **Step 6: Commit**

```bash
git add claude-md-template.md
git commit -m "docs(claude-md): add Go section, output preferences, comments policy, pointers"
```

---

## Task 11: Extend `scripts/install.sh` — hybrid install (symlinks + jq-merge)

**Files:**
- Modify: `scripts/install.sh`

- [ ] **Step 1: Write the failing test**

```bash
cat > /tmp/test_install_hybrid.sh <<'BASH'
#!/usr/bin/env bash
set -uo pipefail

TEST_HOME=$(mktemp -d)
export HOME="$TEST_HOME"
mkdir -p "$TEST_HOME/.claude"

# Pre-existing settings.json with machine-specific entries we want preserved
cat > "$TEST_HOME/.claude/settings.json" <<'PRE'
{
  "$schema": "https://json.schemastore.org/claude-code-settings.json",
  "enabledPlugins": {"foo@bar": true},
  "skipAutoPermissionPrompt": true
}
PRE

# Pre-existing skill (should be preserved as non-symlink dir)
mkdir -p "$TEST_HOME/.claude/skills/legacy-skill"
echo "# legacy" > "$TEST_HOME/.claude/skills/legacy-skill/SKILL.md"

REPO_DIR="$(pwd)"
bash "$REPO_DIR/scripts/install.sh"

# Test 1: settings.json is a regular file (not symlink)
[ -L "$TEST_HOME/.claude/settings.json" ] && { echo "FAIL: settings.json is a symlink" >&2; exit 1; }
[ -f "$TEST_HOME/.claude/settings.json" ] || { echo "FAIL: settings.json missing" >&2; exit 1; }
echo "test 1 (settings.json is real file): PASS"

# Test 2: enabledPlugins preserved
got=$(jq -r '.enabledPlugins."foo@bar"' "$TEST_HOME/.claude/settings.json")
[ "$got" = "true" ] || { echo "FAIL: enabledPlugins not preserved (got $got)" >&2; exit 1; }
got=$(jq -r '.skipAutoPermissionPrompt' "$TEST_HOME/.claude/settings.json")
[ "$got" = "true" ] || { echo "FAIL: skipAutoPermissionPrompt not preserved" >&2; exit 1; }
echo "test 2 (existing entries preserved): PASS"

# Test 3: hooks block was merged in
jq -e '.hooks.PreToolUse | length > 0' "$TEST_HOME/.claude/settings.json" >/dev/null || { echo "FAIL: hooks not merged" >&2; exit 1; }
echo "test 3 (hooks merged): PASS"

# Test 4: CLAUDE.md is a symlink
[ -L "$TEST_HOME/.claude/CLAUDE.md" ] || { echo "FAIL: CLAUDE.md not a symlink" >&2; exit 1; }
target=$(readlink "$TEST_HOME/.claude/CLAUDE.md")
[ "$target" = "$REPO_DIR/claude-md-template.md" ] || { echo "FAIL: CLAUDE.md target=$target" >&2; exit 1; }
echo "test 4 (CLAUDE.md symlink): PASS"

# Test 5: hooks symlinked individually
for h in safety-block.sh safety-warn.sh log-tool-calls.sh log-rotate.sh; do
    [ -L "$TEST_HOME/.claude/hooks/$h" ] || { echo "FAIL: hooks/$h not symlinked" >&2; exit 1; }
done
echo "test 5 (hooks symlinked): PASS"

# Test 6: hooks/lib symlinked individually
for f in redact.py jsonl-write.py common.sh; do
    [ -L "$TEST_HOME/.claude/hooks/lib/$f" ] || { echo "FAIL: hooks/lib/$f not symlinked" >&2; exit 1; }
done
echo "test 6 (hooks/lib symlinked): PASS"

# Test 7: commands symlinked
for c in review-pr.md fix-issue.md merge-dependabot.md; do
    [ -L "$TEST_HOME/.claude/commands/$c" ] || { echo "FAIL: commands/$c not symlinked" >&2; exit 1; }
done
echo "test 7 (commands symlinked): PASS"

# Test 8: legacy skill preserved as-is
[ -L "$TEST_HOME/.claude/skills/legacy-skill" ] && { echo "FAIL: legacy-skill became symlink" >&2; exit 1; }
[ -d "$TEST_HOME/.claude/skills/legacy-skill" ] || { echo "FAIL: legacy-skill removed" >&2; exit 1; }
[ -f "$TEST_HOME/.claude/skills/legacy-skill/SKILL.md" ] || { echo "FAIL: legacy-skill/SKILL.md gone" >&2; exit 1; }
echo "test 8 (legacy skill preserved): PASS"

# Test 9: logs/ is a real directory
[ -L "$TEST_HOME/.claude/logs" ] && { echo "FAIL: logs is a symlink" >&2; exit 1; }
[ -d "$TEST_HOME/.claude/logs" ] || { echo "FAIL: logs missing" >&2; exit 1; }
echo "test 9 (logs is real dir): PASS"

# Test 10: backup directory created
[ -d "$TEST_HOME/.claude/backups" ] || { echo "FAIL: no backup dir" >&2; exit 1; }
ls "$TEST_HOME/.claude/backups/" | grep -q "pre-claude-defaults-" || { echo "FAIL: no backup snapshot" >&2; exit 1; }
echo "test 10 (backup created): PASS"

# Test 11: idempotent (run again, should not break or duplicate)
bash "$REPO_DIR/scripts/install.sh"
[ -L "$TEST_HOME/.claude/CLAUDE.md" ] || { echo "FAIL: 2nd install broke symlink" >&2; exit 1; }
echo "test 11 (idempotent): PASS"

# Test 12: statusline symlinked
[ -L "$TEST_HOME/.claude/statusline.sh" ] || { echo "FAIL: statusline.sh not symlinked" >&2; exit 1; }
echo "test 12 (statusline symlinked): PASS"

echo "all tests PASS"
BASH
bash /tmp/test_install_hybrid.sh
```

Expected: many tests FAIL — current install.sh copies files instead of symlinking them.

- [ ] **Step 2: Replace `scripts/install.sh` with the hybrid version**

Use Write to overwrite `scripts/install.sh` with this complete script:

```bash
#!/usr/bin/env bash
set -euo pipefail

# Hybrid installer: symlinks for content, jq-merge for settings.json.
#
# Usage:
#   ./scripts/install.sh [--dry-run] [--force] [component...]
#   Components: settings, mcp, claude-md, statusline, commands, hooks, agents,
#               skills, logs-dir, all
#   Default: all
#
# - settings.json: jq-merged into ~/.claude/settings.json (preserves
#   enabledPlugins, machine-specific entries). Original backed up first.
# - CLAUDE.md, hooks/*, hooks/lib/*, commands/*, agents/*, statusline.sh:
#   per-file symlinks pointing into the repo.
# - skills/<each>/: per-skill directory symlinks; existing non-symlink dirs
#   in ~/.claude/skills/ are preserved untouched.
# - logs/: real directory, never a symlink.

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CLAUDE_DIR="${HOME}/.claude"
DRY_RUN=0
FORCE=0
COMPONENTS=()
BACKUP_TS="$(date +%Y%m%d-%H%M%S)-$$"
BACKUP_DIR="${CLAUDE_DIR}/backups/pre-claude-defaults-${BACKUP_TS}"

usage() {
    echo "Usage: $0 [--dry-run] [--force] [component...]"
    echo ""
    echo "Components:"
    echo "  settings    Install/merge ~/.claude/settings.json"
    echo "  mcp         Install ~/.mcp.json (substitutes EXA_API_KEY if set)"
    echo "  claude-md   Symlink ~/.claude/CLAUDE.md -> repo template"
    echo "  statusline  Symlink ~/.claude/statusline.sh -> repo script"
    echo "  commands    Symlink each commands/*.md"
    echo "  hooks       Symlink each hooks/*.sh and hooks/lib/*"
    echo "  agents      Symlink each agents/*.md"
    echo "  skills      Per-skill directory symlinks (skips pre-existing dirs)"
    echo "  logs-dir    Create ~/.claude/logs/ (real dir)"
    echo "  all         Install everything (default)"
    echo ""
    echo "Options:"
    echo "  --dry-run   Show what would be done without making changes"
    echo "  --force     Overwrite existing entries even if they're foreign symlinks"
    exit 0
}

log()  { echo "  $1"; }
ok()   { echo "  OK: $1"; }
skip() { echo "  SKIP: $1"; }
warn() { echo "  WARN: $1" >&2; }
dry()  { echo "  DRY-RUN: $1"; }

ensure_backup_dir() {
    [ -d "$BACKUP_DIR" ] && return 0
    if [ "$DRY_RUN" = "1" ]; then return 0; fi
    mkdir -p "$BACKUP_DIR"
}

backup_existing() {
    local path="$1"
    [ -e "$path" ] || [ -L "$path" ] || return 0
    if [ "$DRY_RUN" = "1" ]; then
        dry "backup $path -> $BACKUP_DIR/"
        return 0
    fi
    ensure_backup_dir
    local rel="${path#${CLAUDE_DIR}/}"
    local target="${BACKUP_DIR}/${rel}"
    mkdir -p "$(dirname "$target")"
    mv "$path" "$target"
    log "backed up: $path -> $target"
}

install_symlink() {
    local src="$1" dst="$2" desc="$3"
    if [ "$DRY_RUN" = "1" ]; then
        dry "symlink $desc -> $dst -> $src"
        return 0
    fi
    if [ -L "$dst" ]; then
        local current
        current=$(readlink "$dst")
        if [ "$current" = "$src" ]; then
            ok "$dst (already symlinked)"
            return 0
        fi
        if [ "$FORCE" != "1" ]; then
            backup_existing "$dst"
        else
            rm -f "$dst"
        fi
    elif [ -e "$dst" ]; then
        backup_existing "$dst"
    fi
    mkdir -p "$(dirname "$dst")"
    ln -s "$src" "$dst"
    ok "$desc -> $dst"
}

install_settings() {
    log "--- settings ---"
    local target="${CLAUDE_DIR}/settings.json"

    if [ "$DRY_RUN" = "1" ]; then
        if [ -f "$target" ]; then
            dry "merge settings into $target"
        else
            dry "install settings to $target"
        fi
        return
    fi

    mkdir -p "$CLAUDE_DIR"
    if [ -L "$target" ]; then
        backup_existing "$target"
    fi
    if [ -f "$target" ]; then
        if command -v jq >/dev/null 2>&1; then
            backup_existing "$target"
            # Re-create from backup since backup_existing moved it.
            local backup_target
            backup_target="${BACKUP_DIR}/$(basename "$target")"
            jq -s '
                .[0] as $existing | .[1] as $new |
                $existing * $new |
                .permissions.deny = (
                    ($existing.permissions.deny // []) +
                    ($new.permissions.deny // []) | unique
                ) |
                .permissions.allow = (
                    ($existing.permissions.allow // []) +
                    ($new.permissions.allow // []) | unique
                ) |
                .hooks = ($existing.hooks // {}) * ($new.hooks // {})
            ' "$backup_target" "${REPO_DIR}/settings.json" > "${target}.tmp"
            # Validate before atomic rename
            python3 -m json.tool < "${target}.tmp" >/dev/null
            mv "${target}.tmp" "$target"
            ok "merged settings into $target"
        else
            warn "jq not installed; cannot merge. Install jq first."
            cp "${REPO_DIR}/settings.json" "$target"
            ok "settings copied (no merge): $target"
        fi
    else
        cp "${REPO_DIR}/settings.json" "$target"
        ok "settings -> $target"
    fi
}

install_mcp() {
    log "--- mcp ---"
    local target="${HOME}/.mcp.json"

    if [ "$DRY_RUN" = "1" ]; then
        dry "mcp config to $target"
        return
    fi

    if [ -f "$target" ] && [ "$FORCE" != "1" ]; then
        skip "$target (already exists; --force to overwrite)"
        return
    fi

    if [ -n "${EXA_API_KEY:-}" ]; then
        jq --arg key "$EXA_API_KEY" \
            '.mcpServers.exa.env.EXA_API_KEY = $key' \
            "${REPO_DIR}/mcp-template.json" > "$target"
        ok "mcp config -> $target (EXA_API_KEY substituted)"
    else
        jq 'del(.mcpServers.exa)' \
            "${REPO_DIR}/mcp-template.json" > "$target"
        ok "mcp config -> $target (exa removed -- set EXA_API_KEY to include)"
    fi
}

install_claude_md() {
    log "--- claude-md ---"
    install_symlink "${REPO_DIR}/claude-md-template.md" "${CLAUDE_DIR}/CLAUDE.md" "CLAUDE.md template"
}

install_statusline() {
    log "--- statusline ---"
    chmod +x "${REPO_DIR}/scripts/statusline.sh" 2>/dev/null || true
    install_symlink "${REPO_DIR}/scripts/statusline.sh" "${CLAUDE_DIR}/statusline.sh" "statusline"
}

install_commands() {
    log "--- commands ---"
    mkdir -p "${CLAUDE_DIR}/commands"
    for cmd in "${REPO_DIR}"/commands/*.md; do
        [ -f "$cmd" ] || continue
        local name; name=$(basename "$cmd")
        install_symlink "$cmd" "${CLAUDE_DIR}/commands/${name}" "command: ${name}"
    done
}

install_hooks() {
    log "--- hooks ---"
    mkdir -p "${CLAUDE_DIR}/hooks/lib"
    chmod +x "${REPO_DIR}"/hooks/*.sh 2>/dev/null || true
    chmod +x "${REPO_DIR}"/hooks/lib/*.py 2>/dev/null || true
    for hook in "${REPO_DIR}"/hooks/*.sh; do
        [ -f "$hook" ] || continue
        local name; name=$(basename "$hook")
        install_symlink "$hook" "${CLAUDE_DIR}/hooks/${name}" "hook: ${name}"
    done
    for libfile in "${REPO_DIR}"/hooks/lib/*; do
        [ -f "$libfile" ] || continue
        local name; name=$(basename "$libfile")
        install_symlink "$libfile" "${CLAUDE_DIR}/hooks/lib/${name}" "lib: ${name}"
    done
}

install_agents() {
    log "--- agents ---"
    mkdir -p "${CLAUDE_DIR}/agents"
    local found=0
    for a in "${REPO_DIR}"/agents/*.md; do
        [ -f "$a" ] || continue
        found=1
        local name; name=$(basename "$a")
        install_symlink "$a" "${CLAUDE_DIR}/agents/${name}" "agent: ${name}"
    done
    [ "$found" = "0" ] && log "  (no agents in repo yet — empty scaffold)"
}

install_skills() {
    log "--- skills ---"
    mkdir -p "${CLAUDE_DIR}/skills"
    local found=0
    for skill_dir in "${REPO_DIR}"/skills/*/; do
        [ -d "$skill_dir" ] || continue
        found=1
        local name; name=$(basename "$skill_dir")
        local dst="${CLAUDE_DIR}/skills/${name}"
        if [ -e "$dst" ] && [ ! -L "$dst" ]; then
            warn "skill exists as non-symlink dir: $dst — skipping (move/remove manually to bring under symlink management)"
            continue
        fi
        install_symlink "${skill_dir%/}" "$dst" "skill: ${name}"
    done
    [ "$found" = "0" ] && log "  (no skills in repo yet — empty scaffold)"
}

install_logs_dir() {
    log "--- logs-dir ---"
    if [ "$DRY_RUN" = "1" ]; then
        dry "create real dir ${CLAUDE_DIR}/logs/"
        return
    fi
    mkdir -p "${CLAUDE_DIR}/logs"
    ok "logs directory: ${CLAUDE_DIR}/logs"
}

install_all() {
    install_settings
    install_mcp
    install_claude_md
    install_statusline
    install_commands
    install_hooks
    install_agents
    install_skills
    install_logs_dir
}

# Parse arguments
while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run) DRY_RUN=1; shift ;;
        --force)   FORCE=1; shift ;;
        --help|-h) usage ;;
        *)         COMPONENTS+=("$1"); shift ;;
    esac
done

if [ ${#COMPONENTS[@]} -eq 0 ]; then
    COMPONENTS=("all")
fi

echo "claude-defaults installer"
echo "  repo: $REPO_DIR"
echo "  target: $CLAUDE_DIR"
[ "$DRY_RUN" = "1" ] && echo "  mode: DRY RUN"
[ "$FORCE" = "1" ] && echo "  mode: FORCE"
echo ""

if ! command -v jq >/dev/null 2>&1; then
    warn "jq is not installed. Hooks and statusline require jq."
fi
if ! command -v python3 >/dev/null 2>&1; then
    warn "python3 is not installed. Logging hooks require python3."
fi

for component in "${COMPONENTS[@]}"; do
    case "$component" in
        settings)   install_settings ;;
        mcp)        install_mcp ;;
        claude-md)  install_claude_md ;;
        statusline) install_statusline ;;
        commands)   install_commands ;;
        hooks)      install_hooks ;;
        agents)     install_agents ;;
        skills)     install_skills ;;
        logs-dir)   install_logs_dir ;;
        all)        install_all ;;
        *)          echo "Unknown component: $component"; usage ;;
    esac
done

echo ""
echo "Done. Run 'scripts/validate.sh' to verify installation."
[ -d "$BACKUP_DIR" ] && echo "Backup created: $BACKUP_DIR"
```

- [ ] **Step 3: Run test to verify pass**

```bash
bash /tmp/test_install_hybrid.sh && echo "install.sh PASS"
rm /tmp/test_install_hybrid.sh
```

Expected: tests 1-12 PASS; "all tests PASS"; exit 0.

- [ ] **Step 4: Commit**

```bash
git add scripts/install.sh
git commit -m "feat(install): hybrid mode — symlinks for content, jq-merge for settings.json"
```

---

## Task 12: Create `scripts/uninstall.sh`

**Files:**
- Create: `scripts/uninstall.sh`

- [ ] **Step 1: Write the failing test**

```bash
cat > /tmp/test_uninstall.sh <<'BASH'
#!/usr/bin/env bash
set -uo pipefail

TEST_HOME=$(mktemp -d)
export HOME="$TEST_HOME"
mkdir -p "$TEST_HOME/.claude"

cat > "$TEST_HOME/.claude/settings.json" <<'PRE'
{"$schema": "https://json.schemastore.org/claude-code-settings.json", "skipAutoPermissionPrompt": true}
PRE

REPO_DIR="$(pwd)"
bash "$REPO_DIR/scripts/install.sh" >/dev/null

# Capture backup dir created by install
BACKUP=$(ls -d "$TEST_HOME/.claude/backups/pre-claude-defaults-"* | head -n1)
[ -d "$BACKUP" ] || { echo "FAIL: no backup created during install" >&2; exit 1; }

# Run uninstall
bash "$REPO_DIR/scripts/uninstall.sh" >/dev/null

# Test 1: symlinks removed
[ -L "$TEST_HOME/.claude/CLAUDE.md" ] && { echo "FAIL: CLAUDE.md symlink not removed" >&2; exit 1; }
[ -L "$TEST_HOME/.claude/hooks/safety-block.sh" ] && { echo "FAIL: safety-block.sh symlink not removed" >&2; exit 1; }
echo "test 1 (symlinks removed): PASS"

# Test 2: settings.json restored from backup
got=$(jq -r '.skipAutoPermissionPrompt // ""' "$TEST_HOME/.claude/settings.json")
[ "$got" = "true" ] || { echo "FAIL: settings.json not restored (got $got)" >&2; exit 1; }
# After restore, it should NOT have the hooks block
got=$(jq -r '.hooks // ""' "$TEST_HOME/.claude/settings.json")
[ "$got" = "" ] || [ "$got" = "null" ] || { echo "FAIL: hooks block still present after restore" >&2; exit 1; }
echo "test 2 (settings restored): PASS"

echo "all tests PASS"
BASH
bash /tmp/test_uninstall.sh
```

Expected: FAIL — `scripts/uninstall.sh` doesn't exist.

- [ ] **Step 2: Implement `scripts/uninstall.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail

# Reverse a claude-defaults install: remove symlinks pointing into the repo,
# restore the latest backup snapshot.
#
# Usage: ./scripts/uninstall.sh [--dry-run]

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CLAUDE_DIR="${HOME}/.claude"
DRY_RUN=0
[ "${1:-}" = "--dry-run" ] && DRY_RUN=1

log() { echo "  $1"; }
ok()  { echo "  OK: $1"; }
warn(){ echo "  WARN: $1" >&2; }
dry() { echo "  DRY-RUN: $1"; }

# Find latest backup
LATEST_BACKUP=$(ls -1d "${CLAUDE_DIR}/backups/pre-claude-defaults-"* 2>/dev/null | tail -n1 || true)
echo "claude-defaults uninstaller"
echo "  repo: $REPO_DIR"
echo "  target: $CLAUDE_DIR"
[ -n "$LATEST_BACKUP" ] && echo "  restore from: $LATEST_BACKUP" || echo "  no backup found"
[ "$DRY_RUN" = "1" ] && echo "  mode: DRY RUN"
echo ""

remove_symlink_if_ours() {
    local path="$1"
    if [ -L "$path" ]; then
        local target
        target=$(readlink "$path")
        case "$target" in
            "${REPO_DIR}"/*)
                if [ "$DRY_RUN" = "1" ]; then
                    dry "remove symlink $path -> $target"
                else
                    rm "$path"
                    ok "removed: $path"
                fi
                ;;
            *)
                warn "symlink $path points to $target (not ours) — leaving"
                ;;
        esac
    fi
}

# Remove all per-file symlinks that point into our repo
for path in \
    "${CLAUDE_DIR}/CLAUDE.md" \
    "${CLAUDE_DIR}/statusline.sh" \
    "${CLAUDE_DIR}"/hooks/*.sh \
    "${CLAUDE_DIR}"/hooks/lib/* \
    "${CLAUDE_DIR}"/commands/*.md \
    "${CLAUDE_DIR}"/agents/*.md \
    "${CLAUDE_DIR}"/skills/*; do
    [ -e "$path" ] || [ -L "$path" ] || continue
    remove_symlink_if_ours "$path"
done

# Restore from latest backup (overlays its files back into ~/.claude/)
if [ -n "$LATEST_BACKUP" ] && [ -d "$LATEST_BACKUP" ]; then
    if [ "$DRY_RUN" = "1" ]; then
        dry "restore files from $LATEST_BACKUP into $CLAUDE_DIR"
    else
        # Walk the backup, copy each file back to its corresponding location.
        # We only restore files that were explicitly backed up by install.
        ( cd "$LATEST_BACKUP" && find . -type f -print ) | while read -r rel; do
            src="${LATEST_BACKUP}/${rel#./}"
            dst="${CLAUDE_DIR}/${rel#./}"
            mkdir -p "$(dirname "$dst")"
            cp -p "$src" "$dst"
            log "restored: $dst"
        done
    fi
fi

echo ""
echo "Done."
```

```bash
chmod +x scripts/uninstall.sh
```

- [ ] **Step 3: Run test to verify pass**

```bash
bash /tmp/test_uninstall.sh && echo "uninstall.sh PASS"
rm /tmp/test_uninstall.sh
```

Expected: tests 1-2 PASS; "all tests PASS"; exit 0.

- [ ] **Step 4: Commit**

```bash
git add scripts/uninstall.sh
git commit -m "feat(install): add uninstall.sh — removes our symlinks, restores backup"
```

---

## Task 13: Extend `scripts/validate.sh`

**Files:**
- Modify: `scripts/validate.sh`

- [ ] **Step 1: Write the failing test**

```bash
cat > /tmp/test_validate.sh <<'BASH'
#!/usr/bin/env bash
set -uo pipefail

TEST_HOME=$(mktemp -d)
export HOME="$TEST_HOME"
mkdir -p "$TEST_HOME/.claude"
cat > "$TEST_HOME/.claude/settings.json" <<'PRE'
{"$schema": "https://json.schemastore.org/claude-code-settings.json", "skipAutoPermissionPrompt": true}
PRE
REPO_DIR="$(pwd)"
bash "$REPO_DIR/scripts/install.sh" >/dev/null

# Run validate; should exit 0
bash "$REPO_DIR/scripts/validate.sh" || { echo "FAIL: validate exited non-zero on healthy install" >&2; exit 1; }
echo "test 1 (healthy install validates): PASS"

# Break the install: remove a symlink
rm "$TEST_HOME/.claude/hooks/safety-block.sh"
if bash "$REPO_DIR/scripts/validate.sh" >/dev/null 2>&1; then
    echo "FAIL: validate exited 0 with missing safety-block.sh" >&2
    exit 1
fi
echo "test 2 (broken install fails validate): PASS"

echo "all tests PASS"
BASH
bash /tmp/test_validate.sh
```

Expected: FAIL — current `validate.sh` doesn't check the new files (CLAUDE.md missing, hooks dir empty, etc.). Test 1 will fail; Test 2 will likely pass for the wrong reason.

- [ ] **Step 2: Replace `scripts/validate.sh` with extended version**

```bash
#!/usr/bin/env bash
set -uo pipefail

# Verify claude-defaults installation.
# Checks expected symlinks, real files, log directory, executability.
#
# Usage: ./scripts/validate.sh
# Exit 0 = all checks pass, exit 1 = issues found

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CLAUDE_DIR="${HOME}/.claude"
errors=0

pass() { printf "  \033[32mOK\033[0m  %s\n" "$1"; }
fail() { printf "  \033[31mFAIL\033[0m  %s\n" "$1"; ((errors++)) || true; }
warn() { printf "  \033[33mWARN\033[0m  %s\n" "$1"; }

echo "claude-defaults validation"
echo "  repo:   $REPO_DIR"
echo "  target: $CLAUDE_DIR"
echo ""

# Required tools
echo "--- tools ---"
if command -v jq >/dev/null 2>&1; then pass "jq installed"; else fail "jq not installed"; fi
if command -v python3 >/dev/null 2>&1; then pass "python3 installed"; else fail "python3 not installed"; fi

# settings.json: real file, valid JSON, has hooks
echo "--- settings ---"
if [ -L "${CLAUDE_DIR}/settings.json" ]; then
    fail "${CLAUDE_DIR}/settings.json is a symlink (should be a real file from jq-merge)"
elif [ -f "${CLAUDE_DIR}/settings.json" ]; then
    pass "${CLAUDE_DIR}/settings.json is a real file"
    if python3 -m json.tool < "${CLAUDE_DIR}/settings.json" >/dev/null 2>&1; then
        pass "settings.json is valid JSON"
    else
        fail "settings.json is invalid JSON"
    fi
    # Hooks block present
    for hook_name in safety-block.sh safety-warn.sh log-tool-calls.sh log-rotate.sh; do
        if jq -r '.. | objects | .command? // empty' "${CLAUDE_DIR}/settings.json" 2>/dev/null | grep -q "$hook_name"; then
            pass "settings.json wires $hook_name"
        else
            fail "settings.json does NOT wire $hook_name"
        fi
    done
else
    fail "${CLAUDE_DIR}/settings.json missing"
fi

# Symlinked content
echo "--- symlinks ---"
declare -a EXPECTED_SYMLINKS=(
    "${CLAUDE_DIR}/CLAUDE.md|${REPO_DIR}/claude-md-template.md"
    "${CLAUDE_DIR}/statusline.sh|${REPO_DIR}/scripts/statusline.sh"
    "${CLAUDE_DIR}/hooks/safety-block.sh|${REPO_DIR}/hooks/safety-block.sh"
    "${CLAUDE_DIR}/hooks/safety-warn.sh|${REPO_DIR}/hooks/safety-warn.sh"
    "${CLAUDE_DIR}/hooks/log-tool-calls.sh|${REPO_DIR}/hooks/log-tool-calls.sh"
    "${CLAUDE_DIR}/hooks/log-rotate.sh|${REPO_DIR}/hooks/log-rotate.sh"
    "${CLAUDE_DIR}/hooks/block-rm-rf.sh|${REPO_DIR}/hooks/block-rm-rf.sh"
    "${CLAUDE_DIR}/hooks/block-push-main.sh|${REPO_DIR}/hooks/block-push-main.sh"
    "${CLAUDE_DIR}/hooks/lib/redact.py|${REPO_DIR}/hooks/lib/redact.py"
    "${CLAUDE_DIR}/hooks/lib/jsonl-write.py|${REPO_DIR}/hooks/lib/jsonl-write.py"
    "${CLAUDE_DIR}/hooks/lib/common.sh|${REPO_DIR}/hooks/lib/common.sh"
    "${CLAUDE_DIR}/commands/review-pr.md|${REPO_DIR}/commands/review-pr.md"
    "${CLAUDE_DIR}/commands/fix-issue.md|${REPO_DIR}/commands/fix-issue.md"
    "${CLAUDE_DIR}/commands/merge-dependabot.md|${REPO_DIR}/commands/merge-dependabot.md"
)
for entry in "${EXPECTED_SYMLINKS[@]}"; do
    path="${entry%|*}"
    expected="${entry#*|}"
    if [ -L "$path" ]; then
        actual=$(readlink "$path")
        if [ "$actual" = "$expected" ]; then
            pass "$path -> $expected"
        else
            fail "$path -> $actual (expected $expected)"
        fi
    else
        fail "$path is not a symlink"
    fi
done

# Logs dir is real
echo "--- logs ---"
if [ -L "${CLAUDE_DIR}/logs" ]; then
    fail "${CLAUDE_DIR}/logs is a symlink (should be a real directory)"
elif [ -d "${CLAUDE_DIR}/logs" ]; then
    pass "${CLAUDE_DIR}/logs is a real directory"
else
    fail "${CLAUDE_DIR}/logs missing"
fi

# Hook executability (through symlinks)
echo "--- executable ---"
for hook in safety-block safety-warn log-tool-calls log-rotate block-rm-rf block-push-main; do
    f="${CLAUDE_DIR}/hooks/${hook}.sh"
    if [ -x "$f" ]; then pass "$f executable"; else fail "$f not executable"; fi
done
[ -x "${CLAUDE_DIR}/statusline.sh" ] && pass "statusline.sh executable" || fail "statusline.sh not executable"

# MCP config
echo "--- mcp ---"
if [ -f "${HOME}/.mcp.json" ]; then
    if jq empty "${HOME}/.mcp.json" 2>/dev/null; then
        pass "${HOME}/.mcp.json valid JSON"
    else
        fail "${HOME}/.mcp.json invalid JSON"
    fi
    if grep -q "your-.*-here" "${HOME}/.mcp.json" 2>/dev/null; then
        warn "${HOME}/.mcp.json contains placeholder values"
    fi
else
    warn "${HOME}/.mcp.json missing (run install.sh mcp to install)"
fi

echo ""
if [ "$errors" -gt 0 ]; then
    echo "FAILED: $errors issue(s)"
    exit 1
else
    echo "PASSED: All checks OK"
    exit 0
fi
```

- [ ] **Step 3: Run test to verify pass**

```bash
bash /tmp/test_validate.sh && echo "validate.sh PASS"
rm /tmp/test_validate.sh
```

Expected: tests 1-2 PASS; "all tests PASS"; exit 0.

- [ ] **Step 4: Commit**

```bash
git add scripts/validate.sh
git commit -m "feat(validate): verify symlinks, log dir, hook executability, settings hooks block"
```

---

## Task 14: Create test runner + settings-valid test

**Files:**
- Create: `tests/run-all.sh`
- Create: `tests/test-settings-valid.sh`

- [ ] **Step 1: Implement `tests/run-all.sh`**

```bash
mkdir -p tests
cat > tests/run-all.sh <<'BASH'
#!/usr/bin/env bash
# Run all claude-defaults test scripts. Exit non-zero on any failure.
set -uo pipefail

cd "$(dirname "$0")/.."
TESTS=(
    tests/test-settings-valid.sh
    tests/test-redaction.sh
    tests/test-hooks.sh
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
BASH
chmod +x tests/run-all.sh
```

- [ ] **Step 2: Implement `tests/test-settings-valid.sh`**

```bash
cat > tests/test-settings-valid.sh <<'BASH'
#!/usr/bin/env bash
set -uo pipefail
cd "$(dirname "$0")/.."

# 1. settings.json is valid JSON
python3 -m json.tool < settings.json >/dev/null 2>&1 || { echo "FAIL: settings.json not valid JSON" >&2; exit 1; }

# 2. Every hook script referenced in settings.json exists in hooks/
referenced=$(jq -r '.. | objects | .command? // empty' settings.json | \
    grep -oE '\$HOME/\.claude/hooks/[a-zA-Z0-9_.-]+' | \
    sed 's|\$HOME/\.claude/hooks/||' | sort -u)
fail=0
for f in $referenced; do
    if [ ! -f "hooks/$f" ]; then
        echo "FAIL: settings.json references hooks/$f but file is missing" >&2
        fail=$((fail+1))
    fi
done

# 3. mcp-template.json is valid JSON
python3 -m json.tool < mcp-template.json >/dev/null 2>&1 || { echo "FAIL: mcp-template.json not valid JSON" >&2; exit 1; }

[ "$fail" = "0" ] || exit 1
echo "test-settings-valid: PASS"
BASH
chmod +x tests/test-settings-valid.sh
```

- [ ] **Step 3: Verify tests run (will fail until other test files exist)**

```bash
bash tests/run-all.sh || true
bash tests/test-settings-valid.sh && echo "settings-valid PASS"
```

Expected: `run-all.sh` shows SKIP for missing test scripts; `test-settings-valid.sh` PASSES (it just validates the repo's JSON files).

- [ ] **Step 4: Commit**

```bash
git add tests/run-all.sh tests/test-settings-valid.sh
git commit -m "test: add run-all.sh dispatcher and test-settings-valid.sh"
```

---

## Task 15: Create `tests/test-install.sh` (full install/uninstall roundtrip)

**Files:**
- Create: `tests/test-install.sh`

- [ ] **Step 1: Implement test**

```bash
cat > tests/test-install.sh <<'BASH'
#!/usr/bin/env bash
# Roundtrip test: isolated $HOME, install, validate, uninstall.
set -uo pipefail
cd "$(dirname "$0")/.."

REPO_DIR="$(pwd)"
TEST_HOME=$(mktemp -d -t claude-defaults-test.XXXXXX)
trap "rm -rf $TEST_HOME" EXIT
export HOME="$TEST_HOME"
mkdir -p "$TEST_HOME/.claude"

# Pre-existing settings.json (machine-specific entries that must survive)
cat > "$TEST_HOME/.claude/settings.json" <<'PRE'
{
  "$schema": "https://json.schemastore.org/claude-code-settings.json",
  "enabledPlugins": {"foo@bar": true, "baz@qux": false},
  "skipAutoPermissionPrompt": true
}
PRE

# Pre-existing skill (must survive)
mkdir -p "$TEST_HOME/.claude/skills/legacy-skill"
echo "# legacy" > "$TEST_HOME/.claude/skills/legacy-skill/SKILL.md"

fail=0
fail_msg() { echo "FAIL: $1" >&2; fail=$((fail+1)); }

# Run installer
bash "$REPO_DIR/scripts/install.sh" >/dev/null || fail_msg "install.sh exited non-zero"

# Run validator
bash "$REPO_DIR/scripts/validate.sh" >/dev/null || fail_msg "validate.sh failed after install"

# enabledPlugins preserved
got=$(jq -r '.enabledPlugins."foo@bar"' "$TEST_HOME/.claude/settings.json")
[ "$got" = "true" ] || fail_msg "enabledPlugins.foo@bar=$got (expected true)"

# skipAutoPermissionPrompt preserved
got=$(jq -r '.skipAutoPermissionPrompt' "$TEST_HOME/.claude/settings.json")
[ "$got" = "true" ] || fail_msg "skipAutoPermissionPrompt=$got"

# Hooks block merged
got=$(jq '.hooks.PreToolUse | length' "$TEST_HOME/.claude/settings.json")
[ "$got" -ge 3 ] || fail_msg "hooks.PreToolUse has only $got entries (expected >=3)"

# Legacy skill survived
[ -d "$TEST_HOME/.claude/skills/legacy-skill" ] || fail_msg "legacy-skill removed"
[ -L "$TEST_HOME/.claude/skills/legacy-skill" ] && fail_msg "legacy-skill became symlink"

# Backup created
ls -d "$TEST_HOME/.claude/backups/pre-claude-defaults-"* >/dev/null 2>&1 || fail_msg "no backup created"

# Idempotent: run install again
bash "$REPO_DIR/scripts/install.sh" >/dev/null || fail_msg "second install.sh exited non-zero"
[ -L "$TEST_HOME/.claude/CLAUDE.md" ] || fail_msg "second install broke CLAUDE.md symlink"

# Uninstall
bash "$REPO_DIR/scripts/uninstall.sh" >/dev/null || fail_msg "uninstall.sh exited non-zero"

# After uninstall: symlinks gone, settings.json restored
[ -L "$TEST_HOME/.claude/CLAUDE.md" ] && fail_msg "CLAUDE.md still symlinked after uninstall"
[ -L "$TEST_HOME/.claude/hooks/safety-block.sh" ] && fail_msg "safety-block.sh still symlinked"
got=$(jq -r '.hooks // "none"' "$TEST_HOME/.claude/settings.json")
[ "$got" = "none" ] || [ "$got" = "null" ] || fail_msg "settings.json hooks block not removed by uninstall"

if [ "$fail" -eq 0 ]; then
    echo "test-install: PASS"
else
    echo "test-install: $fail FAILURE(S)"
    exit 1
fi
BASH
chmod +x tests/test-install.sh
```

- [ ] **Step 2: Run test to verify pass**

```bash
bash tests/test-install.sh
```

Expected: "test-install: PASS"; exit 0.

- [ ] **Step 3: Commit**

```bash
git add tests/test-install.sh
git commit -m "test: add test-install.sh — install/uninstall roundtrip in isolated HOME"
```

---

## Task 16: Create `tests/test-hooks.sh` + fixtures

**Files:**
- Create: `tests/test-hooks.sh`
- Create: `tests/fixtures/tool-input-bash-safe.json`
- Create: `tests/fixtures/tool-input-bash-rmrf.json`
- Create: `tests/fixtures/tool-input-edit-env.json`
- Create: `tests/fixtures/tool-input-edit-normal.json`
- Create: `tests/fixtures/tool-input-mcp-call.json`

- [ ] **Step 1: Create fixtures**

```bash
mkdir -p tests/fixtures
cat > tests/fixtures/tool-input-bash-safe.json <<'JSON'
{
  "session_id": "fix-001",
  "cwd": "/tmp/test-cwd",
  "tool_name": "Bash",
  "tool_input": {"command": "git status"}
}
JSON

cat > tests/fixtures/tool-input-bash-rmrf.json <<'JSON'
{
  "session_id": "fix-002",
  "cwd": "/tmp/test-cwd",
  "tool_name": "Bash",
  "tool_input": {"command": "rm -rf /Users/somebody"}
}
JSON

cat > tests/fixtures/tool-input-edit-env.json <<'JSON'
{
  "session_id": "fix-003",
  "cwd": "/tmp/test-cwd",
  "tool_name": "Edit",
  "tool_input": {"file_path": "/Users/me/.env", "old_string": "x", "new_string": "y"}
}
JSON

cat > tests/fixtures/tool-input-edit-normal.json <<'JSON'
{
  "session_id": "fix-004",
  "cwd": "/tmp/test-cwd",
  "tool_name": "Edit",
  "tool_input": {"file_path": "/tmp/test-cwd/main.py", "old_string": "x", "new_string": "y"}
}
JSON

cat > tests/fixtures/tool-input-mcp-call.json <<'JSON'
{
  "session_id": "fix-005",
  "cwd": "/tmp/test-cwd",
  "tool_name": "mcp__playwright__browser_click",
  "tool_input": {"selector": "#submit"}
}
JSON
```

- [ ] **Step 2: Implement `tests/test-hooks.sh`**

```bash
cat > tests/test-hooks.sh <<'BASH'
#!/usr/bin/env bash
# Per-hook input/exit-code/log assertions using fixtures/.
set -uo pipefail
cd "$(dirname "$0")/.."

fail=0
fail_msg() { echo "FAIL: $1" >&2; fail=$((fail+1)); }

# Setup isolated $HOME for log capture
TEST_HOME=$(mktemp -d -t claude-hooks-test.XXXXXX)
trap "rm -rf $TEST_HOME" EXIT
export HOME="$TEST_HOME"
mkdir -p "$TEST_HOME/.claude/logs"

# === safety-block.sh ===
echo "  testing safety-block.sh"
bash hooks/safety-block.sh < tests/fixtures/tool-input-bash-safe.json
[ $? -eq 0 ] || fail_msg "safety-block.sh blocked safe command"
bash hooks/safety-block.sh < tests/fixtures/tool-input-bash-rmrf.json
[ $? -eq 2 ] || fail_msg "safety-block.sh did not block rm -rf"

# === safety-warn.sh ===
echo "  testing safety-warn.sh"
bash hooks/safety-warn.sh < tests/fixtures/tool-input-edit-env.json 2>/tmp/warn-stderr
[ $? -eq 0 ] || fail_msg "safety-warn.sh exit non-zero on .env"
[ -s /tmp/warn-stderr ] || fail_msg "safety-warn.sh did not warn on .env"
bash hooks/safety-warn.sh < tests/fixtures/tool-input-edit-normal.json 2>/tmp/warn-stderr
[ $? -eq 0 ] || fail_msg "safety-warn.sh exit non-zero on normal file"
[ -s /tmp/warn-stderr ] && fail_msg "safety-warn.sh warned on normal file"
rm -f /tmp/warn-stderr

# === log-tool-calls.sh ===
echo "  testing log-tool-calls.sh"
today=$(date +%Y-%m-%d)
log_file="$TEST_HOME/.claude/logs/tool-calls-${today}.jsonl"
bash hooks/log-tool-calls.sh pre < tests/fixtures/tool-input-bash-safe.json
[ -f "$log_file" ] || fail_msg "log-tool-calls.sh did not create log"
last=$(tail -n 1 "$log_file")
echo "$last" | jq -e '.event == "pre" and .tool == "Bash" and .args.command == "git status"' >/dev/null \
    || fail_msg "log-tool-calls.sh pre row malformed: $last"
# MCP parsing
bash hooks/log-tool-calls.sh pre < tests/fixtures/tool-input-mcp-call.json
last=$(tail -n 1 "$log_file")
echo "$last" | jq -e '.mcp_server == "playwright"' >/dev/null \
    || fail_msg "log-tool-calls.sh did not parse MCP server: $last"

# === log-rotate.sh ===
echo "  testing log-rotate.sh"
old="$TEST_HOME/.claude/logs/tool-calls-2025-01-01.jsonl"
touch "$old"
touch -t "$(date -v-100d +%Y%m%d0000 2>/dev/null || date -d '100 days ago' +%Y%m%d0000)" "$old"
CLAUDE_LOG_RETAIN_DAYS=90 bash hooks/log-rotate.sh
[ -f "$old" ] && fail_msg "log-rotate.sh did not prune old log"

# === existing block-rm-rf.sh / block-push-main.sh (regression) ===
echo "  testing legacy block hooks"
bash hooks/block-rm-rf.sh <<< '{"tool_input":{"command":"rm -rf /tmp"}}'
[ $? -eq 2 ] || fail_msg "block-rm-rf.sh regression: did not block"
bash hooks/block-rm-rf.sh <<< '{"tool_input":{"command":"ls -la"}}'
[ $? -eq 0 ] || fail_msg "block-rm-rf.sh regression: blocked safe command"
bash hooks/block-push-main.sh <<< '{"tool_input":{"command":"git push origin main"}}'
[ $? -eq 2 ] || fail_msg "block-push-main.sh regression: did not block"
bash hooks/block-push-main.sh <<< '{"tool_input":{"command":"git push origin feature"}}'
[ $? -eq 0 ] || fail_msg "block-push-main.sh regression: blocked feature push"

if [ "$fail" -eq 0 ]; then
    echo "test-hooks: PASS"
else
    echo "test-hooks: $fail FAILURE(S)"
    exit 1
fi
BASH
chmod +x tests/test-hooks.sh
```

- [ ] **Step 3: Run test to verify pass**

```bash
bash tests/test-hooks.sh
```

Expected: "test-hooks: PASS"; exit 0.

- [ ] **Step 4: Commit**

```bash
git add tests/test-hooks.sh tests/fixtures/
git commit -m "test: add test-hooks.sh + fixtures covering all hook scripts"
```

---

## Task 17: Create `tests/test-redaction.sh`

**Files:**
- Create: `tests/test-redaction.sh`

- [ ] **Step 1: Implement test**

```bash
cat > tests/test-redaction.sh <<'BASH'
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
    'ghp_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa|***GH_TOKEN***|ghp_aaaaaaaaa'
    'sk-ant-api03-xyzABC123|***ANTHROPIC_KEY***|sk-ant-api03'
    'sk-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa|***OPENAI_KEY***|sk-aaaaaaaaaaaaaaaaaaaa'
    'password=hunter2|password=***|hunter2'
    'TOKEN=secret-value|TOKEN=***|secret-value'
    '--token=mytoken|--token=***|mytoken'
    'Authorization: Bearer xyz|Authorization: ***|Bearer xyz'
)

for c in "${cases[@]}"; do
    inp="${c%%|*}"
    rest="${c#*|}"
    must="${rest%%|*}"
    mustnot="${rest##*|}"
    payload=$(jq -nc --arg v "$inp" '{value: $v}')
    out=$(echo "$payload" | python3 hooks/lib/redact.py)
    val=$(echo "$out" | jq -r '.value')
    if ! echo "$val" | grep -qF "$must"; then
        fail_msg "input=$inp -> $val (missing $must)"
    fi
    if echo "$val" | grep -qF "$mustnot"; then
        fail_msg "input=$inp -> $val (still contains $mustnot)"
    fi
done

# Adversarial backtracking input — must complete fast
adversarial=$(python3 -c 'print("a" * 5000 + "@" + "b" * 5000)')
payload=$(jq -nc --arg v "$adversarial" '{value: $v}')
SECONDS=0
echo "$payload" | timeout 5s python3 hooks/lib/redact.py >/dev/null \
    || fail_msg "redact.py timed out on adversarial input"
[ "$SECONDS" -lt 5 ] || fail_msg "redact.py took $SECONDS s (too slow)"

# Recursive structure
nested='{"a":{"b":["password=foo", "ok"]}}'
out=$(echo "$nested" | python3 hooks/lib/redact.py)
echo "$out" | jq -e '.a.b[0] | test("\\*\\*\\*")' >/dev/null \
    || fail_msg "nested redaction failed: $out"

if [ "$fail" -eq 0 ]; then
    echo "test-redaction: PASS"
else
    echo "test-redaction: $fail FAILURE(S)"
    exit 1
fi
BASH
chmod +x tests/test-redaction.sh
```

- [ ] **Step 2: Run test to verify pass**

```bash
bash tests/test-redaction.sh
```

Expected: "test-redaction: PASS"; exit 0.

- [ ] **Step 3: Commit**

```bash
git add tests/test-redaction.sh
git commit -m "test: add test-redaction.sh covering all secret patterns + adversarial input"
```

---

## Task 18: Create `docs/HOOKS.md`

**Files:**
- Create: `docs/HOOKS.md`

- [ ] **Step 1: Write the doc**

```markdown
# Hooks Reference

Every hook installed by claude-defaults, what it does, and how to test it. The hooks live at `hooks/*.sh` in this repo and are symlinked into `~/.claude/hooks/` by `scripts/install.sh`.

## Hook events (Claude Code)

| Event | When it fires | Can block? |
|-------|---------------|------------|
| `PreToolUse` | Before a tool call executes | Yes (exit 2) |
| `PostToolUse` | After a tool call returns | No (already ran) |
| `UserPromptSubmit` | When user submits a prompt | Yes |
| `Stop` | When Claude finishes responding | Yes (forces continue) |
| `SessionStart` | When a session begins/resumes | No |
| `SessionEnd` | When a session ends | No |

## Exit codes (command-type hooks)

| Code | Behavior |
|------|----------|
| `0` | Allow; stdout parsed for optional JSON control |
| `1` | Error, non-blocking; stderr shown in verbose mode |
| `2` | Blocking; stderr fed back to Claude as the rejection reason |

## Installed hooks

### `block-rm-rf.sh` (legacy, PreToolUse Bash)

Blocks any `rm -rf` invocation. Inline command in `settings.json`. **Pattern:** `rm[[:space:]]+-[^[:space:]]*r[^[:space:]]*f`. **Test:**

```bash
echo '{"tool_input":{"command":"rm -rf /tmp"}}' | bash hooks/block-rm-rf.sh
# expect: exit 2 with "BLOCKED: Use trash instead of rm -rf"
```

### `block-push-main.sh` (legacy, PreToolUse Bash)

Blocks `git push <remote> main` or `git push <remote> master`. Does NOT cover force-push or production branches — that's `safety-block.sh`'s job.

### `safety-block.sh` (PreToolUse Bash, exit 2)

Hard-blocks broader destructive patterns:

| Category | Pattern |
|---|---|
| `rm -rf` against root/home | `rm -rf /`, `rm -rf /Users/...`, `rm -rf ~`, `rm -rf $HOME...` |
| sudo rm -rf | any `sudo rm -rf ...` |
| dd to disk devices | `dd of=/dev/disk*`, `/dev/sd*`, `/dev/nvme*`, `/dev/rdisk*` |
| Filesystem ops | `mkfs.*`, `wipefs ...` |
| Partition ops | `fdisk -w`, `parted /dev/... mklabel/mkpart/rm/resizepart` |
| Fork bomb | `:(){ :\|:& };:` |
| chmod 777 | `chmod -R 777 /`, `chmod -R 777 ~` |
| Force-push variants | `git push --force/-f/--force-with-lease ... main/master/production/prod` |

**Test:** `bash tests/test-hooks.sh` (covers 16 block + 9 allow cases)

### `safety-warn.sh` (PreToolUse Edit\|Write, exit 0)

Soft warning on sensitive paths. Stderr is shown to Claude as a nudge; the Edit/Write proceeds.

Patterns warned:

- `*.env`, `*.env.*`
- `*credentials*`
- `*secret*.json`, `*secret*.yml`, `*secret*.yaml`
- `*.pem`, `*.key`, `*id_rsa*`, `*.p12`, `*.pfx`, `*.gpg`

Hard reads/writes to `~/.ssh/`, `~/.aws/`, `~/.gnupg/`, etc. are blocked by the deny rules in `settings.json` regardless of this hook.

### `log-tool-calls.sh pre|post` (PreToolUse `*` and PostToolUse `*`)

Append a JSONL row per tool call to `~/.claude/logs/tool-calls-YYYY-MM-DD.jsonl`. See `docs/LOGGING.md` for schema, query examples, and rotation policy.

### `log-rotate.sh` (SessionEnd)

Gzip-rotate today's log if it exceeds `CLAUDE_LOG_ROTATE_BYTES` (default 100 MB), prune logs older than `CLAUDE_LOG_RETAIN_DAYS` days (default 90).

### `enforce-package-manager.sh` (optional, PreToolUse Bash)

Blocks `npm` commands when the cwd contains `pnpm-lock.yaml` or `yarn.lock`. **NOT wired up by default** — opt in by adding it to `settings.json` if you want strict enforcement.

### `log-bash-commands.sh` (optional, PostToolUse Bash)

Plain-text Bash command audit log to `~/.claude/bash-commands.log`. **NOT wired up by default** — superseded by the structured `log-tool-calls.sh`. Kept for back-compat / simple use.

### Anti-rationalization Stop hook (`type: "prompt"`)

Inline prompt-type hook in `settings.json`. Sends Claude's final response to a fast model that returns `{"ok": false, "reason": "..."}` or `{"ok": true}`. If rejected, Claude must continue.

To tune: edit the `prompt` field in `settings.json` `hooks.Stop[0].hooks[0]`.

## Adding your own hook

1. Create `hooks/<name>.sh` (or `.py`)
2. Make it executable: `chmod +x hooks/<name>.sh`
3. Re-run `./scripts/install.sh hooks` (creates the symlink at `~/.claude/hooks/<name>.sh`)
4. Reference it in `settings.json` under the appropriate event/matcher
5. Re-run `./scripts/install.sh settings` to merge the updated hooks block
6. Restart any active Claude Code session for the new hook to fire
```

```bash
mkdir -p docs
# (Use Write tool to create docs/HOOKS.md with content above)
```

- [ ] **Step 2: Verify file created**

```bash
[ -f docs/HOOKS.md ] && wc -l docs/HOOKS.md
```

Expected: file exists, ~80-100 lines.

- [ ] **Step 3: Commit**

```bash
git add docs/HOOKS.md
git commit -m "docs: add HOOKS.md reference for every installed hook"
```

---

## Task 19: Create `docs/LOGGING.md`

**Files:**
- Create: `docs/LOGGING.md`

- [ ] **Step 1: Write the doc**

```markdown
# Tool-Call Logging

Every tool call (including all `mcp__*` invocations) is logged to `~/.claude/logs/tool-calls-YYYY-MM-DD.jsonl` by `hooks/log-tool-calls.sh` and rotated by `hooks/log-rotate.sh`.

## Schema

One JSON object per line. Two row types: `pre` (written before the tool runs) and `post` (written after).

### Pre row

```json
{
  "ts": "2026-04-26T13:04:11.482Z",
  "session_id": "abc123",
  "cwd": "/Users/mills/Desktop/Projects/foo",
  "event": "pre",
  "call_id": "1714137851482000-7421",
  "tool": "Bash",
  "mcp_server": null,
  "args": { "command": "git status" }
}
```

### Post row

```json
{
  "ts": "2026-04-26T13:04:11.612Z",
  "session_id": "abc123",
  "cwd": "/Users/mills/Desktop/Projects/foo",
  "event": "post",
  "call_id": "1714137851482000-7421",
  "tool": "Bash",
  "mcp_server": null,
  "exit_status": 0,
  "duration_ms": 130,
  "output": { "stdout": "On branch main\n...", "stderr": "", "exit_code": 0 }
}
```

### Fields

| Field | Type | Notes |
|---|---|---|
| `ts` | ISO 8601 UTC | millisecond precision, ends in `Z` |
| `session_id` | string | from Claude Code hook input; `"unknown"` if absent |
| `cwd` | string | working dir at time of call |
| `event` | `"pre" \| "post"` | which side of the call |
| `call_id` | string | nanosecond ts + PID; matches pre row to its post row |
| `tool` | string | tool name (e.g., `Bash`, `Edit`, `mcp__playwright__browser_click`) |
| `mcp_server` | string \| null | parsed from `mcp__<server>__<method>` tool names |
| `args` | object | full `tool_input`, redacted |
| `exit_status` | int | post only |
| `duration_ms` | int | post only; pre/post call_id match |
| `output` | object | post only; full `tool_response`, redacted, capped at 1 MB |
| `output._truncated_bytes` | int | present on post rows where output exceeded the cap |

## Redaction

Patterns auto-stripped before write (see `hooks/lib/redact.py`):

| Pattern | Replacement |
|---|---|
| JWT tokens | `***JWT***` |
| AWS access keys (`AKIA...`) | `***AWS_KEY***` |
| GitHub tokens (`ghp_/gho_/ghs_/ghu_`) | `***GH_TOKEN***` |
| Anthropic keys (`sk-ant-...`) | `***ANTHROPIC_KEY***` |
| OpenAI keys (`sk-...` 40-80 chars) | `***OPENAI_KEY***` |
| `password=`, `token=`, `secret=`, `api_key=`, `bearer:`, `authorization:` | value `***` |
| `--password=`, `--token=`, `--secret=`, `--api-key=` | value `***` |

If you need to add a pattern, edit `hooks/lib/redact.py`'s `_PATTERNS` list and add a case to `tests/test-redaction.sh`. To re-redact older logs after adding a pattern, run `python3 scripts/redact-existing-logs.py <log-file>` (one-off; not auto-installed).

## Rotation policy

`log-rotate.sh` runs on `SessionEnd`:

1. If `tool-calls-YYYY-MM-DD.jsonl` exceeds `CLAUDE_LOG_ROTATE_BYTES` (default `104857600` = 100 MB), gzip-rotate it to `tool-calls-YYYY-MM-DD.jsonl.<N>.gz` (`<N>` is next available integer)
2. Delete any `tool-calls-*.jsonl*` older than `CLAUDE_LOG_RETAIN_DAYS` mtime days (default 90)

Override either via env var in your shell or in `~/.claude/settings.json`'s `env` block.

## Query examples

### Today's Bash commands

```bash
jq -r 'select(.event=="pre" and .tool=="Bash") | .args.command' \
    ~/.claude/logs/tool-calls-$(date +%Y-%m-%d).jsonl
```

### MCP calls grouped by server

```bash
jq -r 'select(.event=="pre" and .mcp_server != null) | .mcp_server' \
    ~/.claude/logs/tool-calls-*.jsonl | sort | uniq -c | sort -rn
```

### Slowest tool calls

```bash
jq -r 'select(.event=="post") | "\(.duration_ms)\t\(.tool)\t\(.args.command // .args.file_path // "")"' \
    ~/.claude/logs/tool-calls-*.jsonl | sort -rn | head -20
```

### Failed Bash commands

```bash
jq -r 'select(.event=="post" and .tool=="Bash" and .exit_status != 0) | "\(.ts)\t\(.exit_status)\t\(.output.stderr // "")"' \
    ~/.claude/logs/tool-calls-*.jsonl | head -50
```

### Calls per session

```bash
jq -r 'select(.event=="pre") | .session_id' \
    ~/.claude/logs/tool-calls-*.jsonl | sort | uniq -c | sort -rn
```

### Files edited today

```bash
jq -r 'select(.event=="pre" and (.tool=="Edit" or .tool=="Write")) | .args.file_path' \
    ~/.claude/logs/tool-calls-$(date +%Y-%m-%d).jsonl | sort -u
```

## Atomicity & failure modes

- Writes use a single `O_APPEND` syscall via `hooks/lib/jsonl-write.py`. Atomic on macOS APFS for line sizes ≤ 1 MB (the truncation cap).
- Lines exceeding 1 MB get `output.stdout`/`output.stderr` truncated with `_truncated_bytes` marker.
- `ENOSPC` (disk full) silently drops the line; never breaks the user's tool call.
- All write errors wrapped in `|| true` from the bash side. Logging cannot break Claude Code.
```

```bash
# (Use Write tool to create docs/LOGGING.md with content above)
```

- [ ] **Step 2: Verify file created**

```bash
[ -f docs/LOGGING.md ] && wc -l docs/LOGGING.md
```

Expected: file exists, ~110-130 lines.

- [ ] **Step 3: Commit**

```bash
git add docs/LOGGING.md
git commit -m "docs: add LOGGING.md with schema, redaction, rotation, jq queries"
```

---

## Task 20: Create `docs/PROMOTION-RATIONALE.md`

**Files:**
- Create: `docs/PROMOTION-RATIONALE.md`

- [ ] **Step 1: Write the doc**

```markdown
# Why nothing was promoted from `resurgent/.claude/`

The `resurgent` project (`~/Desktop/Projects/resurgent/`) has the most mature `.claude/` setup of any project: 8 agents, 11 skills, 10 commands, custom hooks, templates, docs, workflows. During design we audited each item for "should this go global?" and answered no for everything. This doc records why, and which items might become future-work generalization candidates.

## Audit table

### Agents (8)

| Agent | Why not promoted |
|---|---|
| `homelab-health-checker` | References Prometheus/Loki/toolkit-specific paths |
| `media-stack-diagnostician` | 7-service media pipeline; 16 modules tied to homelab |
| `security-auditor` | Calls bandit/dependency-audit on `toolkit/` paths; pr-review-toolkit covers generic |
| `config-drift-detector` | Compares against SCD snapshots in homelab format |
| `test-failure-investigator` | Hooks into homelab solutions KB |
| `ci-failure-analyzer` | GH Actions specific to resurgent's workflow files |
| `performance-regression-detector` | Benchmarks tied to toolkit modules |
| `homelab-operator` | Operational runbooks for /mnt/user, docker compose unified |

The compound-engineering and pr-review-toolkit plugins already provide generic agent equivalents (security-reviewer, performance-reviewer, code-reviewer, etc.).

### Skills (11)

| Skill | Why not promoted |
|---|---|
| `deploy-stack` | Docker Compose profile-specific |
| `media-health` | Media stack only |
| `run-ci-local` | Toolkit-specific lint/format/types/tests pipeline |
| `scd-snapshot` | SCD format is homelab-specific |
| `compound-knowledge` | KB schema homelab-specific (compound-engineering plugin covers generic) |
| `dependency-audit` | pip-audit on toolkit's pyproject; codex/compound plugins cover generic |
| `media-reconcile` | Cross-service media-only |
| `gen-test` | Tests follow toolkit conventions |
| `review-pr` | pr-review-toolkit plugin is the generic version |
| `security-scan` | bandit+safety+semgrep wrapper on toolkit; security-guidance plugin covers generic |
| `release` | Release workflow uses homelab-specific tagging |

### Commands (10)

| Command | Why not promoted |
|---|---|
| `/health` | System health check for homelab containers |
| `/stats` | Homelab metrics summary |
| `/benchmark` | Performance benchmarking against toolkit |
| `/container-logs` | Docker compose specific |
| `/find-files` | Thin wrapper around `fd` — Claude does this natively |
| `/quick-fix` | Generic but minimal value over native Edit |
| `/search-code` | Thin wrapper around `rg` — Claude does this natively |
| `/settings-health` | Validates resurgent's specific settings hierarchy |
| `/changelog` | Useful but lightweight; better as a per-project command |
| `/review-homelab` | Multi-agent review tied to homelab agents |

## Future generalization candidates

If a pattern recurs across other projects, consider extracting the generic core into a global agent/skill/command and parameterizing the project-specific bits:

- **`gen-test`** — could become a generic "infer test from production code" skill if conventions are project-detected
- **`security-scan`** — bandit + safety pattern is generic; promote if the security-guidance plugin proves insufficient
- **`dependency-audit`** — pip-audit / cargo deny / pnpm audit per detected language; could be a unified skill
- **`compound-knowledge`** — compound-engineering plugin's `ce-compound` already covers this; nothing to promote

When promoting, follow `docs/HOOKS.md`'s "Adding your own hook" pattern but for the appropriate component type.
```

```bash
# (Use Write tool to create docs/PROMOTION-RATIONALE.md with content above)
```

- [ ] **Step 2: Verify file created**

```bash
[ -f docs/PROMOTION-RATIONALE.md ] && wc -l docs/PROMOTION-RATIONALE.md
```

Expected: file exists.

- [ ] **Step 3: Commit**

```bash
git add docs/PROMOTION-RATIONALE.md
git commit -m "docs: add PROMOTION-RATIONALE.md explaining why no resurgent items went global"
```

---

## Task 21: Extend `README.md` with Logging + new hooks

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Inspect current README to find insertion point**

```bash
grep -n '^## ' README.md
```

Expected: shows section headers. Note positions of `## Hooks` and `## File structure`.

- [ ] **Step 2: Insert new "Logging" section after the Hooks section**

Use Edit to insert just before `## Plugins and Skills`:

```
old_string: ## Plugins and Skills
new_string: ## Logging

Every tool call (including all `mcp__*` invocations) is captured to a structured JSONL log via `hooks/log-tool-calls.sh`, fired on `PreToolUse *` and `PostToolUse *`. The log includes full tool args and output (capped at 1 MB per line, with a truncation marker), timing, exit status, and the parsed MCP server name when applicable.

- **Where:** `~/.claude/logs/tool-calls-YYYY-MM-DD.jsonl`
- **Schema, query examples, redaction rules, rotation:** [`docs/LOGGING.md`](docs/LOGGING.md)
- **Rotation:** `hooks/log-rotate.sh` runs on `SessionEnd` — gzip-rotates files >100 MB, prunes files >90 days old
- **Redaction:** secrets stripped before write — JWTs, AWS/GitHub/Anthropic/OpenAI keys, `password=`, `token=`, etc. Patterns in `hooks/lib/redact.py`

Logging never breaks a tool call: write failures (disk full, missing dir, malformed JSON) are silently dropped.

## Anti-rationalization

A `Stop` hook of `type: "prompt"` (configured in `settings.json`) reviews Claude's final response with a fast model and forces continuation if Claude is rationalizing incomplete work ("out of scope," "pre-existing," "follow-up," etc.). Tune the prompt in `settings.json`'s `hooks.Stop[0].hooks[0].prompt` if it's too strict or too lax.

## Plugins and Skills
```

- [ ] **Step 3: Update the install instructions to mention symlinks**

Find this in the README:

```
old_string: The install script is idempotent -- it merges settings into existing config, substitutes API keys from environment variables, and skips files that already exist. Use `--dry-run` to preview changes, `--force` to overwrite existing files, or pass specific components (`settings`, `mcp`, `claude-md`, `statusline`, `commands`, `hooks`).
new_string: The install script is idempotent and uses a hybrid model: `settings.json` is jq-merged in place (preserves your existing `enabledPlugins`, `extraKnownMarketplaces`, and `skipAutoPermissionPrompt`); everything else (`CLAUDE.md`, `commands/`, `hooks/`, `hooks/lib/`, `agents/`, `skills/`, `statusline.sh`) is symlinked into `~/.claude/` so edits in either place take effect immediately. Skills are symlinked per-skill so existing non-symlink skills (like `agent-browser`) survive untouched. The first install backs up any conflicting files to `~/.claude/backups/pre-claude-defaults-<ts>/`.

Use `--dry-run` to preview changes, `--force` to overwrite foreign symlinks, or pass specific components (`settings`, `mcp`, `claude-md`, `statusline`, `commands`, `hooks`, `agents`, `skills`, `logs-dir`). Run `./scripts/uninstall.sh` to reverse the install (removes our symlinks, restores latest backup).
```

- [ ] **Step 4: Update the file structure section**

Find the `## File structure` block and replace with:

```
old_string: ```
claude-defaults/
├── README.md                  # This file
├── LICENSE
├── settings.json              # Global settings template
├── mcp-template.json          # MCP server config template
├── claude-md-template.md      # Global CLAUDE.md template
├── scripts/
│   ├── install.sh             # Idempotent installer (--dry-run, --force, components)
│   ├── validate.sh            # Post-install verification
│   └── statusline.sh          # Two-line terminal status bar
├── hooks/
│   ├── block-rm-rf.sh         # PreToolUse: block rm -rf (active in settings.json)
│   ├── block-push-main.sh     # PreToolUse: block push to main (active in settings.json)
│   ├── enforce-package-manager.sh  # PreToolUse: enforce pnpm/yarn (manual setup)
│   └── log-bash-commands.sh   # PostToolUse: audit log (manual setup)
└── commands/
    ├── review-pr.md           # /review-pr <number>
    ├── fix-issue.md           # /fix-issue <number>
    └── merge-dependabot.md    # /merge-dependabot <owner/repo>
```
new_string: ```
claude-defaults/
├── README.md                       # This file
├── LICENSE
├── settings.json                   # Global settings template (merged into ~/.claude/settings.json)
├── mcp-template.json               # MCP server config template
├── claude-md-template.md           # Global CLAUDE.md template (Python/TS/Rust/Go/Bash/GH Actions)
├── scripts/
│   ├── install.sh                  # Hybrid installer (--dry-run, --force, components)
│   ├── uninstall.sh                # Reverse install, restore backup
│   ├── validate.sh                 # Verify symlinks, log dir, hooks wired
│   └── statusline.sh               # Two-line terminal status bar
├── hooks/
│   ├── block-rm-rf.sh              # legacy: block rm -rf (active)
│   ├── block-push-main.sh          # legacy: block push to main (active)
│   ├── enforce-package-manager.sh  # opt-in: enforce pnpm/yarn
│   ├── log-bash-commands.sh        # opt-in: plain audit log (superseded by log-tool-calls.sh)
│   ├── safety-block.sh             # NEW: extended destructive-pattern blocks (active)
│   ├── safety-warn.sh              # NEW: warn on sensitive Edit/Write (active)
│   ├── log-tool-calls.sh           # NEW: rich JSONL log of every tool call (active)
│   ├── log-rotate.sh               # NEW: SessionEnd gzip+prune (active)
│   └── lib/
│       ├── redact.py               # secret-pattern redaction
│       ├── jsonl-write.py          # atomic JSONL append + truncation
│       └── common.sh               # shared bash helpers
├── commands/
│   ├── review-pr.md                # /review-pr <number>
│   ├── fix-issue.md                # /fix-issue <number>
│   └── merge-dependabot.md         # /merge-dependabot <owner/repo>
├── agents/                         # scaffold for global agents (empty)
├── skills/                         # scaffold for global skills (empty)
├── docs/
│   ├── HOOKS.md                    # every hook documented
│   ├── LOGGING.md                  # log schema, queries, rotation
│   └── PROMOTION-RATIONALE.md      # what was/wasn't promoted from resurgent
└── tests/
    ├── run-all.sh                  # dispatcher
    ├── test-install.sh             # install/uninstall roundtrip
    ├── test-hooks.sh               # per-hook assertions
    ├── test-redaction.sh           # secret-pattern coverage
    ├── test-settings-valid.sh      # JSON parse + hook path checks
    └── fixtures/                   # mock Claude hook stdin inputs
```
```

- [ ] **Step 5: Verify edits**

```bash
grep -c '^## Logging$' README.md          # expect 1
grep -c '^## Anti-rationalization$' README.md  # expect 1
grep -q 'safety-block.sh' README.md && echo "safety-block referenced"
```

Expected: counts are 1; "safety-block referenced" printed.

- [ ] **Step 6: Commit**

```bash
git add README.md
git commit -m "docs(readme): add Logging + Anti-rationalization sections; updated file structure"
```

---

## Task 22: Create empty agents/ and skills/ scaffold dirs

**Files:**
- Create: `agents/.gitkeep`
- Create: `skills/.gitkeep`

- [ ] **Step 1: Create scaffold dirs**

```bash
mkdir -p agents skills
touch agents/.gitkeep skills/.gitkeep
ls -la agents/ skills/
```

Expected: both dirs exist with `.gitkeep` files.

- [ ] **Step 2: Commit**

```bash
git add agents/.gitkeep skills/.gitkeep
git commit -m "chore: add empty agents/ and skills/ scaffold dirs"
```

---

## Task 23: Run all automated tests

**Files:** none (verification only)

- [ ] **Step 1: Run the full test suite**

```bash
bash tests/run-all.sh
```

Expected: "ALL TESTS PASSED"; exit 0. Each test script printed its own PASS line.

- [ ] **Step 2: If anything failed, fix and re-run**

If a test fails: read the FAIL message, locate the offending file, fix the bug, re-run `bash tests/run-all.sh` until green. Do not proceed until all pass.

- [ ] **Step 3: Commit any fixes**

```bash
git status
# If any files were modified by fixes:
git add -u
git commit -m "fix(tests): address failures from test-suite run"
```

---

## Task 24: Run install.sh --dry-run against real `$HOME`, review

**Files:** none (verification only)

- [ ] **Step 1: Dry-run the installer**

```bash
./scripts/install.sh --dry-run | tee /tmp/install-dryrun.log
```

Expected: shows DRY-RUN entries for each backup + symlink + merge. No actual changes.

- [ ] **Step 2: Review the dry-run output for surprises**

```bash
grep "would" /tmp/install-dryrun.log | head -40
```

Confirm:
- `~/.claude/CLAUDE.md` will be backed up (you don't have one currently — check)
- `~/.claude/settings.json` will be jq-merged
- `~/.claude/skills/agent-browser/` is NOT in the action list (preserved)
- All hooks/commands listed for symlinking
- `~/.claude/logs/` will be created

If anything looks wrong, STOP and fix before Step 3.

---

## Task 25: Run install.sh for real, run validate.sh

**Files:** affects `~/.claude/` directly

- [ ] **Step 1: Install for real**

```bash
./scripts/install.sh | tee /tmp/install.log
```

Expected: list of "OK:" lines for each symlink + merge + log dir. Final line: "Done." with backup path.

- [ ] **Step 2: Run validator**

```bash
./scripts/validate.sh
```

Expected: every check shows green "OK"; "PASSED: All checks OK".

- [ ] **Step 3: Manually inspect a few key links**

```bash
ls -la ~/.claude/CLAUDE.md ~/.claude/settings.json ~/.claude/hooks/safety-block.sh ~/.claude/skills/agent-browser
```

Expected:
- `CLAUDE.md` shows `-> /Users/mills/Desktop/Projects/claude-defaults/claude-md-template.md`
- `settings.json` is a regular file (no `->`)
- `safety-block.sh` shows `-> /Users/mills/Desktop/Projects/claude-defaults/hooks/safety-block.sh`
- `agent-browser` is a regular dir (no `->`) — preserved

---

## Task 26: Manual smoke test in a fresh Claude Code session

**Files:** none (verification only)

- [ ] **Step 1: Open a new Claude Code session in any project**

```
# (User action — open Claude Code, e.g. in ~/Desktop/Projects/claude-defaults itself)
```

- [ ] **Step 2: Tail the log in another terminal**

```bash
tail -f ~/.claude/logs/tool-calls-$(date +%Y-%m-%d).jsonl | jq .
```

- [ ] **Step 3: In the Claude session, exercise each hook category**

Run these prompts in the session and verify the expected behavior:

| Prompt | Expected behavior |
|---|---|
| "What's in this directory?" → triggers `Bash: ls` | log shows `pre`+`post` rows for `Bash` with command, exit_status, duration |
| "Use the Playwright MCP to take a screenshot of example.com" | log shows row with `tool: "mcp__plugin_playwright_playwright__browser_navigate"` and `mcp_server: "plugin"` (or similar) |
| "Run `rm -rf /tmp/this-is-a-test-xyz`" | Claude should refuse — `safety-block.sh` rejects with the BLOCKED message |
| "Edit `/tmp/test.env` and set `KEY=value`" | warning printed to stderr (visible to Claude); Edit proceeds |
| Ask Claude to declare a half-finished task complete | anti-rationalization Stop hook should reject and force continuation |

- [ ] **Step 4: Inspect the log file for redaction**

```bash
# Run a command containing a fake secret in the session, then:
grep -E "ghp_|AKIA|sk-ant" ~/.claude/logs/tool-calls-$(date +%Y-%m-%d).jsonl
```

Expected: no real-looking secrets; only `***GH_TOKEN***`, `***AWS_KEY***`, `***ANTHROPIC_KEY***` markers.

- [ ] **Step 5: Confirm anti-rationalization fires**

This one's harder to force. Watch for it organically across normal use, OR ask Claude something like: "List the bugs in this file but don't fix any of them, then say you're done." The Stop hook should respond and force a follow-up.

---

## Task 27: Push the feature branch and open PR (or merge)

**Files:** none (git operations)

- [ ] **Step 1: Review what's about to be pushed**

```bash
git log --oneline main..feat/centralize-config
git diff --stat main..feat/centralize-config
```

Expected: ~22-25 commits; reasonable file changes.

- [ ] **Step 2: Push the branch**

```bash
git push -u origin feat/centralize-config
```

Expected: branch pushed.

- [ ] **Step 3: Open PR (or merge directly if you prefer)**

```bash
# Option A: open PR for review
gh pr create --title "Centralize Claude Code config — add logging, expand safety, switch to hybrid install" --body "$(cat <<'EOF'
## Summary
- Switch install from copy to hybrid: symlinks for content, jq-merge for settings.json
- Add structured JSONL tool/MCP logging with redaction and rotation
- Expand safety hooks: block destructive Bash patterns, warn on sensitive Edits
- Wire up anti-rationalization Stop hook by default
- Add Go to the CLAUDE.md style guide; add output preferences and comments policy
- New scaffolding for global agents/ and skills/

See `docs/superpowers/specs/2026-04-26-centralize-claude-config-design.md` for the design rationale and `docs/superpowers/plans/2026-04-26-centralize-claude-config.md` for the implementation steps.

## Test plan
- [x] `tests/run-all.sh` green
- [x] Manual smoke test in fresh Claude Code session: every hook category exercised
- [x] Log shows pre/post rows including MCP calls; secrets redacted; <1 MB lines
- [x] safety-block.sh rejects rm -rf, dd, mkfs, force-push, etc.
- [x] safety-warn.sh warns on .env / credentials / .pem / .key
- [x] Anti-rationalization Stop hook fires when Claude rationalizes incomplete work
- [x] uninstall.sh restores pre-install state from backup
EOF
)"

# Option B: merge to main directly
# git checkout main && git merge --no-ff feat/centralize-config && git push origin main
```

Expected: PR opened (or merged), URL printed.

- [ ] **Step 4: After merge, delete the feature branch**

```bash
git checkout main
git pull
git branch -d feat/centralize-config
git push origin --delete feat/centralize-config 2>/dev/null || true
```

---

## Self-review checklist

After completing all tasks, verify:

- [ ] **Spec coverage:** every section in `docs/superpowers/specs/2026-04-26-centralize-claude-config-design.md` has a corresponding task above. Sections 1-3 (problem/goals/non-goals): no impl needed. Section 4 (foundation): Task 1. Section 5 (file layout): all create-tasks. Section 6 (distribution): Task 11. Section 7 (components): Tasks 2-10, 14-22. Section 8 (data flow): no impl — verified in Task 26. Section 9 (error handling): tested across hook tasks. Section 10 (testing): Tasks 14-17, 23. Section 11 (migration): Tasks 1, 24-27. Section 12 (open questions): documented in spec; not impl. Section 13 (decisions): codified throughout.
- [ ] **No placeholders:** every code block is complete, no TODO/FIXME/TBD.
- [ ] **Type/path consistency:** function names match between definition and use (`redact_value`, `redact_string`, `_truncate_output`, `SCRIPT_DIR_OF`, `claude_logs_dir`, `extract_jq_field`); env var names consistent (`CLAUDE_LOG_MAX_LINE_BYTES`, `CLAUDE_LOG_ROTATE_BYTES`, `CLAUDE_LOG_RETAIN_DAYS`); file paths consistent (`hooks/lib/redact.py`, `hooks/log-tool-calls.sh`, etc).
