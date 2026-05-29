#!/usr/bin/env bash
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

# 1. settings.json is valid JSON
python3 -m json.tool <settings.json >/dev/null 2>&1 || {
  echo "FAIL: settings.json not valid JSON" >&2
  exit 1
}

# 2. Every hook script referenced in settings.json exists in hooks/
# shellcheck disable=SC2016  # $HOME is a literal in the JSON command strings, not expanded here
referenced=$(jq -r '.. | objects | .command? // empty' settings.json |
  grep -oE '\$HOME/\.claude/hooks/[a-zA-Z0-9_.-]+' |
  sed 's|\$HOME/\.claude/hooks/||' | sort -u)
fail=0
for f in $referenced; do
  if [ ! -f "hooks/$f" ]; then
    echo "FAIL: settings.json references hooks/$f but file is missing" >&2
    fail=$((fail + 1))
  fi
done

# 3. mcp-template.json is valid JSON
python3 -m json.tool <mcp-template.json >/dev/null 2>&1 || {
  echo "FAIL: mcp-template.json not valid JSON" >&2
  exit 1
}

# 4. permissions.deny blocks Edit/Write on every shell init file a login shell sources
deny=$(jq -r '.permissions.deny[]' settings.json)
for f in .bashrc .bash_profile .bash_login .profile .zshrc .zprofile .zshenv; do
  for action in Edit Write; do
    entry="$action(~/$f)"
    if ! grep -qxF "$entry" <<<"$deny"; then
      echo "FAIL: settings.json permissions.deny missing $entry" >&2
      fail=$((fail + 1))
    fi
  done
done

[ "$fail" = "0" ] || exit 1
echo "test-settings-valid: PASS"
