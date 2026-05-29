#!/usr/bin/env bash
set -euo pipefail

# Hybrid installer: symlinks for content, jq-merge for settings.json.
#
# Usage:
#   ./scripts/install.sh [--dry-run] [--force] [component...]
#   Components: settings, mcp, claude-md, statusline, commands, hooks, agents,
#               skills, logs-dir, all
#   Default: all
#
# - settings.json: jq-merged into ~/.claude/settings.json (preserves
#   enabledPlugins, machine-specific entries). Original backed up first.
# - CLAUDE.md, hooks/*, hooks/lib/*, commands/*, agents/*, statusline.sh:
#   per-file symlinks pointing into the repo.
# - skills/<each>/: per-skill directory symlinks; existing non-symlink dirs
#   in ~/.claude/skills/ are preserved untouched.
# - logs/: real directory, never a symlink.

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CLAUDE_DIR="${HOME}/.claude"
DRY_RUN=0
FORCE=0
COMPONENTS=()
BACKUP_TS="$(date +%Y%m%d-%H%M%S)-$$"
BACKUP_DIR="${CLAUDE_DIR}/backups/pre-claude-defaults-${BACKUP_TS}"
# Records files install created fresh (no prior version) and home-dir backups,
# so uninstall can reverse them. Files under ~/.claude that already existed are
# captured by the backup snapshot; this manifest covers what that can't.
MANIFEST="${CLAUDE_DIR}/.claude-defaults-install.manifest"

usage() {
    echo "Usage: $0 [--dry-run] [--force] [component...]"
    echo ""
    echo "Components:"
    echo "  settings    Install/merge ~/.claude/settings.json"
    echo "  mcp         Install ~/.mcp.json (substitutes EXA_API_KEY if set)"
    echo "  claude-md   Symlink ~/.claude/CLAUDE.md -> repo template"
    echo "  statusline  Symlink ~/.claude/statusline.sh -> repo script"
    echo "  commands    Symlink each commands/*.md"
    echo "  hooks       Symlink each hooks/*.sh and hooks/lib/*"
    echo "  agents      Symlink each agents/*.md"
    echo "  skills      Per-skill directory symlinks (skips pre-existing dirs)"
    echo "  logs-dir    Create ~/.claude/logs/ (real dir)"
    echo "  all         Install everything (default)"
    echo ""
    echo "Options:"
    echo "  --dry-run   Show what would be done without making changes"
    echo "  --force     Overwrite existing entries even if they're foreign symlinks"
    exit 0
}

log()  { echo "  $1"; }
ok()   { echo "  OK: $1"; }
skip() { echo "  SKIP: $1"; }
warn() { echo "  WARN: $1" >&2; }
dry()  { echo "  DRY-RUN: $1"; }

ensure_backup_dir() {
    [ -d "$BACKUP_DIR" ] && return 0
    if [ "$DRY_RUN" = "1" ]; then return 0; fi
    mkdir -p "$BACKUP_DIR"
}

manifest_add() {
    [ "$DRY_RUN" = "1" ] && return 0
    mkdir -p "$(dirname "$MANIFEST")"
    echo "$1" >> "$MANIFEST"
}

# Print the sha256 hex digest of a file, empty if no checksum tool is available.
# Recorded in the manifest for `created` entries so uninstall can detect
# post-install edits and refuse to delete a file the user has changed.
file_sha256() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" 2>/dev/null | awk '{print $1}'
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" 2>/dev/null | awk '{print $1}'
    fi
}

# Resolve a symlink to the real file it points at (absolute path), handling both
# absolute and relative link targets. Empty output if it can't be resolved.
resolve_link() {
    if command -v python3 >/dev/null 2>&1; then
        python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$1" 2>/dev/null
    else
        readlink "$1" 2>/dev/null
    fi
}

backup_existing() {
    local path="$1"
    [ -e "$path" ] || [ -L "$path" ] || return 0
    if [ "$DRY_RUN" = "1" ]; then
        dry "backup $path -> $BACKUP_DIR/"
        return 0
    fi
    ensure_backup_dir
    local rel="${path#"${CLAUDE_DIR}"/}"
    local target="${BACKUP_DIR}/${rel}"
    mkdir -p "$(dirname "$target")"
    mv "$path" "$target"
    log "backed up: $path -> $target"
}

install_symlink() {
    local src="$1" dst="$2" desc="$3"
    if [ "$DRY_RUN" = "1" ]; then
        dry "symlink $desc -> $dst -> $src"
        return 0
    fi
    if [ -L "$dst" ]; then
        local current
        current=$(readlink "$dst")
        if [ "$current" = "$src" ]; then
            ok "$dst (already symlinked)"
            return 0
        fi
        if [ "$FORCE" != "1" ]; then
            backup_existing "$dst"
        else
            rm -f "$dst"
        fi
    elif [ -e "$dst" ]; then
        backup_existing "$dst"
    fi
    mkdir -p "$(dirname "$dst")"
    ln -s "$src" "$dst"
    ok "$desc -> $dst"
}

install_settings() {
    log "--- settings ---"
    local target="${CLAUDE_DIR}/settings.json"

    if [ "$DRY_RUN" = "1" ]; then
        if [ -f "$target" ]; then
            dry "merge settings into $target"
        else
            dry "install settings to $target"
        fi
        return
    fi

    mkdir -p "$CLAUDE_DIR"
    # Idempotency: if the existing settings.json already wires our hooks under
    # the canonical hook events, treat as already-installed (no re-backup, no
    # re-merge). --force bypasses this check to support re-merging after
    # settings.json template changes.
    #
    # Issue #15 (polish): narrow scope from the broad `.. | objects | .command?`
    # walk to specific hook-event paths. The previous walk could false-positive
    # on any nested object with a `.command` field referencing a hook script
    # name (e.g. inside a comment field, or in an unrelated config section).
    if [ "$FORCE" != "1" ] && [ -f "$target" ] && command -v jq >/dev/null 2>&1; then
        if jq -r '
            (.hooks.PreToolUse // [])[]?.hooks[]?.command,
            (.hooks.PostToolUse // [])[]?.hooks[]?.command,
            (.hooks.SessionEnd // [])[]?.hooks[]?.command
            | select(. != null)
        ' "$target" 2>/dev/null \
            | grep -qE 'safety-block\.sh|safety-warn\.sh|log-tool-calls\.sh|log-rotate\.sh'; then
            ok "$target (already merged with claude-defaults hooks — skipping)"
            return
        fi
    fi
    # Snapshot whatever is at the target (regular file or symlink) into the
    # backup, then merge its content with the template. A symlink is resolved
    # to its real file first -- moving the link instead would break a relative
    # target and silently drop the user's settings.
    local existing=""
    if [ -L "$target" ]; then
        ensure_backup_dir
        local resolved
        resolved=$(resolve_link "$target")
        if [ -n "$resolved" ] && [ -f "$resolved" ]; then
            cp -p "$resolved" "${BACKUP_DIR}/$(basename "$target")"
            existing="${BACKUP_DIR}/$(basename "$target")"
            log "backed up (resolved symlink): $target -> ${BACKUP_DIR}/$(basename "$target")"
            # Record that the original was a symlink so uninstall can warn that
            # it restored content as a plain file rather than recreating the link.
            manifest_add "wassymlink ${target} ${resolved}"
        fi
        rm -f "$target"
    elif [ -f "$target" ]; then
        backup_existing "$target"
        existing="${BACKUP_DIR}/$(basename "$target")"
    fi

    if [ -n "$existing" ] && command -v jq >/dev/null 2>&1; then
        jq -s '
            .[0] as $existing | .[1] as $new |
            $existing * $new |
            .permissions.deny = (
                ($existing.permissions.deny // []) +
                ($new.permissions.deny // []) | unique
            ) |
            .permissions.allow = (
                ($existing.permissions.allow // []) +
                ($new.permissions.allow // []) | unique
            ) |
            .hooks = (
                ($existing.hooks // {}) as $eh |
                ($new.hooks // {}) as $nh |
                reduce ((($eh | keys) + ($nh | keys)) | unique[]) as $event ({};
                    .[$event] = (($eh[$event] // []) + ($nh[$event] // []) | unique)
                )
            )
        ' "$existing" "${REPO_DIR}/settings.json" > "${target}.tmp"
        # Validate before atomic rename
        jq . < "${target}.tmp" >/dev/null
        mv "${target}.tmp" "$target"
        ok "merged settings into $target"
    elif [ -n "$existing" ]; then
        warn "jq not installed; cannot merge. Install jq first."
        cp "${REPO_DIR}/settings.json" "$target"
        ok "settings copied (no merge): $target"
    else
        cp "${REPO_DIR}/settings.json" "$target"
        manifest_add "created ${target} $(file_sha256 "$target")"
        ok "settings -> $target"
    fi
}

install_mcp() {
    log "--- mcp ---"
    local target="${HOME}/.mcp.json"

    if [ "$DRY_RUN" = "1" ]; then
        dry "mcp config to $target"
        return
    fi

    if [ -f "$target" ] && [ "$FORCE" != "1" ]; then
        skip "$target (already exists; --force to overwrite)"
        return
    fi

    # We only reach here with the target absent or --force set. Back up an
    # existing file before overwriting (it lives in $HOME, outside the
    # ~/.claude backup snapshot, so record the backup path in the manifest);
    # if it's a fresh creation, record that so uninstall can remove it.
    local fresh=0
    if [ -f "$target" ]; then
        ensure_backup_dir
        cp -p "$target" "${BACKUP_DIR}/mcp.json"
        log "backed up: $target -> ${BACKUP_DIR}/mcp.json"
        manifest_add "mcpbackup ${BACKUP_DIR}/mcp.json"
    else
        fresh=1
    fi

    if [ -n "${EXA_API_KEY:-}" ]; then
        jq --arg key "$EXA_API_KEY" \
            '.mcpServers.exa.env.EXA_API_KEY = $key' \
            "${REPO_DIR}/mcp-template.json" > "$target"
        ok "mcp config -> $target (EXA_API_KEY substituted)"
    else
        jq 'del(.mcpServers.exa)' \
            "${REPO_DIR}/mcp-template.json" > "$target"
        ok "mcp config -> $target (exa removed -- set EXA_API_KEY to include)"
    fi

    # Record the checksum after writing so uninstall can detect post-install
    # edits and refuse to delete a file the user has since changed.
    if [ "$fresh" = "1" ]; then
        manifest_add "created ${target} $(file_sha256 "$target")"
    fi
}

install_claude_md() {
    log "--- claude-md ---"
    install_symlink "${REPO_DIR}/claude-md-template.md" "${CLAUDE_DIR}/CLAUDE.md" "CLAUDE.md template"
}

install_statusline() {
    log "--- statusline ---"
    chmod +x "${REPO_DIR}/scripts/statusline.sh" 2>/dev/null || true
    install_symlink "${REPO_DIR}/scripts/statusline.sh" "${CLAUDE_DIR}/statusline.sh" "statusline"
}

install_commands() {
    log "--- commands ---"
    mkdir -p "${CLAUDE_DIR}/commands"
    for cmd in "${REPO_DIR}"/commands/*.md; do
        [ -f "$cmd" ] || continue
        local name; name=$(basename "$cmd")
        install_symlink "$cmd" "${CLAUDE_DIR}/commands/${name}" "command: ${name}"
    done
}

install_hooks() {
    log "--- hooks ---"
    mkdir -p "${CLAUDE_DIR}/hooks/lib"
    chmod +x "${REPO_DIR}"/hooks/*.sh 2>/dev/null || true
    chmod +x "${REPO_DIR}"/hooks/lib/*.py 2>/dev/null || true
    for hook in "${REPO_DIR}"/hooks/*.sh; do
        [ -f "$hook" ] || continue
        local name; name=$(basename "$hook")
        install_symlink "$hook" "${CLAUDE_DIR}/hooks/${name}" "hook: ${name}"
    done
    for libfile in "${REPO_DIR}"/hooks/lib/*; do
        [ -f "$libfile" ] || continue
        local name; name=$(basename "$libfile")
        install_symlink "$libfile" "${CLAUDE_DIR}/hooks/lib/${name}" "lib: ${name}"
    done
}

install_agents() {
    log "--- agents ---"
    mkdir -p "${CLAUDE_DIR}/agents"
    local found=0
    for a in "${REPO_DIR}"/agents/*.md; do
        [ -f "$a" ] || continue
        found=1
        local name; name=$(basename "$a")
        install_symlink "$a" "${CLAUDE_DIR}/agents/${name}" "agent: ${name}"
    done
    [ "$found" = "0" ] && log "  (no agents in repo yet — empty scaffold)"
}

install_skills() {
    log "--- skills ---"
    mkdir -p "${CLAUDE_DIR}/skills"
    local found=0
    for skill_dir in "${REPO_DIR}"/skills/*/; do
        [ -d "$skill_dir" ] || continue
        found=1
        local name; name=$(basename "$skill_dir")
        local dst="${CLAUDE_DIR}/skills/${name}"
        if [ -e "$dst" ] && [ ! -L "$dst" ]; then
            warn "skill exists as non-symlink dir: $dst — skipping (move/remove manually to bring under symlink management)"
            continue
        fi
        install_symlink "${skill_dir%/}" "$dst" "skill: ${name}"
    done
    [ "$found" = "0" ] && log "  (no skills in repo yet — empty scaffold)"
}

install_logs_dir() {
    log "--- logs-dir ---"
    if [ "$DRY_RUN" = "1" ]; then
        dry "create real dir ${CLAUDE_DIR}/logs/"
        return
    fi
    mkdir -p "${CLAUDE_DIR}/logs"
    ok "logs directory: ${CLAUDE_DIR}/logs"
}

install_all() {
    install_settings
    install_mcp
    install_claude_md
    install_statusline
    install_commands
    install_hooks
    install_agents
    install_skills
    install_logs_dir
}

# Parse arguments
while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run) DRY_RUN=1; shift ;;
        --force)   FORCE=1; shift ;;
        --help|-h) usage ;;
        *)         COMPONENTS+=("$1"); shift ;;
    esac
done

if [ ${#COMPONENTS[@]} -eq 0 ]; then
    COMPONENTS=("all")
fi

echo "claude-defaults installer"
echo "  repo: $REPO_DIR"
echo "  target: $CLAUDE_DIR"
[ "$DRY_RUN" = "1" ] && echo "  mode: DRY RUN"
[ "$FORCE" = "1" ] && echo "  mode: FORCE"
echo ""

if ! command -v jq >/dev/null 2>&1; then
    warn "jq is not installed. Hooks and statusline require jq."
fi
if ! command -v python3 >/dev/null 2>&1; then
    warn "python3 is not installed. Logging hooks require python3."
fi

for component in "${COMPONENTS[@]}"; do
    case "$component" in
        settings)   install_settings ;;
        mcp)        install_mcp ;;
        claude-md)  install_claude_md ;;
        statusline) install_statusline ;;
        commands)   install_commands ;;
        hooks)      install_hooks ;;
        agents)     install_agents ;;
        skills)     install_skills ;;
        logs-dir)   install_logs_dir ;;
        all)        install_all ;;
        *)          echo "Unknown component: $component"; usage ;;
    esac
done

echo ""
echo "Done. Run 'scripts/validate.sh' to verify installation."
if [ -d "$BACKUP_DIR" ]; then echo "Backup created: $BACKUP_DIR"; fi
