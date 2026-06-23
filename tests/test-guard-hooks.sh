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
# #126: leading-path normalization -- /./, //, and /.// must not slip a
# protected target past the literal-prefix check.
expect_block "$SAFETY" 'rm -rf /./etc' "safety /./etc normalized"
expect_block "$SAFETY" 'rm -rf //etc' "safety //etc normalized"
expect_block "$SAFETY" 'rm -rf /.//etc' "safety /.//etc normalized"
expect_block "$SAFETY" 'rm -rf /etc/../usr' "safety /etc/../usr normalized"
# #126: globs whose literal prefix can expand to a protected root.
expect_block "$SAFETY" 'rm -rf /Users*' "safety /Users* glob"
expect_block "$SAFETY" 'rm -rf /Us*' "safety /Us* glob"
expect_block "$SAFETY" 'rm -rf /et*' "safety /et* glob"
expect_block "$SAFETY" 'rm -rf ~*' "safety ~* glob"
# #126: a glob that cannot reach a protected root must stay allowed.
expect_allow "$SAFETY" 'rm -rf /usr-mirror*' "safety /usr-mirror* allowed"
expect_allow "$SAFETY" 'rm -rf ./build/*' "safety ./build/* allowed"
expect_allow "$SAFETY" 'rm -rf /tmp/*' "safety /tmp/* allowed"
# #126: ${HOME} brace form alongside the $HOME form. The literal ${HOME} is the
# input under test -- it must reach the hook unexpanded, so single quotes are
# intentional here.
# shellcheck disable=SC2016
expect_block "$SAFETY" 'rm -rf ${HOME}/projects' "safety \${HOME} brace form"
# #126: arg-taking launchers (timeout duration, timeout -k/-s, doas) must not
# hide the wrapped rm.
expect_block "$SAFETY" 'timeout 5 rm -rf /etc' "safety timeout rm-rf"
expect_block "$SAFETY" 'timeout -k 5 5 rm -rf /etc' "safety timeout -k rm-rf"
expect_block "$SAFETY" 'timeout -s TERM -k 5 5 rm -rf /etc' "safety timeout -s -k rm-rf"
expect_block "$SAFETY" 'timeout --signal=TERM 5 rm -rf /etc' "safety timeout --signal= rm-rf"
expect_block "$SAFETY" 'doas rm -rf /etc' "safety doas rm-rf"
expect_block "$SAFETY" 'nice -n 5 rm -rf /etc' "safety nice -n rm-rf"
# #126: launcher false positives -- a non-rm wrapped command stays allowed.
expect_allow "$SAFETY" 'timeout 5 echo hi' "safety timeout echo allowed"
expect_allow "$SAFETY" 'nice -n 5 make' "safety nice make allowed"
expect_allow "$SAFETY" 'echo x | xargs rm -f' "safety xargs rm -f allowed"
# #126 residual: brace expansion that reaches a protected root. The literal brace
# must reach the hook unexpanded, so single quotes are intentional.
# shellcheck disable=SC2016
expect_block "$SAFETY" 'rm -rf /{etc,usr}' "safety brace /{etc,usr}"
# shellcheck disable=SC2016
expect_block "$SAFETY" 'rm -rf /{e,u}*' "safety brace+glob /{e,u}*"
# shellcheck disable=SC2016
expect_allow "$SAFETY" 'rm -rf /tmp/{a,b}' "safety brace /tmp allowed"
# #126 residual: brace *sequences* ({a..b}) whose literal prefix only completes
# into a protected root must block; a sequence under /tmp stays allowed.
# shellcheck disable=SC2016
expect_block "$SAFETY" 'rm -rf /et{c..c}' "safety brace seq /et{c..c}"
# shellcheck disable=SC2016
expect_block "$SAFETY" 'rm -rf /Librar{y..y}' "safety brace seq /Librar{y..y}"
# shellcheck disable=SC2016
expect_allow "$SAFETY" 'rm -rf /tmp/{0..9}' "safety brace seq /tmp allowed"
# #126 residual: a comma list too large to fully expand must fail closed, not
# silently drop the protected alternative past the bound.
big=$(printf 'x%d,' {0..70})
# shellcheck disable=SC2016
expect_block "$SAFETY" "rm -rf /{${big}etc}" "safety brace overflow fails closed"
# #126 residual: tilde-user forms name a home dir the same as bare ~.
expect_block "$SAFETY" 'rm -rf ~root' "safety ~root"
expect_block "$SAFETY" 'rm -rf ~nobody' "safety ~nobody"
expect_block "$SAFETY" 'rm -rf ~root/.ssh' "safety ~root child"
expect_allow "$SAFETY" 'rm -rf ./tmp~backup' "safety trailing tilde allowed"
# #126 residual: chmod recursive flag and world-writable mode in one bundled token.
expect_block "$SAFETY" 'chmod -R777 ~' "safety chmod -R777 bundle"
expect_block "$SAFETY" 'chmod -R=777 /etc' "safety chmod -R=777 equals"
expect_block "$SAFETY" 'chmod -fR0777 ~' "safety chmod -fR0777 bundle"
expect_allow "$SAFETY" 'chmod -R755 ~' "safety chmod -R755 not world-writable"
# #137: symbolic chmod modes granting world (other) write, separate and bundled.
expect_block "$SAFETY" 'chmod -R a+rwx /etc' "safety chmod a+rwx symbolic"
expect_block "$SAFETY" 'chmod -R o+w /etc' "safety chmod o+w symbolic"
expect_block "$SAFETY" 'chmod -R =rwx /etc' "safety chmod =rwx symbolic"
expect_block "$SAFETY" 'chmod -R ugo+rwx ~' "safety chmod ugo+rwx symbolic"
expect_block "$SAFETY" 'chmod -Ra=rwx /etc' "safety chmod -Ra=rwx bundled symbolic"
# #137: symbolic modes that do NOT grant world-write stay allowed.
expect_allow "$SAFETY" 'chmod -R u+w /etc' "safety chmod u+w owner only"
expect_allow "$SAFETY" 'chmod -R g+w /etc' "safety chmod g+w group only"
expect_allow "$SAFETY" 'chmod -R o-w /etc' "safety chmod o-w removes write"
# #137: a clause with multiple ops still granting world-write must block.
expect_block "$SAFETY" 'chmod -R a-x+w /etc' "safety chmod a-x+w multi-op"
expect_block "$SAFETY" 'chmod -R o+w-x /etc' "safety chmod o+w-x multi-op"
expect_block "$SAFETY" 'chmod -R u-w,o-x+w /etc' "safety chmod multi-clause world"
expect_allow "$SAFETY" 'chmod -R u+w-x /etc' "safety chmod u+w-x owner only"
# #137: nested braces whose only literal prefix is `/` still resolve to a root.
# shellcheck disable=SC2016
expect_block "$SAFETY" 'rm -rf /{etc,x{a..b}}' "safety nested brace /{etc,x{a..b}}"
# shellcheck disable=SC2016
expect_block "$SAFETY" 'rm -rf /{x{1..2},etc}' "safety nested brace /{x{1..2},etc}"
# shellcheck disable=SC2016
expect_allow "$SAFETY" 'rm -rf /tmp/{a,b{1..2}}' "safety nested brace /tmp allowed"
# #137: an enormous range must be bounded (no hang/OOM) and fail closed, not
# materialize the whole sequence. This case returns near-instantly if bounded.
# shellcheck disable=SC2016
expect_block "$SAFETY" 'rm -rf /tmp{1..100000000}' "safety huge range bounded fails closed"
# #140: an expansion exactly `limit` (256) alternatives wide is complete, not
# truncated, so a benign non-protected target stays allowed (no fail-closed).
# shellcheck disable=SC2016
expect_allow "$SAFETY" 'rm -rf /srv/{0..255}' "safety brace exactly-limit benign allowed"

# #52: a non-string command must fail open (exit 0), never crash with rc=1.
[ "$(
  jq -nc '{tool_name:"Bash", tool_input:{command:123}}' | "$SAFETY" >/dev/null 2>&1
  echo $?
)" = "0" ] ||
  fail_msg "safety: non-string command did not fail open (expected rc=0)"

# === #113/#114 bypass forms -- each was allowed (rc=0) before the hardening ===
# Path-qualified / launcher-prefixed rm hides the command behind a token.
expect_block "$SAFETY" '/bin/rm -rf /Users/x' "safety /bin/rm path-qualified"
expect_block "$SAFETY" 'command rm -rf /Users/x' "safety command rm prefix"
expect_block "$SAFETY" 'env rm -rf /Users/x' "safety env rm prefix"
# Unspaced separators hide the destructive command after them.
expect_block "$SAFETY" 'true;mkfs.ext4 /dev/sda' "safety unspaced ; mkfs"
expect_block "$SAFETY" 'echo ok&&mkfs.ext4 /dev/sda' "safety unspaced && mkfs"
# Narrow protected-path set: root glob and system dirs.
expect_block "$SAFETY" "bash -c 'rm -rf /*'" "safety bash -c rm-rf root glob"
expect_block "$SAFETY" 'rm -rf /etc' "safety rm-rf /etc"
expect_block "$SAFETY" 'rm -rf /usr/*' "safety rm-rf /usr glob"
# chmod recursive/mode normalization.
expect_block "$SAFETY" 'chmod -R 0777 ~' "safety chmod -R 0777 octal"
expect_block "$SAFETY" 'chmod --recursive 777 ~' "safety chmod --recursive long"
# Force-push false positive: a branch path ending in a protected name is fine.
expect_allow "$SAFETY" 'git push --force origin hotfix/prod' "safety force-push hotfix/prod ok"
# Redirect target must not be read as an rm operand.
expect_allow "$SAFETY" 'rm -rf /tmp/x > /dev/null' "safety rm-rf tmp with redirect"

# === #114 bare push on a protected branch (resolved from the checked-out repo) ===
# A throwaway repo gives a deterministic current branch independent of CWD.
bare_repo=$(mktemp -d)
git -C "$bare_repo" init -q -b main &&
  git -C "$bare_repo" -c user.email=test@example.com -c user.name=test \
    commit -q --allow-empty -m init
bare_rc() { # branch cmd
  git -C "$bare_repo" checkout -q "$1" 2>/dev/null
  jq -nc --arg c "$2" '{tool_name:"Bash", tool_input:{command:$c}}' |
    (cd "$bare_repo" && "$PWD_HOOK/block-push-main.py") >/dev/null 2>&1
  echo $?
}
PWD_HOOK="$(pwd)/hooks"
[ "$(bare_rc main 'git push')" = "2" ] ||
  fail_msg "push: bare 'git push' on main was allowed (expected block)"
git -C "$bare_repo" checkout -q -b feature
[ "$(bare_rc feature 'git push')" = "0" ] ||
  fail_msg "push: bare 'git push' on feature was blocked (expected allow)"
rm -rf "$bare_repo"

# === #132: residual fail-open / under-block gaps in the shared tokenizer ===
# Item 1: nesting past _MAX_DEPTH (5) must fail closed, not silently allow. A
# benign command 6 levels deep is the clean signal -- before the fix it was
# allowed (rc=0) because the inner command was never reached.
nested() { # depth inner
  python3 - "$1" "$2" <<'PY'
import sys
def shq(s): return "'" + s.replace("'", "'\\''") + "'"
depth, cmd = int(sys.argv[1]), sys.argv[2]
for _ in range(depth):
  cmd = "bash -c " + shq(cmd)
sys.stdout.write(cmd)
PY
}
expect_block "$RMRF" "$(nested 5 'rm -rf ./x')" "rm-rf nest 5 inner caught"
expect_block "$RMRF" "$(nested 6 'ls -la')" "rm-rf nest 6 benign fails closed"
expect_block "$SAFETY" "$(nested 6 'echo hi')" "safety nest 6 benign fails closed"
# The same boundary must hold on the unbalanced-quote fallback path: a deep
# wrapper shlex cannot parse (odd quote count) must fail closed, not flat-split
# past the bound and silently drop the inner command.
unbalanced() { # count inner -> N unclosed `bash -c '` wrappers around inner
  local n="$1" inner="$2" out="" k
  for ((k = 0; k < n; k++)); do out="bash -c '$out"; done
  printf '%s%s' "$out" "$inner"
}
expect_block "$SAFETY" "$(unbalanced 7 'rm -rf /etc')" "safety deep unbalanced fails closed"
expect_block "$RMRF" "$(unbalanced 7 'rm -rf ./x')" "rm-rf deep unbalanced fails closed"

# timeout with no DURATION must not consume the wrapped command as the duration.
expect_block "$SAFETY" 'timeout rm -rf /etc' "safety timeout no-duration rm"
expect_block "$SAFETY" 'timeout mkfs.ext4 /dev/sda' "safety timeout no-duration mkfs"
expect_block "$RMRF" 'timeout rm -rf ./x' "rm-rf timeout no-duration"

# Item 3: a non-dict tool_input must fail open cleanly (rc=0), not crash to rc=1.
for hook in "$RMRF" "$PUSH" "$SAFETY"; do
  for payload in '{"tool_input":"x"}' '{"tool_input":null}'; do
    rc=$(
      printf '%s' "$payload" | "$hook" >/dev/null 2>&1
      echo $?
    )
    [ "$rc" = "0" ] || fail_msg "$(basename "$hook"): non-dict tool_input rc=$rc (expected 0)"
  done
done

# Item 4: dd/mkfs/fdisk/chmod must skip launcher prefixes and brace groups, the
# way rm/git already do.
expect_block "$SAFETY" 'sudo dd if=/dev/zero of=/dev/disk0' "safety sudo dd"
expect_block "$SAFETY" 'command mkfs.ext4 /dev/sda' "safety command mkfs"
expect_block "$SAFETY" 'env mkfs.ext4 /dev/sda' "safety env mkfs"
expect_block "$SAFETY" 'sudo chmod -R 777 /etc' "safety sudo chmod 777"
expect_block "$SAFETY" '{ rm -rf /etc; }' "safety brace-group rm-rf"
expect_block "$SAFETY" '{ mkfs.ext4 /dev/sda; }' "safety brace-group mkfs"

# Item 5: git push evasions -- --repo supplies the remote (so main is a
# refspec), and --all/--mirror push every branch including main.
expect_block "$PUSH" 'git push --repo=origin main' "push --repo= main"
expect_block "$PUSH" 'git push --repo origin main' "push --repo separate main"
expect_block "$PUSH" 'git push --all origin' "push --all"
expect_block "$PUSH" 'git push --mirror origin' "push --mirror"
expect_allow "$PUSH" 'git push --repo=origin feature' "push --repo= feature ok"

# Item 6: an unbalanced-quote payload inside bash -c must still be re-scanned by
# the fallback, not flat-split and missed.
expect_block "$SAFETY" "bash -c 'rm -rf /etc" "safety unbalanced bash -c rm-rf"
expect_block "$RMRF" "bash -c 'rm -rf ./build" "rm-rf unbalanced bash -c"

# Item 2: a bare `git push` whose branch cannot be resolved must fail closed when
# git itself errored, but stay allowed when simply outside a repo.
fakebin=$(mktemp -d)
cat >"$fakebin/git" <<'EOS'
#!/bin/sh
echo "fatal: kaboom" >&2
exit 128
EOS
chmod +x "$fakebin/git"
norepo=$(mktemp -d)
cat >"$norepo/git" <<'EOS'
#!/bin/sh
echo "fatal: not a git repository (or any of the parent directories)" >&2
exit 128
EOS
chmod +x "$norepo/git"
nogit=$(mktemp -d)
ln -s "$(command -v python3)" "$nogit/python3"
push_with_path() { # pathdir cmd
  jq -nc --arg c "$2" '{tool_name:"Bash", tool_input:{command:$c}}' |
    PATH="$1" "$PWD_HOOK/block-push-main.py" >/dev/null 2>&1
  echo $?
}
[ "$(push_with_path "$fakebin:$PATH" 'git push')" = "2" ] ||
  fail_msg "push: bare push with git erroring did not fail closed (expected block)"
[ "$(push_with_path "$nogit" 'git push')" = "2" ] ||
  fail_msg "push: bare push with git absent did not fail closed (expected block)"
[ "$(push_with_path "$norepo:$PATH" 'git push')" = "0" ] ||
  fail_msg "push: bare push outside a repo should be allowed (expected rc=0)"
# #141: outside-repo detection must not depend on the user's locale. This fake
# git emits its "not a repository" diagnostic in English only under LC_ALL=C; the
# hook must force LC_ALL=C so the bare push is still allowed even when the ambient
# locale is non-English (here de_DE). Without the fix the German message would not
# match and the push would fail closed (block).
locale_norepo=$(mktemp -d)
cat >"$locale_norepo/git" <<'EOS'
#!/bin/sh
if [ "$LC_ALL" = "C" ]; then
  echo "fatal: not a git repository (or any of the parent directories)" >&2
else
  echo "fatal: Kein Git-Repository (oder eines der ubergeordneten Verzeichnisse)" >&2
fi
exit 128
EOS
chmod +x "$locale_norepo/git"
[ "$(LC_ALL=de_DE.UTF-8 push_with_path "$locale_norepo:$PATH" 'git push')" = "0" ] ||
  fail_msg "push: outside-repo under a non-English locale should be allowed (expected rc=0)"
rm -rf "$fakebin" "$norepo" "$nogit" "$locale_norepo"

if [ "$fail" -eq 0 ]; then
  echo "test-guard-hooks: PASS"
else
  echo "test-guard-hooks: $fail FAILURE(S)"
  exit 1
fi
