#!/usr/bin/env bash
# PreToolUse hook (matcher: Agent|Task, exit 0): force file-mutating subagents
# into their own git worktree so parallel sessions never share the main
# checkout. Emits JSON `updatedInput` that sets `isolation:"worktree"` on the
# subagent dispatch; the harness re-runs the tool with the modified input.
#
# Scope decisions (see the AskUserQuestion answers that created this hook):
#   - Only file-mutating agents are isolated. Clearly read-only agent types are
#     skipped (a throwaway worktree for a search-only agent is pure overhead).
#     Misclassifying a read-only agent as mutating only wastes a worktree that
#     auto-removes when unchanged; misclassifying a mutating agent as read-only
#     would let it edit the main checkout -- so the skip-list stays tight and
#     everything unknown (including the default agent) is isolated.
#   - An explicit isolation already on the call (worktree or remote) is left
#     untouched -- the caller opted in deliberately.
#
# Never blocks (exit 0). If jq is missing or the payload is unparseable the hook
# emits nothing and the dispatch proceeds unchanged.
set -uo pipefail

command -v jq >/dev/null 2>&1 || exit 0

input=$(cat)

# Read-only agent types to leave in the main checkout. Namespace prefixes
# ("pr-review-toolkit:code-reviewer") are stripped and matching is
# case-insensitive before this list is consulted.
readonly_agents='["explore","plan","claude-code-guide","red-team-reviewer","statusline-setup"]'

printf '%s' "$input" | jq -c --argjson ro "$readonly_agents" '
  (.tool_input // {}) as $in
  | ($in.subagent_type // "" | ascii_downcase | sub(".*:"; "")) as $sub
  | if (($in.isolation // "") != "") then empty
    elif ($sub | IN($ro[])) then empty
    else {hookSpecificOutput: {hookEventName: "PreToolUse",
                               updatedInput: ($in + {isolation: "worktree"})}}
    end
' 2>/dev/null || true

exit 0
