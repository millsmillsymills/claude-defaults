#!/usr/bin/env bash
set -euo pipefail

# Idempotent installer for claude-defaults configuration.
# Detects existing config, merges where possible, and reports actions taken.
#
# Usage:
#   ./scripts/install.sh [--dry-run] [--force] [component...]
#   Components: settings, mcp, claude-md, statusline, commands, hooks, all
#   Default: all

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CLAUDE_DIR="${HOME}/.claude"
DRY_RUN=0
FORCE=0
COMPONENTS=()

usage() {
    echo "Usage: $0 [--dry-run] [--force] [component...]"
    echo ""
    echo "Components:"
    echo "  settings    Install ~/.claude/settings.json"
    echo "  mcp         Install ~/.mcp.json (substitutes EXA_API_KEY if set)"
    echo "  claude-md   Install ~/.claude/CLAUDE.md"
    echo "  statusline  Install ~/.claude/statusline.sh"
    echo "  commands    Install slash commands to ~/.claude/commands/"
    echo "  hooks       Install hook scripts to ~/.claude/hooks/"
    echo "  all         Install everything (default)"
    echo ""
    echo "Options:"
    echo "  --dry-run   Show what would be installed without making changes"
    echo "  --force     Overwrite existing files without prompting"
    exit 0
}

log() { echo "  $1"; }
ok()  { echo "  OK: $1"; }
skip() { echo "  SKIP: $1 (already exists, use --force to overwrite)"; }
dry() { echo "  DRY-RUN: would install $1"; }

copy_file() {
    local src="$1" dst="$2" desc="$3"
    if [ "$DRY_RUN" = "1" ]; then
        dry "$desc -> $dst"
        return
    fi
    if [ -f "$dst" ] && [ "$FORCE" != "1" ]; then
        skip "$dst"
        return
    fi
    mkdir -p "$(dirname "$dst")"
    cp "$src" "$dst"
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
    if [ -f "$target" ] && [ "$FORCE" != "1" ]; then
        if command -v jq >/dev/null 2>&1; then
            # Merge: concatenate deny arrays, merge objects
            jq -s '
                .[0] as $existing | .[1] as $new |
                $existing * $new |
                .permissions.deny = (
                    ($existing.permissions.deny // []) +
                    ($new.permissions.deny // []) | unique
                ) |
                .hooks = ($existing.hooks // {}) * ($new.hooks // {})
            ' "$target" "${REPO_DIR}/settings.json" > "${target}.tmp"
            mv "${target}.tmp" "$target"
            ok "merged settings into $target"
        else
            skip "$target (install jq for merge support)"
        fi
    else
        cp "${REPO_DIR}/settings.json" "$target"
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
        skip "$target"
        return
    fi

    if [ -n "${EXA_API_KEY:-}" ]; then
        jq --arg key "$EXA_API_KEY" \
            '.mcpServers.exa.env.EXA_API_KEY = $key' \
            "${REPO_DIR}/mcp-template.json" > "$target"
        ok "mcp config -> $target (EXA_API_KEY substituted)"
    else
        jq 'del(.mcpServers.exa)' \
            "${REPO_DIR}/mcp-template.json" > "$target"
        ok "mcp config -> $target (exa removed -- set EXA_API_KEY to include it)"
    fi
}

install_claude_md() {
    log "--- claude-md ---"
    copy_file "${REPO_DIR}/claude-md-template.md" "${CLAUDE_DIR}/CLAUDE.md" "CLAUDE.md template"
}

install_statusline() {
    log "--- statusline ---"
    copy_file "${REPO_DIR}/scripts/statusline.sh" "${CLAUDE_DIR}/statusline.sh" "statusline"
    if [ "$DRY_RUN" != "1" ] && [ -f "${CLAUDE_DIR}/statusline.sh" ]; then
        chmod +x "${CLAUDE_DIR}/statusline.sh"
    fi
}

install_commands() {
    log "--- commands ---"
    mkdir -p "${CLAUDE_DIR}/commands"
    for cmd in "${REPO_DIR}"/commands/*.md; do
        local name
        name=$(basename "$cmd")
        copy_file "$cmd" "${CLAUDE_DIR}/commands/${name}" "command: ${name}"
    done
}

install_hooks() {
    log "--- hooks ---"
    mkdir -p "${CLAUDE_DIR}/hooks"
    for hook in "${REPO_DIR}"/hooks/*.sh; do
        local name
        name=$(basename "$hook")
        copy_file "$hook" "${CLAUDE_DIR}/hooks/${name}" "hook: ${name}"
        if [ "$DRY_RUN" != "1" ] && [ -f "${CLAUDE_DIR}/hooks/${name}" ]; then
            chmod +x "${CLAUDE_DIR}/hooks/${name}"
        fi
    done
}

install_all() {
    install_settings
    install_mcp
    install_claude_md
    install_statusline
    install_commands
    install_hooks
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

# Default to all
if [ ${#COMPONENTS[@]} -eq 0 ]; then
    COMPONENTS=("all")
fi

echo "claude-defaults installer"
echo ""

# Check for jq (required by hooks and statusline)
if ! command -v jq >/dev/null 2>&1; then
    echo "WARNING: jq is not installed. Hooks and statusline require jq."
    echo ""
fi

for component in "${COMPONENTS[@]}"; do
    case "$component" in
        settings)   install_settings ;;
        mcp)        install_mcp ;;
        claude-md)  install_claude_md ;;
        statusline) install_statusline ;;
        commands)   install_commands ;;
        hooks)      install_hooks ;;
        all)        install_all ;;
        *)          echo "Unknown component: $component"; usage ;;
    esac
done

echo ""
echo "Done. Run 'scripts/validate.sh' to verify installation."
