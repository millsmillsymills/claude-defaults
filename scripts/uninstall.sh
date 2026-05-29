#!/usr/bin/env bash
set -euo pipefail

# Reverse a claude-defaults install: remove symlinks pointing into the repo,
# restore the latest backup snapshot.
#
# Usage: ./scripts/uninstall.sh [--dry-run]

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CLAUDE_DIR="${HOME}/.claude"
MANIFEST="${CLAUDE_DIR}/.claude-defaults-install.manifest"
DRY_RUN=0
[ "${1:-}" = "--dry-run" ] && DRY_RUN=1

# Set when any restore step fails, so a partial restore is reported via a
# non-zero exit instead of a stderr-only warning automation can't detect.
RESTORE_FAILED=0

log() { echo "  $1"; }
ok()  { echo "  OK: $1"; }
warn(){ echo "  WARN: $1" >&2; }
dry() { echo "  DRY-RUN: $1"; }

# Print the sha256 hex digest of a file, empty if no checksum tool is available.
# Used to compare a `created` file's current content against the digest install
# recorded, so post-install edits are preserved instead of deleted.
file_sha256() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" 2>/dev/null | awk '{print $1}'
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" 2>/dev/null | awk '{print $1}'
    fi
}

# Find latest backup (timestamped names sort lexically, newest last)
LATEST_BACKUP=$(find "${CLAUDE_DIR}/backups" -maxdepth 1 -type d -name 'pre-claude-defaults-*' 2>/dev/null | sort | tail -n1 || true)
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
    "${CLAUDE_DIR}"/hooks/*.py \
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
        #
        # Process substitution (not a pipe) keeps the loop body in the current
        # shell so `set -euo pipefail` propagates; a cp failure is observable
        # here instead of being swallowed in a pipe subshell.
        #
        # mcp.json at the snapshot root is the home-dir ~/.mcp.json backup, not
        # a ~/.claude/ file. Restoring it via this loop would land a stray
        # ~/.claude/mcp.json that never existed. The manifest's `mcpbackup`
        # entry restores it to the correct ~/.mcp.json, so skip it here.
        while IFS= read -r -d '' rel; do
            rel="${rel#./}"
            [ "$rel" = "mcp.json" ] && continue
            src="${LATEST_BACKUP}/${rel}"
            dst="${CLAUDE_DIR}/${rel}"
            mkdir -p "$(dirname "$dst")"
            if cp -p "$src" "$dst"; then
                log "restored: $dst"
            else
                warn "failed to restore $dst — partial restore"
                RESTORE_FAILED=1
            fi
        done < <(cd "$LATEST_BACKUP" && find . -type f -print0)
    fi
fi

# Reverse fresh creations and home-dir overwrites recorded at install time.
# The backup snapshot above only covers files that lived under ~/.claude and
# already existed; the manifest covers files install created from nothing
# (settings.json, ~/.mcp.json) and ~/.mcp.json overwrites it backed up.
if [ -f "$MANIFEST" ]; then
    while read -r action arg extra; do
        [ -n "${action:-}" ] || continue
        case "$action" in
            created)
                # `extra` is the sha256 install recorded for the file's original
                # content (empty for manifests written before checksums existed).
                # If the file's current content no longer matches, the user has
                # edited it post-install; leave it in place rather than delete.
                if [ -f "$arg" ] && [ ! -L "$arg" ]; then
                    current=""
                    [ -n "$extra" ] && current=$(file_sha256 "$arg")
                    if [ -n "$extra" ] && [ -n "$current" ] && [ "$current" != "$extra" ]; then
                        warn "kept (edited since install): $arg"
                    elif [ "$DRY_RUN" = "1" ]; then
                        dry "remove install-created file $arg"
                    else
                        rm -f "$arg"
                        ok "removed (created by install): $arg"
                    fi
                fi
                ;;
            wassymlink)
                # install resolved a symlinked settings.json and backed up its
                # content; the restore above wrote a plain file where a symlink
                # was. Recreating the link is out of scope — just warn.
                warn "restored $arg as a regular file; it was originally a symlink to ${extra:-?} (link not recreated)"
                ;;
            mcpbackup)
                if [ -f "$arg" ]; then
                    if [ "$DRY_RUN" = "1" ]; then
                        dry "restore $arg -> ${HOME}/.mcp.json"
                    elif cp -p "$arg" "${HOME}/.mcp.json"; then
                        ok "restored: ${HOME}/.mcp.json"
                    else
                        warn "failed to restore ${HOME}/.mcp.json — partial restore"
                        RESTORE_FAILED=1
                    fi
                fi
                ;;
        esac
    done < "$MANIFEST"
    [ "$DRY_RUN" = "1" ] || rm -f "$MANIFEST"
fi

echo ""
if [ "$RESTORE_FAILED" = "1" ]; then
    echo "Done with errors: one or more files could not be restored (see WARN above)." >&2
    exit 1
fi
echo "Done."
