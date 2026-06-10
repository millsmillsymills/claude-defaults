#!/usr/bin/env bash
set -uo pipefail

# Self-heal a claude-defaults install. Fixes the drift that install.sh alone
# can't: dangling symlinks left behind when a repo hook is renamed/removed
# (install.sh only iterates files that currently exist, so a stale link to a
# vanished source is never revisited).
#
# --quick (used by the SessionStart hook) does symlink/dir repair only and
# skips the settings.json re-merge, so startup stays cheap and never rewrites
# settings.json behind the user's back. Idempotent and safe to run repeatedly.

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
# Re-link symlinked content with --force so a foreign or stale link (e.g. one
# left by a renamed hook) is overwritten rather than backed up and left in
# place. Settings is handled separately below -- it must NOT get --force.
# Single array (always non-empty) so the expansion is safe under bash 3.2 + set -u.
# set -uo pipefail has no -e, so a failed install.sh would otherwise be
# swallowed and doctor would still exit 0. Track each pass and propagate.
rc=0
link_argv=()
[ "$DRY_RUN" = "1" ] && link_argv+=(--dry-run)
link_argv+=(--force hooks commands agents skills statusline claude-md logs-dir)
bash "${REPO_DIR}/scripts/install.sh" "${link_argv[@]}" || rc=1

# Re-merge settings WITHOUT --force so an unchanged merge is a true no-op:
# install.sh's content-aware guard then skips the rewrite and takes no backup,
# while a drifted file still re-merges (collapsing duplicated hook groups and
# picking up renamed hooks). --force would defeat that and rewrite every run.
# Skipped in --quick so startup never rewrites settings.json behind the user.
if [ "$QUICK" != "1" ]; then
  settings_argv=()
  [ "$DRY_RUN" = "1" ] && settings_argv+=(--dry-run)
  settings_argv+=(settings)
  bash "${REPO_DIR}/scripts/install.sh" "${settings_argv[@]}" || rc=1
fi

echo ""
if [ "$rc" != "0" ]; then
  echo "doctor: install.sh reported errors -- see output above." >&2
  exit "$rc"
fi
echo "doctor complete. Run scripts/validate.sh to verify."
