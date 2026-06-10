# PR-Workflow Convention Enforcement — Design

**Date:** 2026-06-09
**Status:** Approved design, pending implementation
**Repo:** claude-defaults

## Problem

The user follows a standing workflow convention across every project under
`~/Desktop/Projects`:

1. Commit local work via PRs (when the work suits the repo).
2. Clean up the local repo before ending a turn (no dangling uncommitted work).
3. Never run `gh pr merge` in the same session that ran `gh pr create`.
4. The review/merge cycle happens in a *separate* session: a fresh session runs
   `/pr-review-toolkit:review-pr` on open PRs, merges, and files follow-ups.
5. Issues are not worked in the same session as the review cycle.

Today this lives only as prose the user repeats. The goal is to make it
authoritative and cross-project. Because the global hooks and the global
`CLAUDE.md` (symlinked to `claude-md-template.md`) already load in every
project, this repo is the correct lever: a change here propagates everywhere.

## Enforceability analysis

The five requirements are not equally machine-detectable. The design treats each
at the strength its detectability supports — over-enforcing an ambiguous rule
produces false positives that train the user to ignore the guardrail.

| Requirement | Detectable? | Treatment |
|---|---|---|
| No merge in the create session (#3) | Cleanly: per-session marker on `gh pr create`, checked on `gh pr merge` | **Hook A** — non-blocking warn |
| Clean up before finishing (#2) | Partially: dirty working tree at session end | **Hook B** — Stop nudge, gated |
| Commit via PRs (#1) | Not as a hard signal (a hook cannot force a PR) | Documentation + Hook B nudge |
| Review cycle is a separate session (#4) | Not reliably (no signal defines "review session") | Documentation only |
| No issue work during review (#5) | Not reliably | Documentation only |

## Hook-mechanism constraints (verified against current docs)

Verified against `https://code.claude.com/docs/en/hooks`:

- **Exit-0 stderr is invisible.** On exit 0, stdout goes to the debug log
  (except `UserPromptSubmit`/`SessionStart`); stderr has no documented channel to
  Claude. A non-blocking warning therefore **cannot** use stderr.
- **Non-blocking model-visible advisories** use exit 0 + JSON on stdout:
  `{"hookSpecificOutput":{"hookEventName":"PreToolUse","additionalContext":"…"}}`.
  `additionalContext` is injected as a system reminder Claude reads, and does not
  block or alter the permission flow.
- **Exit 2 blocks** and feeds stderr to Claude. For `Stop`, exit 2 prevents the
  stop and continues the turn.
- **`stop_hook_active` is not in the current input schema.** Loop-prevention must
  not depend on it; a session-scoped marker file is used instead.

### Consequence: a pre-existing bug

`hooks/safety-warn.sh` warns via exit-0 + stderr, so its sensitive-file warnings
reach neither Claude nor the user — a silent no-op. `docs/HOOKS.md` documents the
same false assumption ("stderr is shown to Claude as a nudge"). Both are fixed as
part of this work (decided in-scope with the user), since the fix is the exact
JSON `additionalContext` mechanism this design introduces.

## Components

### A. `hooks/warn-merge-after-pr.sh` — PreToolUse / Bash, exit 0 + JSON

Non-blocking advisory enforcing requirement #3.

- Read `.tool_input.command` and `.session_id` from stdin (`jq`).
- Scrub quoted strings before token-scanning, matching the technique in
  `block-push-main.sh`/`block-rm-rf.sh` (avoids matching `gh pr create` inside a
  quoted literal).
- Token-scan the scrubbed command:
  - Detects `gh pr create` → `touch ~/.claude/state/pr-created-<session_id>`.
  - Detects `gh pr merge` → if the session marker exists (or the same command
    line also creates a PR), emit JSON `additionalContext` reminding that merges
    belong in a separate session from PR creation. Always exit 0 (non-blocking).
- Opportunistically prune `~/.claude/state/pr-created-*` markers older than 7
  days so the directory does not accumulate.

`gh pr create` fires at PreToolUse (before the command runs), so the marker
records *intent*; a create that later fails still sets it. This is the
conservative direction (warn slightly too often, never too rarely) and is
acceptable for a non-blocking advisory.

Review-cycle sessions never run `gh pr create`, so no marker exists and their
merges are silent — exactly the intended behavior.

### B. `hooks/stop-check-clean-repo.sh` — Stop, command type, exit 2 (once)

Nudge enforcing requirement #2, deliberately gated to avoid false positives on
read-only / Q&A sessions in repos that carry a perpetually dirty tree.

- Read `.cwd`, `.session_id`, `.transcript_path` from stdin.
- Exit 0 (no nudge) unless **all** hold:
  1. `cwd` is inside a git work tree.
  2. `git -C "$cwd" status --porcelain` is non-empty (uncommitted changes).
  3. The session's transcript (`transcript_path`) shows this session used a
     mutating file tool (`Edit` / `Write` / `MultiEdit` / `NotebookEdit`) — i.e.
     the session itself produced changes, rather than inheriting pre-existing
     dirt.
- Loop-safety without `stop_hook_active`: a per-session marker
  `~/.claude/state/clean-nudged-<session_id>`. If present → exit 0 (already
  nudged once). Otherwise write the marker and exit 2 with a message pointing to
  the convention (commit via a PR and clean up, or stop again to confirm the WIP
  tree is intentional). The hook fires at most once per session.

Scope for v1 is **uncommitted changes only**. Unpushed-commit detection
(comparing against an upstream that may not exist) is fragile in bash and
high-false-positive; it is intentionally deferred and noted here so the omission
is visible rather than silent.

### C. Documentation — `claude-md-template.md`

Add the full five-point convention to the Workflow section so it loads in every
project session (the file is symlinked to `~/.claude/CLAUDE.md`). This is the
sole enforcement for requirements #4 and #5 and reinforces #1.

### D. Fix `hooks/safety-warn.sh` + `docs/HOOKS.md`

Convert `safety-warn.sh` from exit-0 + stderr to exit-0 + JSON
`additionalContext` so its warnings actually surface. Correct the
`docs/HOOKS.md` description that claims exit-0 stderr reaches Claude.

## Wiring

- **`settings.json` (template):** append Hook A to the existing
  `PreToolUse` → `Bash` hook array; add Hook B as a second entry in the `Stop`
  array, preserving the existing anti-rationalization `prompt` hook. `doctor.sh`
  re-merges the template, so both must live in the template.
- **Install:** `scripts/install.sh hooks settings` symlinks the new hooks into
  `~/.claude/hooks/` and jq-merges the settings.
- **State dir:** hooks `mkdir -p ~/.claude/state` defensively; it is created on
  demand, never a symlink.

## Testing

New cases in `tests/`, mirroring `tests/test-guard-hooks.sh` style (synthesize a
hook stdin JSON, assert on exit code and output):

- **Hook A:** `gh pr create` sets the marker; a subsequent `gh pr merge` with the
  marker emits `additionalContext` and exits 0; `gh pr merge` with no marker is
  silent; `gh pr create` inside a quoted literal does not set the marker;
  always exits 0.
- **Hook B:** dirty tree + mutating-tool transcript → exit 2 once, then exit 0 on
  the second call (marker); clean tree → exit 0; dirty tree but read-only
  transcript → exit 0; non-repo cwd → exit 0.
- **Hook D:** `safety-warn.sh` on a sensitive path emits JSON `additionalContext`
  and exits 0.

Tests use temp dirs / temp git repos and temp `HOME` so marker files and the
state dir don't touch the real `~/.claude`.

## Process

Per the very convention being encoded: implement on the
`pr-workflow-convention-hooks` branch, open a PR, do **not** merge it in this
session, and clean up the local repo before finishing. The review/merge happens
in a later, separate session.

## Out of scope (v1)

- Unpushed-commit detection in Hook B (noted above).
- Hard-blocking the merge rule (Hook A is advisory by the user's choice; a hard
  block would be a one-line change to exit 2 if revisited).
- Any per-project `.claude/settings.json` — global hooks already cover every
  subdir, so no per-project files are added.
