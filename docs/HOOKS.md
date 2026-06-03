# Hooks Reference

Every hook installed by claude-defaults, what it does, and how to test it. The hooks live at `hooks/*.sh` in this repo and are symlinked into `~/.claude/hooks/` by `scripts/install.sh`.

## Missing-hook safety net

Every command-type hook in `settings.json` is invoked through `run-hook.sh <name> [args]` rather than referencing the script directly (the one exception is `session-heal.sh`, wired directly -- see below). This wrapper plus a `doctor.sh` self-heal step make a missing directory or a renamed/removed hook a non-event instead of a `/bin/sh: ...: No such file or directory` failure.

- **`run-hook.sh` (runtime, in every hook command).** Ensures `logs/` and `hooks/lib/` exist and resolves its own symlink back to the repo, so it can run the real script even when `~/.claude/hooks/<name>` is missing or dangling. It does **not** rewrite symlinks -- repairing the install is `doctor.sh`'s job, not the per-tool-call hot path. If the hook genuinely can't be found it warns on stderr and exits 0 (fails OPEN, so infrastructure breakage never blocks a tool call); a real hook's own exit code (including 2 to block) is propagated unchanged. When the skipped hook is a **security** hook (`safety-block.py`, `block-rm-rf.sh`, `block-push-main.sh`), or python3 is unavailable for a `.py` hook, the skip is also recorded to `logs/hook-errors.log` and warned loudly -- a never-ran guard must not be silent.
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

### `block-rm-rf.sh` (legacy, PreToolUse Bash)

Blocks any `rm -rf` invocation. Inline command in `settings.json`. **Pattern:** `rm[[:space:]]+-[^[:space:]]*r[^[:space:]]*f`. **Test:**

```bash
echo '{"tool_input":{"command":"rm -rf /tmp"}}' | bash hooks/block-rm-rf.sh
# expect: exit 2 with "BLOCKED: Use trash instead of rm -rf"
```

### `block-push-main.sh` (legacy, PreToolUse Bash)

Blocks `git push <remote> main` or `git push <remote> master`. Does NOT cover force-push or production branches -- that's `safety-block.py`'s job.

### `safety-block.py` (PreToolUse Bash, exit 2)

Parses the command with `shlex` and matches patterns against the tokens, so a payload hidden inside `bash -c '...'`, `sh -c '...'`, or `eval '...'` is unwrapped and checked too. Hard-blocks these destructive patterns:

| Category | Pattern |
|---|---|
| `rm -rf` against root/home | `rm -rf /`, `rm -rf /Users/...`, `rm -rf ~`, `rm -rf $HOME...` |
| sudo rm -rf | any `sudo rm -rf ...` |
| dd to disk devices | `dd of=/dev/disk*`, `/dev/sd*`, `/dev/nvme*`, `/dev/rdisk*` |
| Filesystem ops | `mkfs.*`, `wipefs ...` |
| Partition ops | `fdisk -w`, `parted /dev/... mklabel/mkpart/rm/resizepart` |
| Fork bomb | `:(){ :\|:& };:` |
| chmod 777 | `chmod -R 777 /`, `chmod -R 777 ~` |
| Force-push | `git push --force/-f/--force-with-lease` to main/master/production/prod, or with no branch named |
| Wrapped payloads | any of the above inside `bash -c`/`sh -c`/`eval` |

**Test:** `bash tests/test-guard-hooks.sh`

### `safety-warn.sh` (PreToolUse Edit\|Write, exit 0)

Soft warning on sensitive paths. Stderr is shown to Claude as a nudge; the Edit/Write proceeds.

Patterns warned:

- `*.env`, `*.env.*`
- `*credentials*`
- `*secret*.json`, `*secret*.yml`, `*secret*.yaml`
- `*.pem`, `*.key`, `*id_rsa*`, `*.p12`, `*.pfx`, `*.gpg`

Hard reads/writes to `~/.ssh/`, `~/.aws/`, `~/.gnupg/`, etc. are blocked by the deny rules in `settings.json` regardless of this hook.

### `log-tool-calls.sh pre|post` (PreToolUse `*` and PostToolUse `*`)

Append a JSONL row per tool call to `~/.claude/logs/tool-calls-YYYY-MM-DD.jsonl`. See `docs/LOGGING.md` for schema, query examples, and rotation policy.

### `log-rotate.sh` (SessionEnd)

Gzip-rotate today's log if it exceeds `CLAUDE_LOG_ROTATE_BYTES` (default 100 MB), prune logs older than `CLAUDE_LOG_RETAIN_DAYS` days (default 365).

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
