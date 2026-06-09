#!/usr/bin/env bash
# PreToolUse hook (matcher: Edit|Write): warn (no block) on sensitive paths.
# Exit 0 always. The advisory is emitted as JSON additionalContext on stdout --
# exit-0 stderr is invisible to Claude (see docs/HOOKS.md), so a stderr warning
# would reach no one.
#
# Hard reads/writes to many of these paths are already blocked by the deny
# rules in settings.json. This hook adds visibility for paths that slip past
# (custom locations, project-specific .env files, etc.).
set -uo pipefail

input=$(cat)
fp=$(printf '%s' "$input" | jq -r '.tool_input.file_path // ""' 2>/dev/null || echo "")
[ -n "$fp" ] || exit 0

if printf '%s' "$fp" | grep -qE '(\.env(\.[^/]+)?$|/credentials([._-][^/]+)?(\.[a-z]+)?$|secrets?\.(json|ya?ml)$|\.pem$|\.key$|id_rsa(\.|$)|\.p12$|\.pfx$|\.gpg$)'; then
  msg="Editing a sensitive-looking file (${fp}). Verify it is in .gitignore; never hardcode secrets (use env vars or a secrets manager); run 'git status' after editing to confirm it will not be committed."
  jq -nc --arg c "$msg" \
    '{hookSpecificOutput:{hookEventName:"PreToolUse",additionalContext:$c}}'
fi

exit 0
