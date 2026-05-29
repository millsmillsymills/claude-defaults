# shellcheck shell=bash
# Shared canonical hook-event list, sourced by install.sh and validate.sh.
# Single source of truth so the two scripts can't drift on which hook events
# they inspect. Derived from the repo's settings.json (.hooks keys) so adding
# a new event there is picked up automatically; falls back to a static list if
# jq is unavailable.
#
# Sets the array HOOK_EVENTS. Requires REPO_DIR to be set by the caller.

hook_events_load() {
    local settings="${REPO_DIR}/settings.json"
    if command -v jq >/dev/null 2>&1 && [ -f "$settings" ]; then
        local keys
        keys=$(jq -r '.hooks | keys[]' "$settings" 2>/dev/null)
        if [ -n "$keys" ]; then
            HOOK_EVENTS=()
            while IFS= read -r event; do
                [ -n "$event" ] && HOOK_EVENTS+=("$event")
            done <<<"$keys"
            return 0
        fi
    fi
    HOOK_EVENTS=(PreToolUse PostToolUse Stop SessionEnd UserPromptSubmit)
}
