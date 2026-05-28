#!/usr/bin/env bash
# PreToolUse hook (matcher: Bash): block catastrophic destructive commands.
# Exit 2 with explanation = block; exit 0 = allow.
#
# Note: existing hooks/block-rm-rf.sh and hooks/block-push-main.sh remain
# wired up alongside this one for back-compat. This script covers patterns
# they don't (dd, mkfs, fork bombs, sudo rm, force-push variants, chmod 777).
#
# Patterns below intentionally contain the literal text "$HOME" (a string a user
# might type), not a shell expansion -- single quotes are correct here.
# shellcheck disable=SC2016

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

# rm -rf against root or home. Detect rm + recursive + force independently
# (any flag arrangement: -rf, -fr, -r -f, -Rf, --recursive --force) and a
# root/home target anywhere in the command, so split flags don't bypass it.
if echo "$S" | grep -qE '(^|[[:space:]])rm([[:space:]]|$)' \
    && echo "$S" | grep -qE '(-[a-zA-Z]*[rR]|--recursive)' \
    && echo "$S" | grep -qE '(-[a-zA-Z]*f|--force)' \
    && echo "$S" | grep -qE '(^|[[:space:]])(/([[:space:]]|$)|/Users([[:space:]/]|$)|~([[:space:]/]|$)|\$HOME)'; then
    block "rm -rf against root, /Users, ~, or \$HOME. Use 'trash' or a specific path."
fi

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
