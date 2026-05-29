#!/usr/bin/env bash
set -euo pipefail

# PreToolUse hook: blocks rm -rf commands, suggests trash instead.
# Wire up in settings.json PreToolUse -> Bash matcher.
#
# Exit codes:
#   0 = allow
#   2 = block (error message fed back to Claude)

CMD=$(jq -r '.tool_input.command')

# Strip quoted strings before pattern matching so e.g. echo "rm -rf foo"
# (the literal pattern inside a quoted argument) doesn't trigger the block.
# Approximation, not a real shell parser: handles most common cases.
SCRUBBED=$(printf '%s' "$CMD" | sed -E 's/"[^"]*"//g' | sed -E "s/'[^']*'//g")

# True when a single command segment is an `rm` invocation carrying BOTH
# recursive and force flags, in any arrangement (-rf, -fr, -r -f, -Rf,
# --recursive --force). Flags are read only from this segment, so a recursive
# flag on an unrelated command (cp -r src dst && rm -f tmp) cannot combine with
# a separate rm's force flag to trigger a false block.
segment_is_rm_rf() {
  local recursive=0 force=0 cmd_seen=0 tok
  local -a toks
  read -ra toks <<<"$1"
  for tok in "${toks[@]}"; do
    if [ "$cmd_seen" -eq 0 ]; then
      case "$tok" in
      *=* | sudo) continue ;; # skip env assignments and a sudo prefix
      rm) cmd_seen=1 ;;
      *) return 1 ;; # segment is not an rm command
      esac
      continue
    fi
    case "$tok" in
    --recursive) recursive=1 ;;
    --force) force=1 ;;
    -*)
      case "$tok" in *[rR]*) recursive=1 ;; esac
      case "$tok" in *f*) force=1 ;; esac
      ;;
    esac
  done
  [ "$recursive" -eq 1 ] && [ "$force" -eq 1 ]
}

# Split on command separators (&&, ||, ;, |) so each command is judged alone.
# `|| [ -n "$segment" ]` keeps the final separator-less segment, which read
# would otherwise drop on EOF.
while IFS= read -r segment || [ -n "$segment" ]; do
  if segment_is_rm_rf "$segment"; then
    echo 'BLOCKED: Use trash instead of rm -rf' >&2
    exit 2
  fi
done < <(printf '%s' "$SCRUBBED" | sed -E 's/&&|\|\||;|\|/\n/g')
