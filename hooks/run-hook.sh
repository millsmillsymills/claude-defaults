#!/usr/bin/env bash
# Resilient hook dispatcher. settings.json routes every command-type hook
# through this wrapper as `run-hook.sh <hook-name> [args...]`, so a missing
# directory or a stale/renamed hook script can never surface a
# "/bin/sh: ...: No such file or directory" failure. See docs/HOOKS.md.
#
# Invariant: never exit non-zero for OUR OWN plumbing errors -- only the real
# hook's exit code (which may be 2 to block) is propagated. A hook that can't be
# found fails OPEN (exit 0), with a loud, durable signal for security hooks.
# Link/dir repair belongs to doctor.sh, not this hot path.
set -uo pipefail

CLAUDE_DIR="${HOME}/.claude"
mkdir -p "${CLAUDE_DIR}/logs" "${CLAUDE_DIR}/hooks/lib" 2>/dev/null || true

# Hooks whose absence leaves the user UNPROTECTED. The deny-list in settings.json
# only backstops the rm-rf/sudo classes; these guard dd/mkfs/fdisk/fork-bomb/
# chmod-777/force-push too. A silent skip of one is the worst failure mode, so
# any skip below is logged durably and warned loudly rather than failing open
# quietly.
SECURITY_HOOKS=" safety-block.py block-rm-rf.sh block-push-main.sh "

# Record a security hook being skipped to a durable log AND stderr, so a
# never-ran guard is visible after the fact instead of silently allowing.
warn_security_skip() {
  local reason="$1"
  case "$SECURITY_HOOKS" in
  *" ${name} "*)
    echo "run-hook.sh: SECURITY hook '${name}' SKIPPED (${reason});" >&2
    echo "  destructive-command guard NOT enforced. Run scripts/doctor.sh." >&2
    echo "$(date -u '+%Y-%m-%dT%H:%M:%SZ') ${name} ${reason}" \
      >>"${CLAUDE_DIR}/logs/hook-errors.log" 2>/dev/null || true
    ;;
  esac
}

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

# Pick a runnable target: the installed path if it resolves to a real file
# (-f follows the symlink, so a dangling link falls through), else the repo copy.
# Don't rewrite the symlink here -- silently mutating a security-relevant path on
# every tool call is the wrong layer; doctor.sh / session-heal.sh repair links.
target=""
if [ -f "$installed" ]; then
  target="$installed"
elif [ -n "$repo_src" ] && [ -f "$repo_src" ]; then
  target="$repo_src"
fi

if [ -z "$target" ]; then
  warn_security_skip "not found"
  echo "run-hook.sh: hook '${name}' not found (looked in ${installed} and" >&2
  echo "  ${repo_src:-<repo unresolved>}); skipping. Run scripts/doctor.sh to repair." >&2
  exit 0
fi

case "$name" in
*.py)
  if ! command -v python3 >/dev/null 2>&1; then
    warn_security_skip "python3 unavailable"
    exit 0
  fi
  exec python3 "$target" "$@"
  ;;
*)
  exec bash "$target" "$@"
  ;;
esac
