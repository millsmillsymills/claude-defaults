# Hooks Reference

Every hook installed by claude-defaults, what it does, and how to test it. The hooks live at `hooks/*.sh` in this repo and are symlinked into `~/.claude/hooks/` by `scripts/install.sh`.

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

Blocks `git push <remote> main` or `git push <remote> master`. Does NOT cover force-push or production branches — that's `safety-block.sh`'s job.

### `safety-block.sh` (PreToolUse Bash, exit 2)

Hard-blocks broader destructive patterns:

| Category | Pattern |
|---|---|
| `rm -rf` against root/home | `rm -rf /`, `rm -rf /Users/...`, `rm -rf ~`, `rm -rf $HOME...` |
| sudo rm -rf | any `sudo rm -rf ...` |
| dd to disk devices | `dd of=/dev/disk*`, `/dev/sd*`, `/dev/nvme*`, `/dev/rdisk*` |
| Filesystem ops | `mkfs.*`, `wipefs ...` |
| Partition ops | `fdisk -w`, `parted /dev/... mklabel/mkpart/rm/resizepart` |
| Fork bomb | `:(){ :\|:& };:` |
| chmod 777 | `chmod -R 777 /`, `chmod -R 777 ~` |
| Force-push variants | `git push --force/-f/--force-with-lease ... main/master/production/prod` |

**Test:** `bash tests/test-hooks.sh` (covers 16 block + 9 allow cases)

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

Gzip-rotate today's log if it exceeds `CLAUDE_LOG_ROTATE_BYTES` (default 100 MB), prune logs older than `CLAUDE_LOG_RETAIN_DAYS` days (default 90).

### `enforce-package-manager.sh` (optional, PreToolUse Bash)

Blocks `npm` commands when the cwd contains `pnpm-lock.yaml` or `yarn.lock`. **NOT wired up by default** — opt in by adding it to `settings.json` if you want strict enforcement.

### `log-bash-commands.sh` (optional, PostToolUse Bash)

Plain-text Bash command audit log to `~/.claude/bash-commands.log`. **NOT wired up by default** — superseded by the structured `log-tool-calls.sh`. Kept for back-compat / simple use.

### Anti-rationalization Stop hook (`type: "prompt"`)

Inline prompt-type hook in `settings.json`. Sends Claude's final response to a fast model that returns `{"ok": false, "reason": "..."}` or `{"ok": true}`. If rejected, Claude must continue.

To tune: edit the `prompt` field in `settings.json` `hooks.Stop[0].hooks[0]`.

## Adding your own hook

1. Create `hooks/<name>.sh` (or `.py`)
2. Make it executable: `chmod +x hooks/<name>.sh`
3. Re-run `./scripts/install.sh hooks` (creates the symlink at `~/.claude/hooks/<name>.sh`)
4. Reference it in `settings.json` under the appropriate event/matcher
5. Re-run `./scripts/install.sh settings` to merge the updated hooks block
6. Restart any active Claude Code session for the new hook to fire
