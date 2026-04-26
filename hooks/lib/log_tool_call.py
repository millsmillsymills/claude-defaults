#!/usr/bin/env python3
"""Consolidated PreToolUse + PostToolUse logger for claude-defaults.

Replaces the bash + 4-jq + 5-python3 + redact.py + jsonl-write.py pipeline
with a single python3 invocation per tool call. Same on-disk schema as the
bash version; same redaction patterns; same temp-file pairing.

Usage: log_tool_call.py {pre|post}
       (reads Claude Code hook JSON from stdin)

Logging failures NEVER break a tool call -- all errors caught and swallowed,
exit 0 unconditionally on failure paths.

Compatible with Python 3.9+ (relies on PEP 563 deferred annotations).
"""
from __future__ import annotations

import errno
import hashlib
import json
import os
import re
import sys
import time
from datetime import datetime, timezone
from pathlib import Path


# ---------------------------------------------------------------------------
# Redaction patterns (kept in sync with hooks/lib/redact.py)
# ---------------------------------------------------------------------------
_PATTERNS: list[tuple[re.Pattern[str], str]] = [
    (re.compile(r"eyJ[A-Za-z0-9_\-]{4,}\.eyJ[A-Za-z0-9_\-]{4,}\.[A-Za-z0-9_\-]{4,}"),
     "***JWT***"),
    (re.compile(r"\bAKIA[0-9A-Z]{16}\b"), "***AWS_KEY***"),
    (re.compile(r"\bgh[opsu]_[A-Za-z0-9]{36,}\b"), "***GH_TOKEN***"),
    (re.compile(r"\bsk-ant-[A-Za-z0-9_\-]{8,}\b"), "***ANTHROPIC_KEY***"),
    (re.compile(r"\bsk-[A-Za-z0-9]{40,80}\b"), "***OPENAI_KEY***"),
    (re.compile(
        r"(?i)\b(password|passwd|secret|token|api[_-]?key)"
        r"(\s*[:=]\s*)([^\s,;'\"]{3,})"
    ), r"\1\2***"),
    (re.compile(
        r"(?i)\b(authorization|bearer)"
        r"(\s*[:=]\s*|\s+)([^*,;'\"\r\n]{3,})"
    ), r"\1\2***"),
    (re.compile(
        r"(--(?:password|token|secret|api[_-]?key))(=)([^\s,;'\"]{3,})"
    ), r"\1\2***"),
]


def _redact_value(v):
    if isinstance(v, str):
        for pat, repl in _PATTERNS:
            v = pat.sub(repl, v)
        return v
    if isinstance(v, list):
        return [_redact_value(x) for x in v]
    if isinstance(v, dict):
        return {k: _redact_value(val) for k, val in v.items()}
    return v


# ---------------------------------------------------------------------------
# JSONL write with truncation (kept in sync with hooks/lib/jsonl-write.py)
# ---------------------------------------------------------------------------
DEFAULT_MAX_LINE = 1024 * 1024  # 1 MB


def _truncate_output(obj: dict, max_bytes: int) -> dict:
    serialized = json.dumps(obj, ensure_ascii=False)
    overhead = len((serialized + "\n").encode("utf-8")) - max_bytes
    if overhead <= 0:
        return obj
    output = obj.get("output")
    if not isinstance(output, dict):
        return obj
    truncated_total = 0
    for key in ("stdout", "stderr"):
        v = output.get(key)
        if not isinstance(v, str):
            continue
        encoded = v.encode("utf-8")
        if len(encoded) <= 256:
            continue
        keep = max(256, len(encoded) - max(0, overhead - truncated_total))
        if keep < len(encoded):
            output[key] = encoded[:keep].decode("utf-8", errors="replace")
            truncated_total += len(encoded) - keep
        serialized = json.dumps(obj, ensure_ascii=False)
        if len((serialized + "\n").encode("utf-8")) <= max_bytes:
            break
    if truncated_total > 0:
        output["_truncated_bytes"] = truncated_total
    return obj


def _atomic_append(path: str, obj: dict) -> None:
    line = (json.dumps(obj, ensure_ascii=False) + "\n").encode("utf-8")
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    fd = os.open(path, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o644)
    try:
        os.write(fd, line)
    finally:
        os.close(fd)


# ---------------------------------------------------------------------------
# Hook entry
# ---------------------------------------------------------------------------
_SAFE_CHARS = re.compile(r"[^A-Za-z0-9_\-]")


def _sanitize(s: str) -> str:
    return _SAFE_CHARS.sub("_", s) if s else "unknown"


def _parse_mcp_server(tool: str) -> str | None:
    if not tool.startswith("mcp__"):
        return None
    rest = tool[len("mcp__"):]
    sep = rest.find("__")
    if sep <= 0:
        return None
    return rest[:sep]


def _now_iso() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z")


def _call_id() -> str:
    return f"{int(time.time() * 1_000_000)}-{os.getpid()}"


def _pair_key(session_id: str, tool_input: dict) -> str:
    h = hashlib.sha256(json.dumps(tool_input, sort_keys=True, ensure_ascii=False).encode("utf-8")).hexdigest()[:16]
    return f"{_sanitize(session_id)}-{h}"


def _temp_dir() -> str:
    return os.environ.get("TMPDIR", "/tmp").rstrip("/")


def _max_line_bytes() -> int:
    try:
        return int(os.environ.get("CLAUDE_LOG_MAX_LINE_BYTES", DEFAULT_MAX_LINE))
    except ValueError:
        return DEFAULT_MAX_LINE


def main() -> int:
    event = "pre"
    if len(sys.argv) >= 2 and sys.argv[1] in ("pre", "post"):
        event = sys.argv[1]

    try:
        raw = sys.stdin.read()
        data = json.loads(raw) if raw.strip() else {}
    except (json.JSONDecodeError, OSError):
        return 0  # logging never breaks a tool call

    session_id = str(data.get("session_id") or "unknown")
    cwd = str(data.get("cwd") or "unknown")
    tool = str(data.get("tool_name") or "unknown")
    tool_input = data.get("tool_input") or {}
    if not isinstance(tool_input, dict):
        tool_input = {"_raw": tool_input}

    mcp_server = _parse_mcp_server(tool)
    log_dir = Path.home() / ".claude" / "logs"
    log_file = str(log_dir / f"tool-calls-{datetime.now().strftime('%Y-%m-%d')}.jsonl")
    pair_path = os.path.join(_temp_dir(), f"claude-tool-{_pair_key(session_id, tool_input)}")

    if event == "pre":
        try:
            with open(pair_path, "w") as f:
                f.write(f"{_call_id()} {time.time()}\n")
        except OSError:
            pass

        payload = {
            "ts": _now_iso(),
            "session_id": session_id,
            "cwd": cwd,
            "event": "pre",
            "call_id": _call_id(),
            "tool": tool,
            "mcp_server": mcp_server,
            "args": _redact_value(tool_input),
        }
    else:
        # Post: pair by content hash. Fall back to most-recent same-session
        # file (handles the case where pre-row was missing).
        start_time = None
        if os.path.isfile(pair_path):
            try:
                with open(pair_path) as f:
                    parts = f.read().split()
                    if len(parts) >= 2:
                        start_time = float(parts[1])
            except (OSError, ValueError):
                pass
            try:
                os.unlink(pair_path)
            except OSError:
                pass
        else:
            session_safe = _sanitize(session_id)
            if session_safe and session_safe != "unknown":
                try:
                    candidates = sorted(
                        Path(_temp_dir()).glob(f"claude-tool-{session_safe}-*"),
                        key=lambda p: p.stat().st_mtime,
                        reverse=True,
                    )
                    if candidates:
                        with open(candidates[0]) as f:
                            parts = f.read().split()
                            if len(parts) >= 2:
                                start_time = float(parts[1])
                        try:
                            candidates[0].unlink()
                        except OSError:
                            pass
                except OSError:
                    pass

        duration_ms = int((time.time() - start_time) * 1000) if start_time else 0
        tool_response = data.get("tool_response") or {}
        if not isinstance(tool_response, dict):
            tool_response = {"_raw": tool_response}
        exit_status = tool_response.get("exit_code", tool_response.get("exitCode", 0))
        try:
            exit_status = int(exit_status)
        except (TypeError, ValueError):
            exit_status = 0

        payload = {
            "ts": _now_iso(),
            "session_id": session_id,
            "cwd": cwd,
            "event": "post",
            "call_id": _call_id(),
            "tool": tool,
            "mcp_server": mcp_server,
            "exit_status": exit_status,
            "duration_ms": duration_ms,
            "output": _redact_value(tool_response),
        }

    payload = _truncate_output(payload, _max_line_bytes())
    try:
        _atomic_append(log_file, payload)
    except OSError as exc:
        if exc.errno == errno.ENOSPC:
            return 0
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception:
        # Never break a tool call due to logging.
        sys.exit(0)
