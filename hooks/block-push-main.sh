#!/usr/bin/env bash
set -euo pipefail

# PreToolUse hook: blocks direct push to main/master, requires feature branches.
# Wire up in settings.json PreToolUse -> Bash matcher.
#
# Kept alongside safety-block.py despite the overlap: this blocks ALL pushes to
# main/master, whereas safety-block.py only blocks force-pushes. Dropping it
# would narrow the policy to force-push-only.
#
# Exit codes:
#   0 = allow
#   2 = block (error message fed back to Claude)

CMD=$(jq -r '.tool_input.command')

# Strip quoted strings before pattern matching (see block-rm-rf.sh for rationale).
SCRUBBED=$(printf '%s' "$CMD" | sed -E 's/"[^"]*"//g' | sed -E "s/'[^']*'//g")

# A push argument targets a protected branch when its refspec DESTINATION is
# main/master. Destination = the part after the last ':' (a refspec like
# HEAD:main or feature:main), with a leading '+' (force refspec) and a
# refs/heads/ prefix stripped. `main:feature` (pushing main INTO feature) is
# therefore allowed -- only main/master as the destination is blocked.
is_protected_dest() {
    local dest="${1##*:}"
    dest="${dest#+}"
    dest="${dest#refs/heads/}"
    [ "$dest" = main ] || [ "$dest" = master ]
}

# These git options consume the following token as their value, so the value
# must be skipped when locating the `push` subcommand (git -C <path> push ...).
opt_takes_value() {
    case "$1" in
    -C | -c | --git-dir | --work-tree | --namespace | --exec-path) return 0 ;;
    *) return 1 ;;
    esac
}

read -ra TOKENS <<<"$SCRUBBED"
n=${#TOKENS[@]}
i=0
while [ "$i" -lt "$n" ]; do
    [ "${TOKENS[$i]}" = git ] || {
        i=$((i + 1))
        continue
    }
    # Skip git-level options (and the value of those that take one) to find push.
    j=$((i + 1))
    while [ "$j" -lt "$n" ] && [ "${TOKENS[$j]:0:1}" = - ]; do
        opt_takes_value "${TOKENS[$j]}" && j=$((j + 1))
        j=$((j + 1))
    done
    if [ "$j" -lt "$n" ] && [ "${TOKENS[$j]}" = push ]; then
        # First non-flag arg after push is the remote; later non-flag args are
        # refspecs. Block if any refspec destination is main/master.
        remote_seen=0
        k=$((j + 1))
        while [ "$k" -lt "$n" ]; do
            tok="${TOKENS[$k]}"
            case "$tok" in
            git) break ;; # next command on the line; outer loop rescans
            -*) ;;        # push option, ignore
            *)
                if [ "$remote_seen" -eq 0 ]; then
                    remote_seen=1
                elif is_protected_dest "$tok"; then
                    echo 'BLOCKED: Use feature branches, not direct push to main' >&2
                    exit 2
                fi
                ;;
            esac
            k=$((k + 1))
        done
    fi
    i=$((i + 1))
done
