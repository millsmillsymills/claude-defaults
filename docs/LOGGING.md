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

Patterns auto-stripped before write (source of truth: `hooks/lib/_log_core.py` `_PATTERNS`):

| Pattern | Replacement |
|---|---|
| JWT tokens | `***JWT***` |
| AWS access keys (`AKIA...`) | `***AWS_KEY***` |
| AWS STS keys (`ASIA...`) | `***AWS_STS_KEY***` |
| GitHub tokens (`ghp_/gho_/ghs_/ghu_`) | `***GH_TOKEN***` |
| GitHub fine-grained PATs (`github_pat_...`) | `***GH_PAT***` |
| Anthropic keys (`sk-ant-...`) | `***ANTHROPIC_KEY***` |
| OpenAI keys (`sk-...`) | `***OPENAI_KEY***` |
| URL userinfo passwords (`user:pass@host`) | `user:***@host` |
| `password=`, `token=`, `secret=`, `api_key=`, `bearer:`, `authorization:` | value `***` |
| `--password=`, `--token=`, `--secret=`, `--api-key=` | value `***` |

This table is a summary; `_log_core.py` is the full, authoritative set.

If you need to add a pattern, edit `hooks/lib/_log_core.py`'s `_PATTERNS` list — it's the single source of truth, imported by all three callers (`redact.py` CLI, `jsonl_write.py` CLI, and the live `log_tool_call.py` logging pipeline). Add a case to `tests/test-redaction.sh`. To re-redact older logs after adding a pattern, run `python3 scripts/redact-existing-logs.py <log-file>` (one-off; not auto-installed).

## Rotation policy

`log-rotate.sh` runs on `SessionEnd`:

1. If `tool-calls-YYYY-MM-DD.jsonl` exceeds `CLAUDE_LOG_ROTATE_BYTES` (default `104857600` = 100 MB), gzip-rotate it to `tool-calls-YYYY-MM-DD.jsonl.<N>.gz` (`<N>` is next available integer)
2. Delete any `tool-calls-*.jsonl*` older than `CLAUDE_LOG_RETAIN_DAYS` mtime days (default 365)

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

- Writes use a single `O_APPEND` syscall (via the helpers in `hooks/lib/_log_core.py`, exposed by both `hooks/lib/jsonl_write.py` and `hooks/lib/log_tool_call.py`). Atomic on macOS APFS for line sizes ≤ 1 MB (the truncation cap).
- Lines exceeding 1 MB get `output.stdout`/`output.stderr` truncated with `_truncated_bytes` marker.
- `ENOSPC` (disk full) silently drops the line; never breaks the user's tool call.
- All write errors wrapped in `|| true` from the bash side. Logging cannot break Claude Code.
