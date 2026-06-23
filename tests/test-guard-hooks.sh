#!/usr/bin/env bash
# Guard hooks must block the dangerous command and its trivial variants
# (flag reordering/splitting, refspecs, env-var prefixes) without blocking
# legitimate commands.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

fail=0
fail_msg() {
  echo "FAIL: $1" >&2
  fail=$((fail + 1))
}

# Run a hook with a synthesized Bash tool-call; echo its exit code. A .py hook
# runs via its shebang (it is executable); .sh hooks run under bash.
hook_rc() {
  local hook="$1" cmd="$2"
  local runner=(bash "$hook")
  [ "${hook##*.}" = "py" ] && runner=("$hook")
  jq -nc --arg c "$cmd" '{tool_name:"Bash", tool_input:{command:$c}}' |
    "${runner[@]}" >/dev/null 2>&1
  echo $?
}

expect_block() { # hook cmd label
  [ "$(hook_rc "$1" "$2")" = "2" ] || fail_msg "$3: '$2' was allowed (expected block)"
}
expect_allow() { # hook cmd label
  [ "$(hook_rc "$1" "$2")" = "0" ] || fail_msg "$3: '$2' was blocked (expected allow)"
}

# === H2: block-rm-rf.py -- recursive+force in any flag arrangement ===
RMRF="hooks/block-rm-rf.py"
expect_block "$RMRF" 'rm -rf /tmp/foo' "rm-rf combined"
expect_block "$RMRF" 'rm -fr /tmp/foo' "rm-rf reversed flags"
expect_block "$RMRF" 'rm -r -f /tmp/foo' "rm-rf split flags"
expect_block "$RMRF" 'rm --recursive --force /tmp/foo' "rm-rf long options"
expect_block "$RMRF" 'rm -Rf /tmp/foo' "rm-rf capital R"
expect_allow "$RMRF" 'ls -la' "rm-rf benign ls"
expect_allow "$RMRF" 'rm file.txt' "rm-rf no flags"
expect_allow "$RMRF" 'rm -f file.txt' "rm-rf force only"
expect_allow "$RMRF" 'echo "rm -rf /tmp"' "rm-rf quoted literal"
# Recursive/force flags from unrelated commands must not combine (false positive).
expect_allow "$RMRF" 'cp -r src dst && rm -f tmp.txt' "rm-rf cp -r then rm -f"
expect_allow "$RMRF" 'ls -R dir; rm -f junk' "rm-rf ls -R then rm -f"
expect_allow "$RMRF" 'grep -r foo . && rm -f out' "rm-rf grep -r then rm -f"
expect_allow "$RMRF" 'rsync -r a b && rm -f c' "rm-rf rsync -r then rm -f"
expect_block "$RMRF" 'cp -r a b && rm -rf /tmp/x' "rm-rf real rm-rf after cp -r"
# Wrapper bypass: a payload inside bash -c must not slip past the guard.
expect_block "$RMRF" "bash -c 'rm -rf ./build'" "rm-rf wrapped in bash -c"
expect_block "$RMRF" "true;rm -rf ./build" "rm-rf after unspaced separator"
# Newline as the sole separator: shlex used to swallow it, hiding line 2 onward.
expect_block "$RMRF" $'echo hi\nrm -rf ./build' "rm-rf after newline"
expect_block "$RMRF" $'echo a\n\nrm -rf ./build' "rm-rf after blank line"
expect_block "$RMRF" $'echo a|\nrm -rf ./build' "rm-rf after pipe then newline"

# === H1: block-push-main.py -- remotes with digits/dots and refspec forms ===
PUSH="hooks/block-push-main.py"
expect_block "$PUSH" 'git push origin main' "push plain"
expect_block "$PUSH" 'git push origin master' "push master"
expect_block "$PUSH" 'git push origin2 main' "push numbered remote"
expect_block "$PUSH" 'git push origin HEAD:main' "push HEAD refspec"
expect_block "$PUSH" 'git push origin main:main' "push main:main"
expect_block "$PUSH" 'git push origin feature:main' "push feature into main"
# Flags between push and remote, fully-qualified refspecs, and force refspecs.
expect_block "$PUSH" 'git push -u origin main' "push -u set-upstream"
expect_block "$PUSH" 'git push --set-upstream origin main' "push --set-upstream"
expect_block "$PUSH" 'git push origin refs/heads/main' "push fully-qualified ref"
expect_block "$PUSH" 'git push origin HEAD:refs/heads/main' "push HEAD to qualified ref"
expect_block "$PUSH" 'git push origin +main' "push force refspec +main"
expect_block "$PUSH" 'git -C /repo push origin main' "push with git -C"
expect_block "$PUSH" 'cd x && git push -u origin main' "push -u after &&"
expect_allow "$PUSH" 'git push origin feature' "push feature branch"
expect_allow "$PUSH" 'git push origin main:feature' "push main into feature"
expect_allow "$PUSH" 'git push -u origin feature' "push -u feature branch"
expect_allow "$PUSH" 'git status' "push benign status"
# Wrapper bypass: a push to main inside bash -c must not slip past the guard.
expect_block "$PUSH" "bash -c 'git push origin main'" "push main wrapped in bash -c"
expect_block "$PUSH" $'echo x\ngit push origin main' "push main after newline"
expect_allow "$PUSH" $'echo x\ngit push origin feature' "push feature after newline ok"

# === H2: safety-block.py -- destructive commands, incl. wrapped payloads ===
SAFETY="hooks/safety-block.py"
expect_block "$SAFETY" 'rm -rf /Users/somebody' "safety combined root"
expect_block "$SAFETY" 'rm -r -f /Users/somebody' "safety split-flag root"
expect_block "$SAFETY" 'rm --recursive --force ~' "safety long-option home"
expect_allow "$SAFETY" 'rm -rf /tmp/scratch' "safety non-root path"
expect_allow "$SAFETY" 'echo "rm -rf /"' "safety quoted literal"
# Recursive flag + protected target from unrelated commands must not combine.
expect_allow "$SAFETY" 'cp -r /Users/x dst && rm -f junk' "safety cp -r home then rm -f"
expect_block "$SAFETY" 'cp -r a b && rm -rf /Users/x' "safety real rm-rf home after cp -r"
# Non-rm destructive classes.
expect_block "$SAFETY" 'dd if=/dev/zero of=/dev/disk0' "safety dd to disk"
expect_block "$SAFETY" 'mkfs.ext4 /dev/sda1' "safety mkfs"
expect_block "$SAFETY" 'chmod -R 777 ~' "safety chmod 777 home"
expect_block "$SAFETY" 'git push --force origin main' "safety force-push main"
expect_block "$SAFETY" ':(){ :|:& };:' "safety fork bomb"
expect_block "$SAFETY" 'git push --force' "safety bare force-push (current branch)"
expect_allow "$SAFETY" 'dd if=in.img of=out.img' "safety dd to file"
expect_allow "$SAFETY" 'chmod 644 file.txt' "safety benign chmod"
expect_allow "$SAFETY" 'git push --force-with-lease origin feature' "safety force-push feature ok"
# The #2 bypass class: payloads hidden in bash -c / sh -c / eval must NOT slip past.
expect_block "$SAFETY" "bash -c 'rm -rf /'" "safety bash -c rm-rf"
expect_block "$SAFETY" "sh -c 'mkfs.ext4 /dev/sda'" "safety sh -c mkfs"
expect_block "$SAFETY" "eval 'dd if=/dev/zero of=/dev/disk2'" "safety eval dd"
expect_block "$SAFETY" "bash -c ':(){ :|:& };:'" "safety bash -c fork bomb"
# A quoted pattern that is only echoed (not executed) stays allowed even nested.
expect_allow "$SAFETY" "bash -c 'echo \"rm -rf /\"'" "safety bash -c echo literal"
# #52: combined short-flag wrappers (-lc/-ec/-xc/-ic) must not smuggle a payload.
expect_block "$SAFETY" "bash -lc 'rm -rf /'" "safety bash -lc rm-rf"
expect_block "$SAFETY" "sh -ec 'rm -rf ~'" "safety sh -ec rm-rf"
expect_block "$SAFETY" "bash -xc 'mkfs.ext4 /dev/sda'" "safety bash -xc mkfs"
expect_allow "$SAFETY" "bash -lc 'ls -la'" "safety bash -lc benign"
# Newline-separated destructive payloads must not slip past on line 2 onward.
expect_block "$SAFETY" $'echo hi\nrm -rf /Users/x' "safety rm-rf home after newline"
expect_block "$SAFETY" $'echo hi\nmkfs.ext4 /dev/sda' "safety mkfs after newline"
expect_block "$SAFETY" $'echo hi\ndd if=/dev/zero of=/dev/disk0' "safety dd after newline"
# #52: a `+refspec` is a force update even without -f; block protected targets.
expect_block "$SAFETY" 'git push origin +main' "safety +refspec force main"
expect_block "$SAFETY" 'git push origin +HEAD:master' "safety +refspec force master"
expect_allow "$SAFETY" 'git push origin +myfeature' "safety +refspec feature ok"
# #52: a non-string command must fail open (exit 0), never crash with rc=1.
[ "$(
  jq -nc '{tool_name:"Bash", tool_input:{command:123}}' | "$SAFETY" >/dev/null 2>&1
  echo $?
)" = "0" ] ||
  fail_msg "safety: non-string command did not fail open (expected rc=0)"

if [ "$fail" -eq 0 ]; then
  echo "test-guard-hooks: PASS"
else
  echo "test-guard-hooks: $fail FAILURE(S)"
  exit 1
fi
