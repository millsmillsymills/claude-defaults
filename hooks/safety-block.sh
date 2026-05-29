#!/usr/bin/env bash
# PreToolUse hook (matcher: Bash): block catastrophic destructive commands.
# Exit 2 with explanation = block; exit 0 = allow.
#
# Note: existing hooks/block-rm-rf.sh and hooks/block-push-main.sh remain
# wired up alongside this one for back-compat. This script covers patterns
# they don't (dd, mkfs, fork bombs, sudo rm, force-push variants, chmod 777).
#
# Patterns below intentionally contain the literal text "$HOME" and "~" (strings
# a user might type), not shell expansions -- single quotes are correct here.
# shellcheck disable=SC2016,SC2088

set -uo pipefail

CMD=$(jq -r '.tool_input.command // ""' 2>/dev/null || echo "")
[ -n "$CMD" ] || exit 0

# Strip quoted strings before pattern matching (handles the common "echo
# 'dangerous-pattern'" false positive). Approximation, not a real shell parser.
S=$(printf '%s' "$CMD" | sed -E 's/"[^"]*"//g' | sed -E "s/'[^']*'//g")

block() {
    echo "BLOCKED: $1" >&2
    exit 2
}

# rm -rf against root or home. The recursive flag, force flag, and root/home
# target must all belong to the SAME rm invocation (any flag arrangement: -rf,
# -fr, -r -f, -Rf, --recursive --force), so flags/targets from an unrelated
# command on the same line (cp -r /Users/x dst && rm -f junk) can't combine
# into a false block.
segment_is_rm_rf_protected() {
    local recursive=0 force=0 protected=0 cmd_seen=0 tok
    local -a toks
    read -ra toks <<<"$1"
    for tok in "${toks[@]}"; do
        if [ "$cmd_seen" -eq 0 ]; then
            case "$tok" in
            *=* | sudo) continue ;;
            rm) cmd_seen=1 ;;
            *) return 1 ;;
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
        / | /Users | /Users/* | '~' | '~/'* | '$HOME' | '$HOME/'*) protected=1 ;;
        esac
    done
    [ "$recursive" -eq 1 ] && [ "$force" -eq 1 ] && [ "$protected" -eq 1 ]
}
while IFS= read -r segment || [ -n "$segment" ]; do
    if segment_is_rm_rf_protected "$segment"; then
        block "rm -rf against root, /Users, ~, or \$HOME. Use 'trash' or a specific path."
    fi
done < <(printf '%s' "$S" | sed -E 's/&&|\|\||;|\|/\n/g')

# sudo rm -rf anything
if echo "$S" | grep -qE '(^|[[:space:]])sudo[[:space:]]+rm[[:space:]]+-[a-zA-Z]*r[a-zA-Z]*f'; then
    block "sudo rm -rf is too dangerous. Run targeted deletes manually if truly needed."
fi

# dd writing to a disk device
if echo "$S" | grep -qE '(^|[[:space:]])dd[[:space:]].*of=/dev/(disk|sd|nvme|rdisk)'; then
    block "dd writing to /dev/disk*, /dev/sd*, /dev/nvme*, or /dev/rdisk* destroys the disk. Refusing."
fi

# Filesystem creation / wipe
if echo "$S" | grep -qE '(^|[[:space:]])(mkfs(\.|[[:space:]])|wipefs[[:space:]])'; then
    block "mkfs/wipefs against any device wipes data. Refusing."
fi

# fdisk/parted with write subcommands (rough)
if echo "$S" | grep -qE '(^|[[:space:]])(fdisk[[:space:]]+(-w|/dev/)|parted[[:space:]]+/dev/.*[[:space:]](mklabel|mkpart|rm|resizepart))'; then
    block "fdisk/parted write operation. Refusing."
fi

# Fork bomb
if echo "$S" | grep -qE ':\(\)\{[[:space:]]*:[[:space:]]*\|[[:space:]]*:[[:space:]]*&[[:space:]]*\}'; then
    block "fork bomb pattern detected."
fi

# chmod -R 777 against / or ~
if echo "$S" | grep -qE '(^|[[:space:]])chmod[[:space:]]+(-[a-zA-Z]*R|-R[a-zA-Z]*)[[:space:]]+777[[:space:]]+(/$|/[[:space:]]|~([[:space:]/]|$)|\$HOME)'; then
    block "chmod -R 777 against / or ~ is destructive (loses original perms). Refusing."
fi

# Force-push variants to protected branches
if echo "$S" | grep -qE '(^|[[:space:]])git[[:space:]]+push[[:space:]]+(--force(-with-lease)?|-f)[[:space:]]+[A-Za-z0-9_./-]+[[:space:]]+(main|master|production|prod)([[:space:]]|$)'; then
    block "force-push to main/master/production. Use a feature branch and PR."
fi

if echo "$S" | grep -qE '(^|[[:space:]])git[[:space:]]+push[[:space:]]+[A-Za-z0-9_./-]+[[:space:]]+(--force(-with-lease)?|-f)'; then
    block "git push --force/--force-with-lease/-f detected. Use feature branches."
fi

exit 0
