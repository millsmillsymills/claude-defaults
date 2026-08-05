# Hooks Reference

Every hook installed by claude-defaults, what it does, and how to test it. The hooks live at `hooks/*.sh` and `hooks/*.py` in this repo (shared Python helpers in `hooks/lib/`) and are symlinked into `~/.claude/hooks/` by `scripts/install.sh`.

## Missing-hook safety net

Every command-type hook in `settings.json` is invoked through `run-hook.sh <name> [args]` rather than referencing the script directly (the one exception is `session-heal.sh`, wired directly -- see below). This wrapper plus a `doctor.sh` self-heal step make a missing directory or a renamed/removed hook a non-event instead of a `/bin/sh: ...: No such file or directory` failure.

- **`run-hook.sh` (runtime, in every hook command).** Ensures `logs/` and `hooks/lib/` exist and resolves its own symlink back to the repo, so it can run the real script even when `~/.claude/hooks/<name>` is missing or dangling. It does **not** rewrite symlinks -- repairing the install is `doctor.sh`'s job, not the per-tool-call hot path. If the hook genuinely can't be found it warns on stderr and exits 0 (fails OPEN, so infrastructure breakage never blocks a tool call); a real hook's own exit code (including 2 to block) is propagated unchanged. When the skipped hook is a **security** hook (`safety-block.py`, `block-rm-rf.py`, `block-push-main.py`, `block-research-env-clobber.py`, `gate-public-review.sh`), or python3 is unavailable for a `.py` hook, the skip is also recorded to `logs/hook-errors.log` and warned loudly -- a never-ran guard must not be silent.
- **`session-heal.sh` (SessionStart).** Wired **directly** (not through `run-hook.sh`) so it can rebuild the wrapper's own symlink if that is what went missing. Runs `doctor.sh --quick`, appending output to `logs/session-heal.log` for a forensic trail, and never blocks startup.
- **`scripts/doctor.sh` (manual or via SessionStart).** Prunes dangling symlinks under the managed `hooks/`, `hooks/lib/`, `commands/`, `agents/`, and `skills/` dirs (links to vanished repo targets only; foreign links are left alone), then re-links missing content. `--quick` stops there; the default also re-merges `settings.json` from the template (collapsing any duplicated hook groups and picking up renamed hooks). Idempotent. Run it after renaming or removing a hook.

Hook **content** can't be regenerated -- symlinks point into this repo, so if a repo script is deleted the wrapper degrades to a logged skip rather than an error. Re-add the script and run `scripts/doctor.sh`.

## Hook events (Claude Code)

| Event | When it fires | Can block? |
|-------|---------------|------------|
| `PreToolUse` | Before a tool call executes | Yes (exit 2) |
| `PostToolUse` | After a tool call returns | No (already ran) |
| `UserPromptSubmit` | When user submits a prompt | Yes |
| `Stop` | When Claude finishes responding | Yes (forces continue) |
| `SessionStart` | When a session begins/resumes | No |
| `SessionEnd` | When a session ends | No |

## Exit codes (command-type hooks)

| Code | Behavior |
|------|----------|
| `0` | Allow; stdout parsed for optional JSON control |
| `1` | Error, non-blocking; stderr shown in verbose mode |
| `2` | Blocking; stderr fed back to Claude as the rejection reason |

## Installed hooks

### `block-rm-rf.py` (PreToolUse Bash, exit 2)

Blocks any `rm -rf` (recursive+force) invocation -- broader than `safety-block.py`, which only blocks `rm -rf` against protected paths. Shares the `cmdscan` tokenizer, so wrapped (`bash -c '...'`) and unspaced-separator (`true;rm -rf x`) forms are unwrapped and checked. **Test:**

```bash
echo '{"tool_input":{"command":"rm -rf /tmp"}}' | hooks/block-rm-rf.py
# expect: exit 2 with "BLOCKED: Use trash instead of rm -rf"
```

### `block-push-main.py` (PreToolUse Bash, exit 2)

Blocks `git push <remote> main`/`master` -- any explicit refspec whose destination is a protected branch, and a *bare* `git push` when the current branch is main/master. Shares the `cmdscan` tokenizer (wrapped/unspaced forms covered). Does NOT cover force-push or production branches -- that's `safety-block.py`'s job.

### `safety-block.py` (PreToolUse Bash, exit 2)

Tokenizes the command with the shared `cmdscan` parser and matches patterns against the segments, so a payload hidden inside `bash -c '...'`, `sh -c '...'`, or `eval '...'`, and commands after unspaced separators (`true;mkfs ...`), are unwrapped and checked too. Hard-blocks these destructive patterns:

| Category | Pattern |
|---|---|
| `rm -rf` against protected paths | root and the root glob (`rm -rf /`, `/*`), system dirs (`/etc`, `/usr`, `/bin`, ...), `/Users/...`, `~`, `$HOME...` -- including `/bin/rm`, `command rm`, `env rm` forms |
| sudo rm -rf | any `sudo rm -rf ...` |
| dd to disk devices | `dd of=/dev/disk*`, `/dev/sd*`, `/dev/nvme*`, `/dev/rdisk*` |
| Filesystem ops | `mkfs.*`, `wipefs ...` |
| Partition ops | `fdisk -w`, `parted /dev/... mklabel/mkpart/rm/resizepart` |
| Fork bomb | `:(){ :\|:& };:` |
| chmod 777 | recursive (`-R`/`--recursive`) world-writable (`777`/`0777`) against `/` or `~` |
| Force-push | `git push --force/-f/--force-with-lease` whose destination is main/master/production/prod, or with no branch named |
| Wrapped/separated payloads | any of the above inside `bash -c`/`sh -c`/`eval`, or after an unspaced `;`/`&&`/`\|` |

**Test:** `bash tests/test-guard-hooks.sh`

### `block-research-env-clobber.py` (PreToolUse Bash\|Write, exit 2)

Blocks whole-file overwrites of the central research secrets file (`~/.config/research/.env`), which holds credentials shared across every `*-research` repo -- overwriting it with one repo's `.env` wipes every other repo's keys. Covers `cp`/`mv`/`install`/`rsync`/`ln` with the file *or its directory* as destination (including `-t`/`--target-directory`), truncating redirects (`>`, `>|`, `&>`), `tee`/`sponge` (without `-a`), `truncate`, `dd of=`, `curl -o`/`wget -O`, and the Write tool. Reads, appends (`>>`, `tee -a`), copies *from* the file, `.env.example`, and repo-local `.env` files stay allowed. Shares the `cmdscan` tokenizer (wrapped/unspaced/unbalanced-quote forms covered); path spellings are normalized before matching. **Test:**

```bash
echo '{"tool_name":"Bash","tool_input":{"command":"cp .env ~/.config/research/.env"}}' | hooks/block-research-env-clobber.py
# expect: exit 2 with "refusing to overwrite ~/.config/research/.env"
```

### `safety-warn.sh` (PreToolUse Edit\|Write, exit 0)

Soft warning on sensitive paths. The advisory is emitted as JSON `additionalContext` on stdout (exit 0, non-blocking); the Edit/Write proceeds. Exit-0 **stderr** is written only to the debug log and is never shown to Claude, so warnings must use the JSON `additionalContext` channel.

Patterns warned:

- `*.env`, `*.env.*`
- `*credentials*`
- `*secret*.json`, `*secret*.yml`, `*secret*.yaml`
- `*.pem`, `*.key`, `*id_rsa*`, `*.p12`, `*.pfx`, `*.gpg`

Hard reads/writes to `~/.ssh/`, `~/.aws/`, `~/.gnupg/`, etc. are blocked by the deny rules in `settings.json` regardless of this hook.

### `force-worktree-isolation.sh` (PreToolUse Agent\|Task, exit 0)

Forces file-mutating subagents into their own git worktree so parallel sessions never share the main checkout. On an `Agent`/`Task` dispatch it emits JSON `updatedInput` setting `isolation:"worktree"`; the harness re-runs the tool with the modified input. Never blocks (exit 0).

- **Scope.** Only mutating agents are isolated. Read-only `subagent_type`s are skipped (namespace stripped, case-insensitive): `explore`, `plan`, `claude-code-guide`, `red-team-reviewer`, `statusline-setup`. Everything else -- including the default agent and unknown types -- is isolated, so a misclassified read-only agent only wastes a worktree that auto-removes when unchanged, while a mutating agent is never left in the main checkout.
- **Explicit opt-out.** A dispatch that already sets `isolation` (`worktree` or `remote`) is left untouched.
- Fails open: if `jq` is missing or the payload is unparseable it emits nothing and the dispatch proceeds unchanged.

### `enforce-session-worktree.sh start|end` (SessionStart / SessionEnd, exit 0)

Peer-session worktree guard, complementing `force-worktree-isolation.sh`: that hook isolates file-mutating *subagents*; this one covers separately-launched peer `claude` sessions that would otherwise share one main checkout. On `start`, the first session in a repo's main working tree claims an owner marker (`~/.claude/state/worktree-owner-<repo>`); a later session starting in the same checkout while the marker is fresh (< 6h) gets JSON `additionalContext` telling it to work in its own git worktree. On `end`, markers owned by the session are released. Advisory only -- never blocks; a stale marker at worst tells a lone session to use a worktree it does not need. Sessions already in a linked worktree, or outside any git repo, are never touched. **Test:** `bash tests/test-convention-hooks.sh`.

### `warn-merge-after-pr.sh` (PreToolUse Bash, exit 0)

Non-blocking advisory for the create/merge session-separation convention. On `gh
pr create` it writes a per-session marker `~/.claude/state/pr-created-<session_id>`;
on a later `gh pr merge` in the same session it emits JSON `additionalContext`
reminding that merges belong in a separate session. Never blocks. Review-cycle
sessions (no `gh pr create`) are silent. **Test:** `bash tests/test-convention-hooks.sh`.

### `gate-public-review.sh` (PreToolUse Bash, exit 2)

Blocks issue/PR **write** actions to a **public** GitHub repo until both a standard
review and an adversarial review have run this session. The two reviews leave
per-session markers (`review-standard-<sid>`, `review-adversarial-<sid>`) written by
`mark-review.sh`; the gate refuses the write until both exist, then exits 0.

- **Scope.** `gh issue create|edit|comment|close|reopen|delete|lock|unlock|pin|unpin|transfer|develop`, `gh pr create|edit|comment|close|reopen|merge|ready|review`, and `gh api` with a mutating method (`-X POST|PATCH|PUT|DELETE`) against an `/issues` or `/pulls` path. Read-only gh (`list`/`view`/`status`/`diff`/`checks`) and `gh api` GETs are never gated. Quoted `gh ...` literals are scrubbed before matching (mirrors `block-push-main.sh`).
- **Visibility.** Repo is resolved from an explicit `--repo`/`-R` flag, else the cwd remote; `gh repo view --json visibility` is consulted once per repo per session and cached at `repovis-<sid>-<repo>` (1-day backstop sweep). `PRIVATE`/`INTERNAL` repos are exempt. If visibility can't be confirmed the write is **gated** (fail closed) -- the write needs the same network, so an offline session was going to fail anyway.
- A blocking message names the missing review(s) and how to satisfy them. Listed in `run-hook.sh`'s `SECURITY_HOOKS`, so a missing gate is logged loudly instead of failing open. **Test:** `bash tests/test-public-review-gate.sh`.

### `mark-review.sh` (PostToolUse Task, exit 0)

Records that a review ran by writing a per-session marker when a review **subagent
completes** -- so satisfying `gate-public-review.sh` requires actually dispatching the
agent, not a bare `touch`. Maps `subagent_type` (plugin namespace stripped, case-insensitive) to a category:

- **standard** -- `code-reviewer`
- **adversarial** -- `silent-failure-hunter`, `red-team-reviewer`, a security/`security-review` agent, or any subagent whose name reads as security / red-team / adversarial

Running `/pr-review:review-pr` dispatches `code-reviewer` (standard) and
`silent-failure-hunter` (adversarial), so it satisfies both. Non-review subagents and
non-`Task` tools write nothing. **Test:** `bash tests/test-public-review-gate.sh`.

### `stop-check-clean-repo.sh` (Stop, command, exit 2 once)

Nudges to commit/clean up when a session leaves the cwd repo dirty. Gated: only
fires when cwd is a git work tree, the tree is dirty, AND the session transcript
shows a mutating tool (Edit/Write/MultiEdit/NotebookEdit). Loop-safe via a
per-session marker `~/.claude/state/clean-nudged-<session_id>` (fires at most
once; no dependency on `stop_hook_active`). **Test:** `bash tests/test-convention-hooks.sh`.

### `log-tool-calls.sh pre|post` (PreToolUse `*` and PostToolUse `*`)

Append a JSONL row per tool call to `~/.claude/logs/tool-calls-YYYY-MM-DD.jsonl`. See `docs/LOGGING.md` for schema, query examples, and rotation policy.

### `log-rotate.sh` (SessionEnd)

Gzip-rotate today's log if it exceeds `CLAUDE_LOG_ROTATE_BYTES` (default 100 MB), prune logs older than `CLAUDE_LOG_RETAIN_DAYS` days (default 365).

### `cleanup-session-markers.sh` (SessionEnd)

Removes this session's per-session state (`pr-created-<sid>`, `clean-nudged-<sid>`,
`review-standard-<sid>`, `review-adversarial-<sid>`, `repovis-<sid>-*`) from
`~/.claude/state` so it has a clear owner. The mtime sweeps inside
`warn-merge-after-pr.sh` / `stop-check-clean-repo.sh` / `mark-review.sh` /
`gate-public-review.sh` remain only as a backstop for sessions that crash without a
SessionEnd.
**Test:** `bash tests/test-convention-hooks.sh`.

### Anti-rationalization Stop hook (`type: "prompt"`)

Inline prompt-type hook in `settings.json`. Sends Claude's final response to a fast model that returns `{"ok": false, "reason": "..."}` or `{"ok": true}`. If rejected, Claude must continue.

To tune: edit the `prompt` field in `settings.json` `hooks.Stop[0].hooks[0]`.

#### Privacy implications

`type: "prompt"` sends the assistant's full final response text to a fast model on every session end. Redaction (`_log_core.redact_value`) runs only in the JSONL logging path -- it never touches the Stop-hook channel. If Claude echoes a secret in its response (e.g. a connection URL surfaced while debugging), that text reaches the fast model unredacted.

Low severity for a single-account local setup (primary and fast model share one account). It grows under shared deployments, multi-account routing, or providers that log requests. To avoid it entirely, remove the Stop hook or switch it to `type: "command"` with pre-redaction -- but a `command` hook gets no LLM judgment, so the anti-rationalization loop would need reimplementing against its own logic.

## Adding your own hook

1. Create `hooks/<name>.sh` (or `.py`)
2. Make it executable: `chmod +x hooks/<name>.sh`
3. Re-run `./scripts/install.sh hooks` (creates the symlink at `~/.claude/hooks/<name>.sh`)
4. Reference it in `settings.json` via the wrapper: `"$HOME/.claude/hooks/run-hook.sh <name>.sh [args]"`
5. Re-run `./scripts/install.sh settings` to merge the updated hooks block
6. Restart any active Claude Code session for the new hook to fire

## Renaming or removing a hook

Because the live `settings.json` and the `~/.claude/hooks/` symlinks are derived from this repo, a rename leaves a stale symlink behind. After renaming/removing a hook in the repo:

1. Update the template `settings.json` reference (the wrapper arg).
2. Run `./scripts/doctor.sh` -- it prunes the now-dangling symlink and re-merges `settings.json`.

Until you do, `run-hook.sh` and the SessionStart self-heal keep the old name from erroring (logged skip / auto-prune).
