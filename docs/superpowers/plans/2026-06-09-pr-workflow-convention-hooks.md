# PR-Workflow Convention Enforcement Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the PR-workflow convention (create/merge session separation, repo cleanliness) authoritative across every project via two global hooks, fix the silent-no-op `safety-warn.sh`, and document the convention in the global CLAUDE.md.

**Architecture:** Two new command hooks in `hooks/`, wired through the existing `run-hook.sh` dispatcher in the template `settings.json`. Non-blocking advisories use exit 0 + JSON `additionalContext` (the only model-visible non-blocking channel); the Stop nudge uses exit 2 once, loop-guarded by a per-session marker under `~/.claude/state/`. Documentation lives in `claude-md-template.md` (symlinked to `~/.claude/CLAUDE.md`).

**Tech Stack:** Bash (shellcheck `-x` + `shfmt -i 2` clean), `jq` for JSON I/O, the repo's existing test harness (`tests/*.sh`, `tests/run-all.sh`).

**Reference spec:** `docs/superpowers/specs/2026-06-09-pr-workflow-convention-design.md`

---

## File Structure

- Create: `hooks/warn-merge-after-pr.sh` — PreToolUse/Bash advisory (Hook A).
- Create: `hooks/stop-check-clean-repo.sh` — Stop nudge (Hook B).
- Create: `tests/test-convention-hooks.sh` — tests for A, B, and the D fix.
- Modify: `hooks/safety-warn.sh` — exit-0+stderr → exit-0+JSON `additionalContext` (Hook D).
- Modify: `settings.json` — wire A into PreToolUse/Bash, B into Stop.
- Modify: `tests/run-all.sh` — register the new test.
- Modify: `docs/HOOKS.md` — correct safety-warn description, add A and B entries.
- Modify: `claude-md-template.md` — add the convention to the Workflow section (Hook C).

State files (created at runtime, not committed): `~/.claude/state/pr-created-<session_id>`, `~/.claude/state/clean-nudged-<session_id>`.

---

## Task 1: Hook A — `warn-merge-after-pr.sh`

**Files:**
- Create: `hooks/warn-merge-after-pr.sh`
- Test: `tests/test-convention-hooks.sh` (Hook A section)

- [ ] **Step 1: Write the failing test** — create `tests/test-convention-hooks.sh` with the Hook A cases.

```bash
#!/usr/bin/env bash
# Convention hooks: warn-merge-after-pr.sh (A), stop-check-clean-repo.sh (B),
# and the safety-warn.sh JSON conversion (D). Each case synthesizes the hook's
# stdin JSON and asserts on exit code / stdout. A throwaway HOME keeps marker
# files out of the real ~/.claude.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

fail=0
fail_msg() {
  echo "FAIL: $1" >&2
  fail=$((fail + 1))
}

TMPHOME="$(mktemp -d)"
trap 'rm -rf "$TMPHOME"' EXIT

# === Hook A: warn-merge-after-pr.sh ===
A="hooks/warn-merge-after-pr.sh"

run_a() { # cmd sid  -> stdout; sets global A_RC
  local out
  out=$(jq -nc --arg c "$1" --arg s "$2" \
    '{tool_name:"Bash",tool_input:{command:$c},session_id:$s}' |
    HOME="$TMPHOME" bash "$A")
  A_RC=$?
  printf '%s' "$out"
}

# create sets a per-session marker, exits 0, emits nothing.
out=$(run_a 'gh pr create -t x -b y' 'S1')
[ "$A_RC" = 0 ] || fail_msg "A: create did not exit 0"
[ -z "$out" ] || fail_msg "A: create should emit no advisory"
[ -f "$TMPHOME/.claude/state/pr-created-S1" ] || fail_msg "A: create did not set marker"

# merge in the same session emits additionalContext, still exits 0.
out=$(run_a 'gh pr merge 12 --squash' 'S1')
[ "$A_RC" = 0 ] || fail_msg "A: merge did not exit 0"
printf '%s' "$out" | jq -e '.hookSpecificOutput.additionalContext' >/dev/null 2>&1 ||
  fail_msg "A: merge with marker did not emit additionalContext"

# merge in a fresh session (no marker) is silent.
out=$(run_a 'gh pr merge 12 --squash' 'S2')
[ "$A_RC" = 0 ] || fail_msg "A: merge no-marker did not exit 0"
[ -z "$out" ] || fail_msg "A: merge without marker should be silent"

# `gh pr create` inside a quoted literal must not set a marker.
out=$(run_a 'echo "gh pr create"' 'S3')
[ -f "$TMPHOME/.claude/state/pr-created-S3" ] && fail_msg "A: quoted create set a marker"

echo "convention-hooks A: checks ran"
[ "$fail" -eq 0 ] || { echo "FAILED: $fail check(s)" >&2; exit 1; }
echo "ALL CONVENTION-HOOK TESTS PASSED"
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash tests/test-convention-hooks.sh`
Expected: FAIL — `hooks/warn-merge-after-pr.sh` does not exist (bash can't open it), checks report failures.

- [ ] **Step 3: Write the hook**

Create `hooks/warn-merge-after-pr.sh`:

```bash
#!/usr/bin/env bash
# PreToolUse hook (matcher: Bash): non-blocking advisory for the create/merge
# session-separation convention. Records a per-session marker when `gh pr
# create` runs; on a later `gh pr merge` in the same session, injects a
# system reminder via JSON additionalContext. Never blocks (exit 0).
#
# Exit-0 stderr is invisible to Claude (see docs/HOOKS.md), so the advisory is
# emitted as JSON on stdout -- the only non-blocking, model-visible channel.
set -uo pipefail

input=$(cat)
cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // ""' 2>/dev/null || echo "")
sid=$(printf '%s' "$input" | jq -r '.session_id // ""' 2>/dev/null || echo "")
[ -n "$cmd" ] || exit 0
[ -n "$sid" ] || sid="unknown"

state_dir="${HOME}/.claude/state"
mkdir -p "$state_dir" 2>/dev/null || true
# Keep the dir from accumulating stale markers across many sessions.
find "$state_dir" -name 'pr-created-*' -type f -mtime +7 -delete 2>/dev/null || true

# Strip quoted strings before matching (mirrors block-push-main.sh) so a
# `gh pr create` inside a quoted literal does not trigger.
scrubbed=$(printf '%s' "$cmd" | sed -E 's/"[^"]*"//g' | sed -E "s/'[^']*'//g")

is_pr_create() { printf '%s' "$scrubbed" | grep -Eq '(^|[^[:alnum:]])gh([[:space:]]+[^;&|]*)?[[:space:]]pr[[:space:]]+create([[:space:]]|$)'; }
is_pr_merge() { printf '%s' "$scrubbed" | grep -Eq '(^|[^[:alnum:]])gh([[:space:]]+[^;&|]*)?[[:space:]]pr[[:space:]]+merge([[:space:]]|$)'; }

marker="${state_dir}/pr-created-${sid}"
if is_pr_create; then
  : >"$marker" 2>/dev/null || true
fi

if is_pr_merge && { [ -f "$marker" ] || is_pr_create; }; then
  msg="PR-workflow convention: this session created a PR. Merges belong in a separate review-cycle session, not the session that created the PR. Proceeding -- consider deferring the merge to a fresh session."
  jq -nc --arg c "$msg" \
    '{hookSpecificOutput:{hookEventName:"PreToolUse",additionalContext:$c}}'
fi

exit 0
```

- [ ] **Step 4: Make it executable and lint it**

Run:
```bash
chmod +x hooks/warn-merge-after-pr.sh
shellcheck -x hooks/warn-merge-after-pr.sh
shfmt -i 2 -d hooks/warn-merge-after-pr.sh
```
Expected: no output (clean). Fix any finding before continuing.

- [ ] **Step 5: Run the test to verify it passes**

Run: `bash tests/test-convention-hooks.sh`
Expected: `ALL CONVENTION-HOOK TESTS PASSED`.

- [ ] **Step 6: Commit**

```bash
git add hooks/warn-merge-after-pr.sh tests/test-convention-hooks.sh
git commit -m "Add warn-merge-after-pr hook for create/merge separation"
```

---

## Task 2: Hook B — `stop-check-clean-repo.sh`

**Files:**
- Create: `hooks/stop-check-clean-repo.sh`
- Test: `tests/test-convention-hooks.sh` (append Hook B section before the final pass/fail block)

- [ ] **Step 1: Write the failing test** — insert this block into `tests/test-convention-hooks.sh` immediately before the `echo "convention-hooks A: checks ran"` line.

```bash
# === Hook B: stop-check-clean-repo.sh ===
B="hooks/stop-check-clean-repo.sh"

mk_repo() { # -> echoes a fresh repo path with one commit
  local r
  r="$(mktemp -d)"
  git -C "$r" init -q
  git -C "$r" config user.email t@example.com
  git -C "$r" config user.name tester
  echo one >"$r/file"
  git -C "$r" add file
  git -C "$r" commit -qm init
  printf '%s' "$r"
}

mk_transcript() { # tool_name -> echoes a transcript path containing one tool_use
  local t
  t="$(mktemp)"
  printf '%s\n' "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"tool_use\",\"name\":\"$1\"}]}}" >"$t"
  printf '%s' "$t"
}

run_b() { # cwd sid transcript -> echoes exit code
  jq -nc --arg c "$1" --arg s "$2" --arg t "$3" \
    '{cwd:$c,session_id:$s,transcript_path:$t,hook_event_name:"Stop"}' |
    HOME="$TMPHOME" bash "$B" >/dev/null 2>&1
  echo $?
}

# dirty tree + a mutating-tool transcript -> nudge once (exit 2), then exit 0.
repo="$(mk_repo)"
echo two >>"$repo/file" # make it dirty
tr_edit="$(mk_transcript Edit)"
[ "$(run_b "$repo" B1 "$tr_edit")" = 2 ] || fail_msg "B: dirty+Edit should nudge (exit 2)"
[ "$(run_b "$repo" B1 "$tr_edit")" = 0 ] || fail_msg "B: second call same session should allow stop (exit 0)"

# clean tree -> no nudge.
git -C "$repo" commit -qam two
[ "$(run_b "$repo" B2 "$tr_edit")" = 0 ] || fail_msg "B: clean tree should not nudge"

# dirty tree but read-only transcript (no mutating tool) -> no nudge.
echo three >>"$repo/file"
tr_read="$(mk_transcript Read)"
[ "$(run_b "$repo" B3 "$tr_read")" = 0 ] || fail_msg "B: dirty+read-only should not nudge"

# non-repo cwd -> no nudge.
nonrepo="$(mktemp -d)"
[ "$(run_b "$nonrepo" B4 "$tr_edit")" = 0 ] || fail_msg "B: non-repo cwd should not nudge"
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash tests/test-convention-hooks.sh`
Expected: FAIL — `hooks/stop-check-clean-repo.sh` does not exist; B checks fail.

- [ ] **Step 3: Write the hook**

Create `hooks/stop-check-clean-repo.sh`:

```bash
#!/usr/bin/env bash
# Stop hook (command type): nudge to commit/clean up before finishing, gated to
# avoid false positives. Fires at most once per session (marker), exit 2 to
# force one continue; exit 0 otherwise. See docs/HOOKS.md.
#
# Gates (all required to nudge): cwd is a git work tree; the tree is dirty; and
# this session's transcript shows a mutating file tool (Edit/Write/MultiEdit/
# NotebookEdit), so pre-existing dirt in read-only sessions is never nagged.
set -uo pipefail

input=$(cat)
cwd=$(printf '%s' "$input" | jq -r '.cwd // ""' 2>/dev/null || echo "")
sid=$(printf '%s' "$input" | jq -r '.session_id // ""' 2>/dev/null || echo "")
transcript=$(printf '%s' "$input" | jq -r '.transcript_path // ""' 2>/dev/null || echo "")
[ -n "$cwd" ] || exit 0
[ -n "$sid" ] || sid="unknown"

state_dir="${HOME}/.claude/state"
mkdir -p "$state_dir" 2>/dev/null || true
find "$state_dir" -name 'clean-nudged-*' -type f -mtime +7 -delete 2>/dev/null || true
nudged="${state_dir}/clean-nudged-${sid}"

# Already nudged this session -> allow the stop (loop-safe; no stop_hook_active).
[ -f "$nudged" ] && exit 0

git -C "$cwd" rev-parse --is-inside-work-tree >/dev/null 2>&1 || exit 0
[ -n "$(git -C "$cwd" status --porcelain 2>/dev/null)" ] || exit 0

[ -n "$transcript" ] && [ -f "$transcript" ] || exit 0
grep -Eq '"name":[[:space:]]*"(Edit|Write|MultiEdit|NotebookEdit)"' "$transcript" 2>/dev/null || exit 0

: >"$nudged" 2>/dev/null || true
cat >&2 <<'MSG'
PR-workflow convention: this session left uncommitted changes in the working
tree. Commit local work via a PR and clean up the repo before finishing, or
stop again if the work-in-progress tree is intentional.
MSG
exit 2
```

- [ ] **Step 4: Make it executable and lint it**

Run:
```bash
chmod +x hooks/stop-check-clean-repo.sh
shellcheck -x hooks/stop-check-clean-repo.sh
shfmt -i 2 -d hooks/stop-check-clean-repo.sh
```
Expected: clean.

- [ ] **Step 5: Run the test to verify it passes**

Run: `bash tests/test-convention-hooks.sh`
Expected: `ALL CONVENTION-HOOK TESTS PASSED`.

- [ ] **Step 6: Commit**

```bash
git add hooks/stop-check-clean-repo.sh tests/test-convention-hooks.sh
git commit -m "Add stop-check-clean-repo hook nudging on dirty tree"
```

---

## Task 3: Hook D — fix `safety-warn.sh` to JSON `additionalContext`

**Files:**
- Modify: `hooks/safety-warn.sh`
- Test: `tests/test-convention-hooks.sh` (append Hook D section before the final pass/fail block)

- [ ] **Step 1: Write the failing test** — insert this block into `tests/test-convention-hooks.sh` immediately before the `echo "convention-hooks A: checks ran"` line.

```bash
# === Hook D: safety-warn.sh now emits JSON additionalContext (not stderr) ===
D="hooks/safety-warn.sh"

run_d() { # file_path -> stdout
  jq -nc --arg f "$1" '{tool_name:"Write",tool_input:{file_path:$f}}' | bash "$D"
}

out=$(run_d '/tmp/project/.env')
printf '%s' "$out" | jq -e '.hookSpecificOutput.additionalContext' >/dev/null 2>&1 ||
  fail_msg "D: sensitive path did not emit additionalContext"

out=$(run_d '/tmp/project/notes.txt')
[ -z "$out" ] || fail_msg "D: benign path should emit nothing"
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash tests/test-convention-hooks.sh`
Expected: FAIL — current `safety-warn.sh` writes to stderr, so stdout is empty and the `additionalContext` assertion fails.

- [ ] **Step 3: Rewrite the hook**

Replace the entire contents of `hooks/safety-warn.sh` with:

```bash
#!/usr/bin/env bash
# PreToolUse hook (matcher: Edit|Write): warn (no block) on sensitive paths.
# Exit 0 always. The advisory is emitted as JSON additionalContext on stdout --
# exit-0 stderr is invisible to Claude (see docs/HOOKS.md), so a stderr warning
# would reach no one.
#
# Hard reads/writes to many of these paths are already blocked by the deny
# rules in settings.json. This hook adds visibility for paths that slip past
# (custom locations, project-specific .env files, etc.).
set -uo pipefail

input=$(cat)
fp=$(printf '%s' "$input" | jq -r '.tool_input.file_path // ""' 2>/dev/null || echo "")
[ -n "$fp" ] || exit 0

if printf '%s' "$fp" | grep -qE '(\.env(\.[^/]+)?$|/credentials([._-][^/]+)?(\.[a-z]+)?$|secrets?\.(json|ya?ml)$|\.pem$|\.key$|id_rsa(\.|$)|\.p12$|\.pfx$|\.gpg$)'; then
  msg="Editing a sensitive-looking file (${fp}). Verify it is in .gitignore; never hardcode secrets (use env vars or a secrets manager); run 'git status' after editing to confirm it will not be committed."
  jq -nc --arg c "$msg" \
    '{hookSpecificOutput:{hookEventName:"PreToolUse",additionalContext:$c}}'
fi

exit 0
```

- [ ] **Step 4: Lint**

Run:
```bash
shellcheck -x hooks/safety-warn.sh
shfmt -i 2 -d hooks/safety-warn.sh
```
Expected: clean.

- [ ] **Step 5: Run the test to verify it passes**

Run: `bash tests/test-convention-hooks.sh`
Expected: `ALL CONVENTION-HOOK TESTS PASSED`.

- [ ] **Step 6: Commit**

```bash
git add hooks/safety-warn.sh tests/test-convention-hooks.sh
git commit -m "safety-warn: emit JSON additionalContext (exit-0 stderr is invisible)"
```

---

## Task 4: Register the test and wire the hooks into `settings.json`

**Files:**
- Modify: `tests/run-all.sh:11` (the `TESTS` array)
- Modify: `settings.json` (PreToolUse Bash array; Stop array)

- [ ] **Step 1: Register the new test** — add the new test to the `TESTS` array in `tests/run-all.sh`, after `tests/test-guard-hooks.sh`:

```bash
  tests/test-guard-hooks.sh
  tests/test-convention-hooks.sh
  tests/test-hook-resilience.sh
```

- [ ] **Step 2: Wire Hook A into PreToolUse/Bash** — in `settings.json`, the `PreToolUse` → `Bash` matcher group's `hooks` array currently ends with the `safety-block.py` entry. Add a fourth entry after it:

```json
          {
            "type": "command",
            "command": "$HOME/.claude/hooks/run-hook.sh warn-merge-after-pr.sh"
          }
```

- [ ] **Step 3: Wire Hook B into Stop** — in `settings.json`, the `Stop` array's single object has a `hooks` list containing the `prompt` hook. Add a `command` entry to that same `hooks` list, after the prompt entry:

```json
          {
            "type": "command",
            "command": "$HOME/.claude/hooks/run-hook.sh stop-check-clean-repo.sh"
          }
```

The Stop `hooks` list then holds two entries: the existing `prompt` hook and the new `command` hook. Both run on stop.

- [ ] **Step 4: Validate settings JSON**

Run:
```bash
jq -e '.hooks.Stop[0].hooks | length == 2' settings.json
jq -e '[.hooks.PreToolUse[] | select(.matcher=="Bash")][0].hooks | length == 4' settings.json
bash tests/test-settings-valid.sh
```
Expected: `true`, `true`, and the settings-valid test passes.

- [ ] **Step 5: Commit**

```bash
git add settings.json tests/run-all.sh
git commit -m "Wire convention hooks into settings; register test"
```

---

## Task 5: Documentation — convention (Hook C) and HOOKS.md

**Files:**
- Modify: `claude-md-template.md` (Workflow section)
- Modify: `docs/HOOKS.md`

- [ ] **Step 1: Add the convention to the global CLAUDE.md template** — in `claude-md-template.md`, locate the `## Workflow` section. Add this subsection at its end (before the next top-level `##` heading). First open the file and confirm the exact heading text, then insert:

```markdown
### PR-session discipline

Across all projects, commit local work via PRs when the work suits the repo, and
leave the local repo clean before ending a turn — no dangling uncommitted work.

- Never run `gh pr merge` in the same session that ran `gh pr create`. Authoring
  and merging are separate sessions.
- The review/merge cycle is its own session: a fresh session runs
  `/pr-review-toolkit:review-pr` on open PRs, merges, and files follow-up issues.
- Do not work issues in the same session as the review cycle.
```

- [ ] **Step 2: Correct the `safety-warn.sh` entry in `docs/HOOKS.md`** — find the `### safety-warn.sh` section (it currently says "Stderr is shown to Claude as a nudge; the Edit/Write proceeds.") and replace that sentence with:

```markdown
The advisory is emitted as JSON `additionalContext` on stdout (exit 0, non-blocking); the Edit/Write proceeds. Exit-0 **stderr** is written only to the debug log and is never shown to Claude, so warnings must use the JSON `additionalContext` channel.
```

- [ ] **Step 3: Add entries for the two new hooks to `docs/HOOKS.md`** — under the `## Installed hooks` section, add:

```markdown
### `warn-merge-after-pr.sh` (PreToolUse Bash, exit 0)

Non-blocking advisory for the create/merge session-separation convention. On `gh
pr create` it writes a per-session marker `~/.claude/state/pr-created-<session_id>`;
on a later `gh pr merge` in the same session it emits JSON `additionalContext`
reminding that merges belong in a separate session. Never blocks. Review-cycle
sessions (no `gh pr create`) are silent. **Test:** `bash tests/test-convention-hooks.sh`.

### `stop-check-clean-repo.sh` (Stop, command, exit 2 once)

Nudges to commit/clean up when a session leaves the cwd repo dirty. Gated: only
fires when cwd is a git work tree, the tree is dirty, AND the session transcript
shows a mutating tool (Edit/Write/MultiEdit/NotebookEdit). Loop-safe via a
per-session marker `~/.claude/state/clean-nudged-<session_id>` (fires at most
once; no dependency on `stop_hook_active`). **Test:** `bash tests/test-convention-hooks.sh`.
```

- [ ] **Step 4: Commit**

```bash
git add claude-md-template.md docs/HOOKS.md
git commit -m "Document PR-session discipline and the new convention hooks"
```

---

## Task 6: Install, full-suite verification, and PR

**Files:** none modified (install + verify only).

- [ ] **Step 1: Install hooks and merged settings into `~/.claude`**

Run:
```bash
./scripts/install.sh hooks settings
```
Expected: symlinks created for `warn-merge-after-pr.sh` and `stop-check-clean-repo.sh`; `~/.claude/settings.json` jq-merged.

- [ ] **Step 2: Verify the live install picked up the hooks**

Run:
```bash
ls -l ~/.claude/hooks/warn-merge-after-pr.sh ~/.claude/hooks/stop-check-clean-repo.sh
jq -e '.hooks.Stop[0].hooks | map(.command // .type) | any(. == "$HOME/.claude/hooks/run-hook.sh stop-check-clean-repo.sh")' ~/.claude/settings.json
```
Expected: both symlinks resolve into the repo; jq prints `true`.

- [ ] **Step 3: Run the full test suite + lint exactly as CI does**

Run:
```bash
find . -name '*.sh' -not -path './.git/*' -print0 | xargs -0 shellcheck -x
find . -name '*.sh' -not -path './.git/*' -print0 | xargs -0 shfmt -i 2 -d
bash tests/run-all.sh
```
Expected: shellcheck/shfmt produce no output; `ALL TESTS PASSED`.

- [ ] **Step 4: Push the branch and open the PR (do NOT merge)**

Run:
```bash
git push -u origin pr-workflow-convention-hooks
gh pr create --title "Enforce PR-workflow convention via hooks" --body "$(cat <<'BODY'
Adds two global hooks and documentation so the PR-workflow convention applies in every project.

- warn-merge-after-pr.sh (PreToolUse/Bash): non-blocking reminder when a session that ran `gh pr create` also runs `gh pr merge`.
- stop-check-clean-repo.sh (Stop): nudges once when a session leaves the cwd repo dirty, gated on the session having used a mutating tool.
- safety-warn.sh: fixed a silent no-op — exit-0 stderr never reaches Claude, so warnings now use JSON additionalContext. HOOKS.md corrected to match.
- claude-md-template.md: documents the create/merge session separation and the separate review-cycle session.

Hook exit-code/stdout behavior verified against current Claude Code docs. Tests in tests/test-convention-hooks.sh; full suite and shellcheck/shfmt pass.

Design: docs/superpowers/specs/2026-06-09-pr-workflow-convention-design.md

🤖 Generated with [Claude Code](https://claude.com/claude-code)
BODY
)"
```
Expected: PR created. Per the convention being encoded, it is **not** merged in this session.

- [ ] **Step 5: Confirm clean local state**

Run: `git status`
Expected: working tree clean, branch pushed. Leave the branch for a separate review-cycle session.

---

## Self-Review

**Spec coverage:**
- Requirement #3 (no merge in create session) → Task 1 (Hook A). ✓
- Requirement #2 (clean up before finishing) → Task 2 (Hook B). ✓
- Requirement #1 (commit via PRs) → Task 5 docs + Task 2 nudge. ✓
- Requirements #4/#5 (separate review/issue sessions) → Task 5 docs. ✓
- Pre-existing `safety-warn.sh` bug + HOOKS.md correction → Task 3 + Task 5. ✓
- Wiring + install + tests → Tasks 4 and 6. ✓

**Placeholder scan:** No TBD/TODO; every code step shows complete content. Tasks 5 step 1/step 2 require locating an existing heading/sentence before inserting — the surrounding anchor text is quoted so the edit is unambiguous.

**Type/name consistency:** Hook filenames, marker paths (`pr-created-<sid>`, `clean-nudged-<sid>`), state dir (`~/.claude/state`), function names (`is_pr_create`/`is_pr_merge`, `run_a`/`run_b`/`run_d`, `mk_repo`/`mk_transcript`), and the test file name are identical across all tasks.

**Lint:** Every hook is declared shellcheck `-x` and `shfmt -i 2` clean with an explicit lint step; CI runs the same two checks plus `tests/run-all.sh`.
