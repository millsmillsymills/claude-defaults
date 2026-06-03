#!/usr/bin/env bash
# SessionStart hook: lightweight self-heal of the claude-defaults install.
# Wired DIRECTLY in settings.json (not via run-hook.sh) so it can rebuild the
# wrapper's own symlink when that is the thing that went missing -- repairing
# dangling links and runtime dirs before a renamed/removed hook surfaces a
# "No such file or directory" error mid-session. Never blocks startup.
set -uo pipefail

self="${BASH_SOURCE[0]}"
real="$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$self" 2>/dev/null ||
  readlink "$self" 2>/dev/null || echo "$self")"
repo="$(cd "$(dirname "$real")/.." 2>/dev/null && pwd || true)"

[ -n "$repo" ] && [ -x "${repo}/scripts/doctor.sh" ] || exit 0

# Keep doctor's output as a forensic trail (a persistent heal failure is
# otherwise invisible across sessions), but never let it block startup.
log="${HOME}/.claude/logs/session-heal.log"
mkdir -p "$(dirname "$log")" 2>/dev/null || true
"${repo}/scripts/doctor.sh" --quick >>"$log" 2>&1 || true
exit 0
