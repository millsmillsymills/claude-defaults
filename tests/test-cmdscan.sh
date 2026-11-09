#!/usr/bin/env bash
# Unit tests for the shared cmdscan parser primitives. Everything else drives
# cmdscan through the hook integration layer, which is why the depth-limit and
# fallback-recursion paths went untested; this exercises them directly.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

python3 - <<'PY'
import sys
sys.path.insert(0, "hooks/lib")
import cmdscan as c

fails = []
def check(cond, msg):
  if not cond:
    fails.append(msg)

# tokenize splits unspaced operators and keeps newline as a separator.
check(c.tokenize("true;rm -rf x") == ["true", ";", "rm", "-rf", "x"], "tokenize unspaced ;")
check(c.tokenize("a\nb") == ["a", "\n", "b"], "tokenize newline separator")
try:
  c.tokenize("bash -c 'oops")
  check(False, "tokenize should raise on unbalanced quotes")
except ValueError:
  pass

# segments splits a token list on shell operators.
segs = list(c.segments(["echo", "ok", "&&", "rm", "-rf", "x"]))
check(segs == [["echo", "ok"], ["rm", "-rf", "x"]], "segments on &&")

# command_start skips launchers, env assignments, brace groups, arg-launchers.
check(c.command_start(["sudo", "rm", "-rf"]) == 1, "command_start sudo")
check(c.command_start(["FOO=1", "env", "rm"]) == 2, "command_start env-assign + env")
check(c.command_start(["{", "rm", "-rf"]) == 1, "command_start brace group")
check(c.command_start(["timeout", "5", "rm"]) == 2, "command_start timeout duration")
check(c.command_start(["timeout", "rm", "-rf"]) == 1, "command_start timeout no-duration")
check(c.command_start(["timeout", "1.5m", "rm"]) == 2, "command_start timeout duration suffix")
check(c.command_start(["nice", "-n", "5", "rm"]) == 3, "command_start nice -n")
check(c.command_start(["}"]) == 1, "command_start lone close brace -> past end")

# command_index matches on basename after skipping prefixes.
check(c.command_index(["/bin/rm", "-rf"], "rm") == 0, "command_index /bin/rm")
check(c.command_index(["command", "rm"], "rm") == 1, "command_index command rm")
check(c.command_index(["ls"], "rm") == -1, "command_index non-match")

# nested_payloads unwraps bash -c / combined short flags / eval.
check(list(c.nested_payloads(["bash", "-c", "rm -rf /"])) == ["rm -rf /"], "nested -c")
check(list(c.nested_payloads(["sh", "-lc", "rm -rf /"])) == ["rm -rf /"], "nested -lc")
check(list(c.nested_payloads(["eval", "rm", "-rf"])) == ["rm -rf"], "nested eval")
# A wrapper behind a launcher/env prefix must still be unwrapped (the checks skip
# the same prefixes via command_start, so the parser must agree).
check(list(c.nested_payloads(["env", "bash", "-c", "rm -rf /"])) == ["rm -rf /"], "nested env-prefixed")
check(list(c.nested_payloads(["FOO=1", "bash", "-lc", "rm -rf /"])) == ["rm -rf /"], "nested env-assign-prefixed")
check(list(c.nested_payloads(["nohup", "bash", "-c", "x"])) == ["x"], "nested nohup-prefixed")
check(list(c.nested_payloads(["timeout", "5", "bash", "-c", "x"])) == ["x"], "nested timeout-prefixed")
# #147: env's own option flags (-i, -u NAME, --) precede the command, so a
# bare-skip stops at the flag and hides the wrapper. They must be skipped too.
check(c.command_start(["env", "-i", "rm"]) == 2, "command_start env -i")
check(c.command_start(["env", "-u", "VAR", "rm"]) == 3, "command_start env -u NAME")
check(c.command_start(["env", "--", "rm"]) == 2, "command_start env -- terminator")
check(c.command_start(["env", "-i", "FOO=1", "rm"]) == 3, "command_start env -i then assign")
check(list(c.nested_payloads(["env", "-i", "bash", "-c", "rm -rf /"])) == ["rm -rf /"], "nested env -i prefixed")
check(list(c.nested_payloads(["env", "-u", "X", "bash", "-c", "y"])) == ["y"], "nested env -u prefixed")
check(list(c.nested_payloads(["env", "--", "bash", "-c", "z"])) == ["z"], "nested env -- prefixed")
check(c.fallback_payload(["env", "-i", "bash", "-c", "rm", "-rf", "/etc"]) == "rm -rf /etc", "fallback env -i prefixed")
# #147 residual: a combined short-flag bundle whose LAST letter is a value flag
# (`-iu` == `-i -u`) consumes the NEXT token as that flag's value, so the wrapper
# after it must still be reached. Treating the bundle as a single non-value flag
# stopped the scan one token early and hid the payload.
check(c.command_start(["env", "-iu", "VAR", "bash", "-c", "x"]) == 3, "command_start env -iu VAR bundle")
check(c.command_start(["env", "-ui", "bash", "-c", "x"]) == 2, "command_start env -ui attached value")
check(list(c.nested_payloads(["env", "-iu", "VAR", "bash", "-c", "rm -rf /etc"])) == ["rm -rf /etc"], "nested env -iu bundle")
check(c.fallback_payload(["env", "-iu", "VAR", "bash", "-c", "rm", "-rf", "/etc"]) == "rm -rf /etc", "fallback env -iu bundle")

# strip_redirects drops the operator and the target it consumes.
check(c.strip_redirects(["rm", "-rf", "x", ">", "/dev/null"]) == ["rm", "-rf", "x"], "strip_redirects")

# iter_segments raises past the depth bound (fail closed), not a silent return.
try:
  list(c.iter_segments("bash -c x", depth=6, max_depth=5))
  check(False, "iter_segments should raise past max_depth")
except c.DepthLimitExceeded:
  pass
# At the boundary it still yields.
check(list(c.iter_segments("rm -rf x", depth=5, max_depth=5)) == [["rm", "-rf", "x"]], "iter_segments at boundary")

# fallback_payload rejoins a de-quoted wrapper tail so the fallback can recurse.
check(c.fallback_payload(["bash", "-c", "rm", "-rf", "/etc"]) == "rm -rf /etc", "fallback_payload bash -c")
check(c.fallback_payload(["eval", "rm", "-rf"]) == "rm -rf", "fallback_payload eval")
check(c.fallback_payload(["ls", "-la"]) == "", "fallback_payload non-wrapper")
check(c.fallback_payload(["env", "bash", "-c", "rm", "-rf", "/etc"]) == "rm -rf /etc", "fallback_payload env-prefixed")
check(c.fallback_payload(["FOO=1", "bash", "-c", "rm", "-rf", "/etc"]) == "rm -rf /etc", "fallback_payload env-assign-prefixed")

# A wrapped payload with unbalanced quotes is re-entered by iter_segments' fallback.
segs = list(c.iter_segments("bash -c 'rm -rf /etc"))
check(["rm", "-rf", "/etc"] in segs, "fallback recurses into bash -c payload")

# #142: nested_payloads (balanced) and fallback_payload (unbalanced-quote) share
# one wrapper-flag predicate, so they must agree on which forms carry a command
# string. A form unwrapped by one but missed by the other is where the fallback
# path turns into a bypass. Drive the same forms through both.
# `c` need not be last: `-cl` is `-c -l` and still carries the command.
for flag in ("-c", "-lc", "-cl", "-ec", "-xc", "-cx", "-ic", "-lec"):
  seg = ["bash", flag, "rm -rf /etc"]
  check(list(c.nested_payloads(seg)) == ["rm -rf /etc"], f"nested unwraps {flag}")
  check(c.fallback_payload(seg) == "rm -rf /etc", f"fallback unwraps {flag}")
# A flag that does NOT carry a command (no trailing `c`, or a `--long`) must be
# ignored by BOTH paths, never just one.
for flag in ("-l", "-x", "-i", "--login", "--rcfile"):
  seg = ["bash", flag, "rm -rf /etc"]
  check(list(c.nested_payloads(seg)) == [], f"nested ignores {flag}")
  check(c.fallback_payload(seg) == "", f"fallback ignores {flag}")

# The #147 shape for launchers other than `env`: a launcher's own option argument
# stopped command_start at the first flag, leaving the wrapped command unscanned.
check(c.command_start(["sudo", "-u", "root", "rm"]) == 3, "command_start sudo -u USER")
check(c.command_start(["sudo", "-E", "rm"]) == 2, "command_start sudo boolean flag")
check(c.command_start(["doas", "-u", "root", "rm"]) == 3, "command_start doas -u USER")
check(c.command_start(["ionice", "-c", "3", "rm"]) == 3, "command_start ionice -c CLASS")
check(c.command_start(["ionice", "-c3", "rm"]) == 2, "command_start ionice attached -c3")
check(c.command_start(["watch", "-n", "5", "rm"]) == 3, "command_start watch -n SECS")
check(c.command_start(["chronic", "-e", "rm"]) == 2, "command_start chronic")
# `script`'s typescript FILE is an arbitrary path, so its positional skip takes
# any non-flag token -- unlike `timeout`, whose DURATION must look like one.
check(c.command_start(["script", "-q", "/dev/null", "rm"]) == 3, "command_start script FILE")
check(c.command_start(["script", "-t", "log", "/dev/null", "rm"]) == 4, "command_start script -t LOG FILE")

# argv_payloads pulls out a command carried mid-argv, which sits at neither
# command_start nor the wrapper tail: `find -exec ARGV ;|+` and `script -c STR`.
check(c.argv_payloads(["find", ".", "-exec", "rm", "-rf", "{}", "+"]) == ["rm -rf {}"], "argv find -exec")
check(c.argv_payloads(["find", ".", "-execdir", "rm", "-rf", "{}"]) == ["rm -rf {}"], "argv find -execdir unterminated")
check(c.argv_payloads(["sudo", "find", ".", "-exec", "rm", "-rf", "{}", "+"]) == ["rm -rf {}"], "argv find behind launcher")
check(c.argv_payloads(["find", ".", "-print"]) == [], "argv find without -exec")
check(c.argv_payloads(["script", "-c", "rm -rf /etc", "/dev/null"]) == ["rm -rf /etc"], "argv script -c")
check(c.argv_payloads(["ls", "-c", "x"]) == [], "argv -c outside a command-string launcher")
# Both scan paths must recurse into it -- balanced and unbalanced-quote alike, or
# the fallback becomes the bypass (the #142 lesson).
check(["rm", "-rf", "/etc"] in list(c.iter_segments("find . -exec rm -rf /etc +")), "iter_segments find -exec")
check(["rm", "-rf", "/etc"] in list(c.iter_segments("find . -exec rm -rf '/etc +")), "fallback recurses into find -exec")

# The fallback path must also fail closed past the depth bound, not silently drop
# the inner command (the balanced path raises; the fallback must match).
try:
  list(c.iter_segments("bash -c 'bash -c 'rm -rf /etc", depth=0, max_depth=0))
  check(False, "fallback should raise past max_depth")
except c.DepthLimitExceeded:
  pass

if fails:
  for m in fails:
    print(f"FAIL: {m}")
  sys.exit(1)
print("test-cmdscan: PASS")
PY
