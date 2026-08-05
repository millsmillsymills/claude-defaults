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

# shellcheck source=scripts/hook-events.sh
. "$(dirname "$0")/hook-events.sh"
hook_events_load

pass() { printf "  \033[32mOK\033[0m  %s\n" "$1"; }
fail() {
  printf "  \033[31mFAIL\033[0m  %s\n" "$1"
  ((errors++)) || true
}
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
  if python3 -m json.tool <"${CLAUDE_DIR}/settings.json" >/dev/null 2>&1; then
    pass "settings.json is valid JSON"
  else
    fail "settings.json is invalid JSON"
  fi
  # Hooks wired: pull commands only from the canonical hook events (shared
  # with install.sh via hook-events.sh) and require each to appear as a
  # hooks/<name>.sh path -- not merely as a substring anywhere in the file
  # (the old `.. | objects | .command` walk would pass on a stray reference
  # in any unrelated section). Iterating the full event set means a hook
  # wired only under Stop/UserPromptSubmit is no longer invisible.
  wired=$(jq -r '
        ($ARGS.positional) as $events |
        [ $events[] as $e | (.hooks[$e] // [])[]?.hooks[]?.command ]
        | .[] | select(. != null)
    ' --args "${HOOK_EVENTS[@]}" <"${CLAUDE_DIR}/settings.json" 2>/dev/null)
  # run-hook.sh is load-bearing: every command hook is invoked through it, so a
  # missing wrapper silently breaks all of them. Check it explicitly alongside
  # the security/logging hooks it dispatches. The hook name appears as a bare
  # argument to run-hook.sh, so match the basename anywhere in the command
  # rather than anchoring on a hooks/ path prefix.
  for hook_name in run-hook safety-block block-rm-rf block-push-main block-research-env-clobber safety-warn log-tool-calls log-rotate; do
    if echo "$wired" | grep -qE "${hook_name}\.(sh|py)($|[[:space:]])"; then
      pass "settings.json wires ${hook_name}"
    else
      fail "settings.json does NOT wire ${hook_name} under a hook event"
    fi
  done
else
  fail "${CLAUDE_DIR}/settings.json missing"
fi

# Symlinked content. Derive expectations from the repo (mirroring install.sh's
# globs) so a new/renamed/removed file is caught automatically instead of
# drifting from a hardcoded list.
echo "--- symlinks ---"
declare -a EXPECTED_SYMLINKS=(
  "${CLAUDE_DIR}/CLAUDE.md|${REPO_DIR}/claude-md-template.md"
  "${CLAUDE_DIR}/statusline.sh|${REPO_DIR}/scripts/statusline.sh"
)
for f in "${REPO_DIR}"/hooks/*.sh "${REPO_DIR}"/hooks/*.py "${REPO_DIR}"/hooks/lib/* \
  "${REPO_DIR}"/commands/*.md "${REPO_DIR}"/agents/*.md; do
  [ -f "$f" ] || continue
  rel="${f#"${REPO_DIR}"/}"
  EXPECTED_SYMLINKS+=("${CLAUDE_DIR}/${rel}|${f}")
done
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
# Skills: install symlinks each repo skill dir unless a real dir pre-exists,
# so a real dir is acceptable (preserved), a correct symlink is ideal, and
# missing is a failure.
for d in "${REPO_DIR}"/skills/*/; do
  [ -d "$d" ] || continue
  name=$(basename "$d")
  dst="${CLAUDE_DIR}/skills/${name}"
  if [ -L "$dst" ]; then
    actual=$(readlink "$dst")
    if [ "$actual" = "${d%/}" ]; then pass "skill $name -> ${d%/}"; else fail "skill $name -> $actual (expected ${d%/})"; fi
  elif [ -d "$dst" ]; then
    warn "skill $name is a real dir (pre-existing; install preserves it)"
  else
    fail "skill $name not installed"
  fi
done

# Logs dir is real
echo "--- logs ---"
if [ -L "${CLAUDE_DIR}/logs" ]; then
  fail "${CLAUDE_DIR}/logs is a symlink (should be a real directory)"
elif [ -d "${CLAUDE_DIR}/logs" ]; then
  pass "${CLAUDE_DIR}/logs is a real directory"
  # Warn (don't fail) if today's log is missing or
  # very stale. Lets agents distinguish "logging working" from "logging
  # silently broken" without false-positive on a freshly-installed-but-
  # never-used setup.
  today_utc=$(python3 -c 'import datetime; print(datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d"))' 2>/dev/null || date -u +%Y-%m-%d)
  today_log="${CLAUDE_DIR}/logs/tool-calls-${today_utc}.jsonl"
  if [ ! -f "$today_log" ]; then
    if ls "${CLAUDE_DIR}/logs/tool-calls-${today_utc}.jsonl"*.gz >/dev/null 2>&1; then
      pass "${today_log} rotated to .gz (logging healthy)"
    else
      warn "${today_log} missing (no log rows yet today; OK for a fresh install or unused day)"
    fi
  else
    # mtime within last 24h?
    if find "$today_log" -mtime -1 -print 2>/dev/null | grep -q .; then
      pass "${today_log} updated within 24h"
    else
      warn "${today_log} not updated within 24h (logging may be silently broken)"
    fi
  fi
else
  fail "${CLAUDE_DIR}/logs missing"
fi

# Hook executability (through symlinks); derived from the repo's hooks.
echo "--- executable ---"
for f in "${REPO_DIR}"/hooks/*.sh "${REPO_DIR}"/hooks/*.py; do
  [ -f "$f" ] || continue
  inst="${CLAUDE_DIR}/hooks/$(basename "$f")"
  if [ -x "$inst" ]; then pass "$inst executable"; else fail "$inst not executable"; fi
done
if [ -x "${CLAUDE_DIR}/statusline.sh" ]; then pass "statusline.sh executable"; else fail "statusline.sh not executable"; fi

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
