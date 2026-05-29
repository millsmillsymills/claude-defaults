#!/usr/bin/env bash
# Resilient hook dispatcher. settings.json routes every command-type hook
# through this wrapper so a missing directory or a stale/renamed hook script
# can never surface a "/bin/sh: ...: No such file or directory" failure.
#
# Wire up in settings.json:
#   command: "$HOME/.claude/hooks/run-hook.sh <hook-name> [args...]"
# e.g.
#   command: "$HOME/.claude/hooks/run-hook.sh safety-block.py"
#   command: "$HOME/.claude/hooks/run-hook.sh log-tool-calls.sh pre"
#
# Behavior:
#   - Ensures the runtime dirs (logs/, hooks/lib/) exist.
#   - Resolves its own symlink back to the repo so it can run the real hook
#     directly even if ~/.claude/hooks/<name> is missing or dangling, and
#     opportunistically recreates that symlink.
#   - If the hook truly cannot be found, warns on stderr and exits 0 so the
#     tool call is NOT blocked by infrastructure breakage. (PreToolUse blocking
#     hooks fail OPEN here; doctor.sh / install.sh restore them between runs.)
#
# Never exit non-zero for our own plumbing errors -- only the real hook's exit
# code (which may be 2 to block) is propagated.
set -uo pipefail

CLAUDE_DIR="${HOME}/.claude"
mkdir -p "${CLAUDE_DIR}/logs" "${CLAUDE_DIR}/hooks/lib" 2>/dev/null || true

if [ "$#" -lt 1 ]; then
  echo "run-hook.sh: no hook name given" >&2
  exit 0
fi
name="$1"
shift

# Absolute path of a symlink's ultimate target (python3 preferred; readlink
# fallback resolves only one hop but covers the common single-link case).
resolve_link() {
  if command -v python3 >/dev/null 2>&1; then
    python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$1" 2>/dev/null
  else
    readlink "$1" 2>/dev/null
  fi
}

# Repo hooks dir = dir of this script's real (de-symlinked) location.
self="${BASH_SOURCE[0]}"
self_real="$(resolve_link "$self")"
[ -n "$self_real" ] || self_real="$self"
repo_hooks="$(cd "$(dirname "$self_real")" 2>/dev/null && pwd || true)"

installed="${CLAUDE_DIR}/hooks/${name}"
repo_src="${repo_hooks:+${repo_hooks}/${name}}"

# Pick a runnable target: prefer the installed symlink if it resolves to a real
# file, else fall back to the repo copy and (re)create the symlink for next time.
target=""
if [ -f "$installed" ]; then
  target="$installed"
elif [ -n "$repo_src" ] && [ -f "$repo_src" ]; then
  target="$repo_src"
  [ -L "$installed" ] && rm -f "$installed" 2>/dev/null || true
  ln -s "$repo_src" "$installed" 2>/dev/null || true
fi

if [ -z "$target" ]; then
  echo "run-hook.sh: hook '${name}' not found (looked in ${installed} and ${repo_src:-<repo unresolved>}); skipping. Run scripts/doctor.sh to repair." >&2
  exit 0
fi

case "$name" in
*.py)
  command -v python3 >/dev/null 2>&1 || exit 0
  exec python3 "$target" "$@"
  ;;
*)
  exec bash "$target" "$@"
  ;;
esac
