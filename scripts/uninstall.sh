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
