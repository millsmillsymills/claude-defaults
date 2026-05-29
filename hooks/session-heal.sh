#!/usr/bin/env bash
# SessionStart hook: lightweight self-heal of the claude-defaults install.
# Recreates missing/dangling symlinks and runtime dirs so a renamed or removed
# hook can't surface a "No such file or directory" error mid-session. Stays
# silent and never blocks startup.
set -uo pipefail

self="${BASH_SOURCE[0]}"
real="$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$self" 2>/dev/null ||
  readlink "$self" 2>/dev/null || echo "$self")"
repo="$(cd "$(dirname "$real")/.." 2>/dev/null && pwd || true)"

[ -n "$repo" ] && [ -x "${repo}/scripts/doctor.sh" ] || exit 0
"${repo}/scripts/doctor.sh" --quick >/dev/null 2>&1 || true
exit 0
