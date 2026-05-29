#!/usr/bin/env bash
# PreToolUse hook (matcher: Edit|Write): warn (no block) on sensitive paths.
# Exit 0 always; stderr is shown to Claude as a nudge.
#
# Hard reads/writes to many of these paths are already blocked by the deny
# rules in settings.json. This hook adds visibility for paths that slip past
# (custom locations, project-specific .env files, etc.).

set -uo pipefail

FP=$(jq -r '.tool_input.file_path // ""' 2>/dev/null || echo "")
[ -n "$FP" ] || exit 0

if echo "$FP" | grep -qE '(\.env(\.[^/]+)?$|/credentials([._-][^/]+)?(\.[a-z]+)?$|secrets?\.(json|ya?ml)$|\.pem$|\.key$|id_rsa(\.|$)|\.p12$|\.pfx$|\.gpg$)'; then
  cat >&2 <<'WARN'
WARNING: editing a sensitive-looking file. Verify it's in .gitignore.
Never hardcode secrets — use env vars or a secrets manager. Run `git status`
after editing to confirm the file won't be committed.
WARN
fi

exit 0
