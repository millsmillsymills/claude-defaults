#!/usr/bin/env bash
set -uo pipefail

# Self-heal a claude-defaults install. Fixes the drift that install.sh alone
# can't: dangling symlinks left behind when a repo hook is renamed/removed
# (install.sh only iterates files that currently exist, so a stale link to a
# vanished source is never revisited).
#
# Usage:
#   ./scripts/doctor.sh [--quick] [--dry-run]
#     --quick    Symlinks + dirs only; skip the settings.json re-merge.
#                Used by the SessionStart hook so startup stays cheap and
#                never rewrites settings.json behind the user's back.
#     (default)  Quick repairs + re-merge settings.json from the template
#                (collapses duplicated hook groups, picks up renamed hooks).
#
# Idempotent and safe to run repeatedly.

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CLAUDE_DIR="${HOME}/.claude"
QUICK=0
DRY_RUN=0

for arg in "$@"; do
  case "$arg" in
  --quick) QUICK=1 ;;
  --dry-run) DRY_RUN=1 ;;
  --help | -h)
    echo "Usage: $0 [--quick] [--dry-run]"
    exit 0
    ;;
  *)
    echo "Unknown option: $arg" >&2
    exit 1
    ;;
  esac
done

log() { echo "  $1"; }
ok() { echo "  OK: $1"; }
dry() { echo "  DRY-RUN: $1"; }

# Remove symlinks under the managed dirs that point into this repo but whose
# target no longer exists (e.g. a renamed hook). Foreign or still-valid links
# are left untouched.
prune_dangling() {
  local dir count=0
  for dir in hooks "hooks/lib" commands agents skills; do
    local d="${CLAUDE_DIR}/${dir}"
    [ -d "$d" ] || continue
    local f
    for f in "$d"/*; do
      [ -L "$f" ] || continue
      [ -e "$f" ] && continue # resolves fine -> not dangling
      local tgt
      tgt=$(readlink "$f")
      case "$tgt" in
      "${REPO_DIR}"/*)
        count=$((count + 1))
        if [ "$DRY_RUN" = "1" ]; then
          dry "prune dangling symlink $f -> $tgt"
        else
          rm -f "$f"
          ok "pruned dangling symlink: $f -> $tgt"
        fi
        ;;
      esac
    done
  done
  [ "$count" = "0" ] && log "no dangling symlinks"
}

echo "claude-defaults doctor"
echo "  repo:   $REPO_DIR"
echo "  target: $CLAUDE_DIR"
[ "$QUICK" = "1" ] && echo "  mode: QUICK"
[ "$DRY_RUN" = "1" ] && echo "  mode: DRY RUN"
echo ""

echo "--- prune dangling symlinks ---"
prune_dangling

# Recreate missing dirs + (re)link current repo content. install.sh is
# idempotent: correct links are left as-is, missing ones recreated, real user
# files backed up before replacement.
echo "--- heal content (via install.sh) ---"
# Single array (always non-empty) so the expansion is safe under bash 3.2 + set -u.
install_argv=()
[ "$DRY_RUN" = "1" ] && install_argv+=(--dry-run)
[ "$QUICK" != "1" ] && install_argv+=(--force) # re-merge settings even if already wired
install_argv+=(hooks commands agents skills statusline claude-md logs-dir)
[ "$QUICK" != "1" ] && install_argv+=(settings)
bash "${REPO_DIR}/scripts/install.sh" "${install_argv[@]}"

echo ""
echo "doctor complete. Run scripts/validate.sh to verify."
