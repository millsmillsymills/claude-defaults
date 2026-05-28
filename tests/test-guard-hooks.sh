#!/usr/bin/env bash
# Guard hooks must block the dangerous command and its trivial variants
# (flag reordering/splitting, refspecs, env-var prefixes) without blocking
# legitimate commands.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
REPO="$PWD"

fail=0
fail_msg() { echo "FAIL: $1" >&2; fail=$((fail + 1)); }

# Run a hook with a synthesized Bash tool-call; echo its exit code.
hook_rc() {
  local hook="$1" cmd="$2"
  jq -nc --arg c "$cmd" '{tool_name:"Bash", tool_input:{command:$c}}' \
    | bash "$hook" >/dev/null 2>&1
  echo $?
}

expect_block() { # hook cmd label
  [ "$(hook_rc "$1" "$2")" = "2" ] || fail_msg "$3: '$2' was allowed (expected block)"
}
expect_allow() { # hook cmd label
  [ "$(hook_rc "$1" "$2")" = "0" ] || fail_msg "$3: '$2' was blocked (expected allow)"
}

# === H2: block-rm-rf.sh -- recursive+force in any flag arrangement ===
RMRF="hooks/block-rm-rf.sh"
expect_block "$RMRF" 'rm -rf /tmp/foo'              "rm-rf combined"
expect_block "$RMRF" 'rm -fr /tmp/foo'              "rm-rf reversed flags"
expect_block "$RMRF" 'rm -r -f /tmp/foo'            "rm-rf split flags"
expect_block "$RMRF" 'rm --recursive --force /tmp/foo' "rm-rf long options"
expect_block "$RMRF" 'rm -Rf /tmp/foo'              "rm-rf capital R"
expect_allow "$RMRF" 'ls -la'                       "rm-rf benign ls"
expect_allow "$RMRF" 'rm file.txt'                  "rm-rf no flags"
expect_allow "$RMRF" 'rm -f file.txt'               "rm-rf force only"
expect_allow "$RMRF" 'echo "rm -rf /tmp"'           "rm-rf quoted literal"

# === H1: block-push-main.sh -- remotes with digits/dots and refspec forms ===
PUSH="hooks/block-push-main.sh"
expect_block "$PUSH" 'git push origin main'         "push plain"
expect_block "$PUSH" 'git push origin master'       "push master"
expect_block "$PUSH" 'git push origin2 main'        "push numbered remote"
expect_block "$PUSH" 'git push origin HEAD:main'    "push HEAD refspec"
expect_block "$PUSH" 'git push origin main:main'    "push main:main"
expect_block "$PUSH" 'git push origin feature:main' "push feature into main"
expect_allow "$PUSH" 'git push origin feature'      "push feature branch"
expect_allow "$PUSH" 'git push origin main:feature' "push main into feature"
expect_allow "$PUSH" 'git status'                   "push benign status"

# === H2: safety-block.sh -- split-flag rm -rf against root/home ===
SAFETY="hooks/safety-block.sh"
expect_block "$SAFETY" 'rm -rf /Users/somebody'    "safety combined root"
expect_block "$SAFETY" 'rm -r -f /Users/somebody'  "safety split-flag root"
expect_block "$SAFETY" 'rm --recursive --force ~'  "safety long-option home"
expect_allow "$SAFETY" 'rm -rf /tmp/scratch'       "safety non-root path"
expect_allow "$SAFETY" 'echo "rm -rf /"'           "safety quoted literal"

# === L1 + H10: enforce-package-manager.sh -- npm not at line start ===
# The hook keys off a lockfile in CWD, so run each case from a temp pnpm project.
ENFORCE="$REPO/hooks/enforce-package-manager.sh"
enforce_rc() { # cmd  (run inside a pnpm-locked dir)
  local cmd="$1"
  jq -nc --arg c "$cmd" '{tool_name:"Bash", tool_input:{command:$c}}' \
    | (cd "$PNPM_DIR" && bash "$ENFORCE") >/dev/null 2>&1
  echo $?
}
PNPM_DIR=$(mktemp -d)
: >"$PNPM_DIR/pnpm-lock.yaml"
[ "$(enforce_rc 'npm install')" = "2" ]            || fail_msg "enforce: plain npm install allowed"
[ "$(enforce_rc 'NODE_ENV=prod npm install')" = "2" ] || fail_msg "enforce: env-prefixed npm allowed"
[ "$(enforce_rc '   npm install')" = "2" ]         || fail_msg "enforce: leading-space npm allowed"
[ "$(enforce_rc 'cd app && npm ci')" = "2" ]       || fail_msg "enforce: chained npm allowed"
[ "$(enforce_rc 'pnpm add lodash')" = "0" ]        || fail_msg "enforce: pnpm blocked"
[ "$(enforce_rc 'echo run npm install first')" = "0" ] || fail_msg "enforce: npm in prose blocked"
rm -rf "$PNPM_DIR"

# No lockfile -> npm is allowed.
CLEAN_DIR=$(mktemp -d)
clean_rc=$(jq -nc '{tool_name:"Bash", tool_input:{command:"npm install"}}' \
  | (cd "$CLEAN_DIR" && bash "$ENFORCE") >/dev/null 2>&1; echo $?)
[ "$clean_rc" = "0" ] || fail_msg "enforce: npm blocked with no lockfile"
rm -rf "$CLEAN_DIR"

if [ "$fail" -eq 0 ]; then
  echo "test-guard-hooks: PASS"
else
  echo "test-guard-hooks: $fail FAILURE(S)"
  exit 1
fi
