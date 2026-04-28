# Centralize Claude Code Config — Design Spec

- **Date:** 2026-04-26
- **Author:** mills (with Claude assistance)
- **Status:** Approved for implementation planning
- **Foundation:** Evolve existing repo `https://github.com/millsmillsymills/claude-defaults` (last updated 2026-02-23)

---

## 1. Problem

Claude Code configuration is scattered across:

- `~/.claude/settings.json` — only enabled-plugins list and `skipAutoPermissionPrompt: true`; no hooks, no permissions, no privacy defaults
- `~/.claude/skills/agent-browser/SKILL.md` — one custom skill, isolated
- 11 project `.claude/` directories — most with only `settings.local.json` (Claude Code-managed permission state)
- `resurgent/.claude/` — extremely mature setup (8 agents, 11 skills, 10 commands, custom hooks, templates, docs) but all homelab-specific
- `~/Desktop/Projects/claude-defaults/` — empty local directory; `git@github.com:millsmillsymills/claude-defaults` is a substantial 2-month-old config repo the user had forgotten about

Specifically missing from the global setup:
- No global hooks (no logging, no safety blocks, no anti-rationalization gate)
- No structured tool-call log; no MCP-aware logging
- No global permission deny rules for credentials, SSH keys, cloud config, crypto wallets
- No global statusline
- No global CLAUDE.md style guide
- No central place to add new global skills/commands/agents

## 2. Goals

1. **Single source of truth** at `~/Desktop/Projects/claude-defaults/`, git-tracked (existing GitHub remote)
2. **Global config inheritance** — every project gets safety hooks, logging, deny rules, style guide for free
3. **Per-project additivity preserved** — projects keep their own `.claude/` for project-specific hooks/permissions; resurgent's homelab-specific assets stay where they are
4. **Rich tool/MCP action logging** — JSONL log of every tool call with full args, full output (truncated at 1MB), redacted secrets, daily rotation
5. **Layered safety** — hard blocks for catastrophic ops, soft warnings for sensitive edits, anti-rationalization Stop hook
6. **No regression** — preserve everything currently working in `~/.claude/settings.json` (plugin list, `skipAutoPermissionPrompt`)
7. **Bootstrap on a new machine in one command**

## 3. Non-Goals

- Promoting any agents/skills/commands from `resurgent/.claude/` to global. All resurgent assets reference homelab-specific paths (`/mnt/user/`, `toolkit/`, docker compose) and are correctly project-scoped.
- Replacing per-project `.claude/settings.local.json` permission state.
- Capturing user prompts or model responses in logs (only tool I/O).
- Building a custom Claude Code plugin (rejected during brainstorming as wrong tradeoff for personal-config velocity).
- Creating a sync daemon or background process.

## 4. Foundation: Evolve, Don't Replace

The existing `millsmillsymills/claude-defaults` GitHub repo (last commit 2026-02-23) already contains ~80% of the target design. We adopt it wholesale and layer on the missing pieces.

**Preserved as-is from existing repo:**
- `settings.json` (privacy env vars, deny rules, `enableAllProjectMcpServers: false`, `alwaysThinkingEnabled`, `cleanupPeriodDays: 365`, `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS`, two existing PreToolUse hooks)
- `scripts/install.sh` (idempotent, jq-merging installer)
- `scripts/validate.sh`
- `scripts/statusline.sh` (two-line bar with model/folder/branch/context%/cost/duration/cache-hit-rate)
- `claude-md-template.md` (Python/TypeScript/Rust style guide; we extend with Go and the comprehensive sections from this brainstorm)
- `mcp-template.json` (Context7 + Exa)
- `hooks/block-rm-rf.sh`, `hooks/block-push-main.sh`, `hooks/enforce-package-manager.sh`, `hooks/log-bash-commands.sh`
- `commands/review-pr.md`, `commands/fix-issue.md`, `commands/merge-dependabot.md`
- `README.md` (extensive; we extend it with logging + new hooks documentation)
- `LICENSE`, `.gitignore`

**Reconciled with current `~/.claude/settings.json` during install:**
- `enabledPlugins` block (23 plugins from 3 marketplaces) — preserved via `jq` merge in `install.sh`
- `extraKnownMarketplaces` — preserved via merge
- `skipAutoPermissionPrompt: true` — preserved via merge

## 5. Final Repo Layout

```
~/Desktop/Projects/claude-defaults/             (git remote: millsmillsymills/claude-defaults)
├── README.md                                   # EXTENDED: + logging section, new hooks
├── LICENSE                                     # unchanged
├── .gitignore                                  # unchanged
├── settings.json                               # EXTENDED: + hooks block referencing new scripts
├── claude-md-template.md                       # EXTENDED: + Go section, output preferences,
│                                               #   comments policy, terse-output rules
├── mcp-template.json                           # unchanged
├── scripts/
│   ├── install.sh                              # EXTENDED: hybrid mode (symlink + jq-merge),
│   │                                           #   per-skill skill symlinks, log dir creation
│   ├── uninstall.sh                            # NEW: reverses install, restores from backup
│   ├── validate.sh                             # EXTENDED: verify symlinks, hook executability,
│   │                                           #   log dir, hook script JSON-input contract
│   └── statusline.sh                           # unchanged
├── hooks/
│   ├── block-rm-rf.sh                          # unchanged
│   ├── block-push-main.sh                      # unchanged
│   ├── enforce-package-manager.sh              # unchanged (still optional)
│   ├── log-bash-commands.sh                    # unchanged (still optional, kept for back-compat)
│   ├── safety-block.sh                         # NEW: expanded destructive-pattern blocks
│   ├── safety-warn.sh                          # NEW: soft warn on sensitive Edit/Write
│   ├── log-tool-calls.sh                       # NEW: PreToolUse + PostToolUse * → JSONL
│   ├── log-rotate.sh                           # NEW: SessionEnd rotate/prune
│   │                                           # (anti-rationalization is a `type: "prompt"`
│   │                                           #  hook in settings.json — no script file)
│   └── lib/
│       ├── jsonl-write.py                      # NEW: atomic JSON-line append, truncation
│       ├── redact.py                           # NEW: secret-pattern redaction
│       └── common.sh                           # NEW: shared bash helpers (cwd, session_id parse)
├── commands/
│   ├── review-pr.md                            # unchanged
│   ├── fix-issue.md                            # unchanged
│   └── merge-dependabot.md                     # unchanged
├── agents/                                     # NEW (empty): scaffold for future global agents
├── skills/                                     # NEW (empty): scaffold for future global skills
├── docs/
│   ├── superpowers/
│   │   └── specs/
│   │       └── 2026-04-26-centralize-claude-config-design.md   # this file
│   ├── HOOKS.md                                # NEW: every hook documented; matcher cheatsheet
│   ├── LOGGING.md                              # NEW: schema, jq query examples, rotation,
│   │                                           #   redaction patterns
│   └── PROMOTION-RATIONALE.md                  # NEW: why nothing promoted from resurgent
└── tests/
    ├── run-all.sh                              # NEW: runs the four test scripts
    ├── test-install.sh                         # NEW: install/uninstall in isolated $HOME
    ├── test-hooks.sh                           # NEW: per-hook input/exit-code/log assertions
    ├── test-redaction.sh                       # NEW: secret-pattern redaction coverage
    ├── test-settings-valid.sh                  # NEW: JSON parse + hook-path existence
    └── fixtures/
        ├── tool-input-bash-safe.json
        ├── tool-input-bash-rmrf.json
        ├── tool-input-edit-env.json
        ├── tool-input-edit-normal.json
        ├── tool-input-mcp-call.json
        └── ...
```

## 6. Distribution Mechanism: Hybrid

| Target in `~/.claude/` | Mechanism |
|---|---|
| `CLAUDE.md` | symlink → `<repo>/claude-md-template.md` (rendered + sourced; user can swap to a personalized rendered file later) |
| `settings.json` | **jq-merge** (NOT symlink) — preserves machine-specific entries; merge runs on every `install.sh`; existing config backed up first |
| `commands/<each>.md` | **per-file symlink** — `<repo>/commands/<name>.md` → `~/.claude/commands/<name>.md` |
| `hooks/<each>.sh` | **per-file symlink** — `<repo>/hooks/<name>.sh` → `~/.claude/hooks/<name>.sh` |
| `hooks/lib/<each>` | **per-file symlink** |
| `agents/<each>.md` | **per-file symlink** (none initially; scaffold) |
| `skills/<each-name>/` | **per-skill directory symlink** — `<repo>/skills/<name>/` → `~/.claude/skills/<name>/` (preserves existing `~/.claude/skills/agent-browser/` untouched) |
| `statusline.sh` | symlink → `<repo>/scripts/statusline.sh` |
| `logs/` | **real directory created by install.sh**; never a symlink (machine-local data) |

**Rationale for hybrid:**
- `settings.json` jq-merge preserves the current `enabledPlugins` (23 entries), `extraKnownMarketplaces`, `skipAutoPermissionPrompt: true`, and any future machine-specific additions
- Per-file symlinks (vs. parent-directory symlinks) allow Claude Code's plugin-installed commands/skills/hooks to coexist in the same parent directories
- Per-skill directory symlinks specifically preserve `~/.claude/skills/agent-browser/`
- All hook scripts symlinked → editing the script in either repo or `~/.claude/hooks/` is the same edit; no reload needed (next tool call subprocess-invokes the updated script)

**Bootstrap behavior** (`install.sh` evolves to support this):
1. Backup `~/.claude/CLAUDE.md`, `~/.claude/settings.json`, `~/.claude/statusline.sh`, all existing files in `~/.claude/{hooks,commands,agents}/` to `~/.claude/backups/pre-claude-defaults-YYYYMMDD-HHMMSS-PID/`
2. For `settings.json`: jq-merge `<repo>/settings.json` over current; output to `~/.claude/settings.json` as a real file (not symlink)
3. For everything else: create symlinks (per spec above), removing existing entries first if they're regular files or differently-targeted symlinks
4. Create `~/.claude/logs/` as a real directory if missing
5. `chmod +x` on all `<repo>/hooks/*.sh` and `<repo>/scripts/statusline.sh` so symlinked targets are executable
6. Print a final checklist of every link created with its target; exit non-zero on any failure

## 7. Components

### 7.1 Settings — `settings.json`

Existing block fully preserved. Additions:

```jsonc
{
  // ... all existing keys preserved ...
  "hooks": {
    "PreToolUse": [
      // existing block-rm-rf and block-push-main inline hooks PRESERVED
      {
        "matcher": "Bash",
        "hooks": [
          { "type": "command", "command": "$HOME/.claude/hooks/safety-block.sh" }
        ]
      },
      {
        "matcher": "Edit|Write",
        "hooks": [
          { "type": "command", "command": "$HOME/.claude/hooks/safety-warn.sh" }
        ]
      },
      {
        "matcher": "*",
        "hooks": [
          { "type": "command", "command": "$HOME/.claude/hooks/log-tool-calls.sh pre" }
        ]
      }
    ],
    "PostToolUse": [
      {
        "matcher": "*",
        "hooks": [
          { "type": "command", "command": "$HOME/.claude/hooks/log-tool-calls.sh post" }
        ]
      }
    ],
    "Stop": [
      {
        "hooks": [
          {
            "type": "prompt",
            "prompt": "Review the assistant's final response. Reject it if the assistant is rationalizing incomplete work. Common patterns: claiming issues are 'pre-existing' or 'out of scope' to avoid fixing them, saying there are 'too many issues' to address all of them, deferring work to a 'follow-up' that was not requested, listing problems without fixing them and calling that done, or skipping test/lint failures with excuses. If the response shows any of these patterns, respond {\"ok\": false, \"reason\": \"You are rationalizing incomplete work. [specific issue]. Go back and finish.\"}. If the work is genuinely complete, respond {\"ok\": true}."
          }
        ]
      }
    ],
    "SessionEnd": [
      {
        "hooks": [
          { "type": "command", "command": "$HOME/.claude/hooks/log-rotate.sh" }
        ]
      }
    ]
  },
  "permissions": {
    // ... existing deny block PRESERVED ...
    "allow": [
      // Generic baseline (Go added; no homelab-specific entries):
      "Bash(rg:*)", "Bash(grep:*)", "Bash(sed:*)", "Bash(awk:*)", "Bash(jq:*)", "Bash(yq:*)",
      "Bash(fd:*)", "Bash(bat:*)", "Bash(eza:*)", "Bash(ls:*)", "Bash(cat:*)", "Bash(head:*)",
      "Bash(tail:*)", "Bash(wc:*)", "Bash(sort:*)", "Bash(uniq:*)", "Bash(tr:*)", "Bash(cut:*)",
      "Bash(realpath:*)", "Bash(basename:*)", "Bash(dirname:*)", "Bash(which:*)", "Bash(env)",
      "Bash(printenv:*)", "Bash(pwd)", "Bash(test:*)", "Bash([:*)", "Bash(date)",
      "Bash(git:*)", "Bash(gh:*)",
      "Bash(python3:*)", "Bash(uv:*)", "Bash(ruff:*)", "Bash(ty:*)", "Bash(pytest:*)",
      "Bash(node:*)", "Bash(npx:*)", "Bash(pnpm:*)", "Bash(oxlint:*)", "Bash(oxfmt:*)", "Bash(vitest:*)",
      "Bash(go:*)", "Bash(gofmt:*)", "Bash(golangci-lint:*)",
      "Bash(cargo:*)", "Bash(rustc:*)", "Bash(clippy:*)",
      "Bash(shellcheck:*)", "Bash(shfmt:*)", "Bash(actionlint:*)", "Bash(zizmor:*)", "Bash(prek:*)",
      "Bash(make:*)", "Bash(trash:*)"
    ]
  }
}
```

### 7.2 Logging — `hooks/log-tool-calls.sh`

Fires on `PreToolUse *` (with arg `pre`) and `PostToolUse *` (with arg `post`). Captures every tool call including all `mcp__*` invocations.

**Output:** `~/.claude/logs/tool-calls-YYYY-MM-DD.jsonl`, one JSON object per line.

**Schema:**
```jsonc
// Pre-call row
{
  "ts": "2026-04-26T13:04:11.482Z",
  "session_id": "abc123",
  "cwd": "/Users/mills/Desktop/Projects/foo",
  "event": "pre",
  "call_id": "1714137851482000-7421",
  "tool": "Bash",
  "mcp_server": null,           // parsed from mcp__<server>__<method> tool names
  "args": { "command": "git status" }   // FULL args (rich logging — user opted in)
}
// Post-call row
{
  "ts": "2026-04-26T13:04:11.612Z",
  "session_id": "abc123",
  "cwd": "/Users/mills/Desktop/Projects/foo",
  "event": "post",
  "call_id": "1714137851482000-7421",
  "tool": "Bash",
  "mcp_server": null,
  "exit_status": 0,
  "duration_ms": 130,
  "output": { "stdout": "On branch main\n...", "stderr": "" }   // FULL output, capped at 1MB
}
```

**Implementation:**
- Reads Claude Code hook JSON input from stdin (per Claude Code hook contract)
- Bash wrapper extracts `tool_name`, `tool_input`, `tool_response`, `session_id`, `cwd` via `jq`
- Resolves its own location via `SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"` so `lib/` lookups work whether the script is invoked through `~/.claude/hooks/` (symlink) or directly from `<repo>/hooks/`
- Calls `lib/redact.py` to strip secrets from args/output strings
- Calls `lib/jsonl-write.py` to write the JSON line atomically
- `call_id` for matching pre→post: nanosecond timestamp + PID
- Pre-call writes `${TMPDIR}/claude-tool-${call_id}` containing start time; post-call reads + deletes for duration
- All log writes wrapped in `|| true` — logging failure NEVER breaks a tool call
- MCP-aware: `mcp_server` field parsed from tools matching `^mcp__([^_]+(?:_[^_]+)*?)__`

**Truncation:** lines exceeding 1MB get `output.stdout` and `output.stderr` truncated with `..._truncated_bytes: N` markers. Threshold configurable via `CLAUDE_LOG_MAX_LINE_BYTES` env var (default 1048576).

### 7.3 Log rotation — `hooks/log-rotate.sh`

Fires on `SessionEnd`. Two operations:

1. If today's `tool-calls-YYYY-MM-DD.jsonl` exceeds `CLAUDE_LOG_ROTATE_BYTES` (default 100 MB), gzip-rotate to `tool-calls-YYYY-MM-DD.jsonl.<N>.gz` (where `<N>` is next available integer)
2. Delete any `tool-calls-*.jsonl*` files older than `CLAUDE_LOG_RETAIN_DAYS` (default 90 days)

Both thresholds documented in the script header and `docs/LOGGING.md`.

### 7.4 Redaction — `hooks/lib/redact.py`

Patterns applied to all string values in `args` and `output` before write:

- `(password|passwd|secret|token|api[_-]?key|bearer|authorization)\s*[:=]\s*\S+` → value replaced with `***`
- JWT shape `eyJ[A-Za-z0-9_-]+\.eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+` → `***JWT***`
- AWS access keys `AKIA[0-9A-Z]{16}` → `***AWS_KEY***`
- GitHub tokens `gh[opsu]_[A-Za-z0-9]{36}` → `***GH_TOKEN***`
- Anthropic keys `sk-ant-[A-Za-z0-9_-]+` → `***ANTHROPIC_KEY***`
- OpenAI keys `sk-[A-Za-z0-9]{48}` → `***OPENAI_KEY***`
- CLI flag values `--password=…`, `--token=…`, `--secret=…`, `--api-key=…` → flag value replaced

A complementary one-off tool `scripts/redact-existing-logs.py` (NOT auto-installed; run manually) lets the user re-redact older logs if a new pattern is added.

### 7.5 Safety hooks

**`hooks/safety-block.sh`** (PreToolUse, matcher `Bash`, hard-block exit 2):
Patterns blocked (in addition to the existing `block-rm-rf.sh` and `block-push-main.sh`):
- `rm -rf /`, `rm -rf /Users`, `rm -rf ~`, `rm -rf $HOME`, `rm -rf $HOME/.*`
- `dd of=/dev/disk*`, `dd of=/dev/sd*`, `dd of=/dev/nvme*`, `dd of=/dev/r?disk*`
- `mkfs.*`, `wipefs`, `fdisk` writes, `parted` writes
- Fork bombs (`:(){ :|:& };:` pattern)
- `chmod -R 777 /`, `chmod -R 777 ~`
- `sudo rm -rf` anything
- `git push --force` / `-f` to `main` / `master` / `production` / `prod` (broader than existing `block-push-main.sh`, which only catches `git push <remote> main`)

All patterns documented in `docs/HOOKS.md` so they're greppable + testable.

**`hooks/safety-warn.sh`** (PreToolUse, matcher `Edit|Write`, exits 0 with stderr warning):
Patterns warned (deny rules in `settings.json` already block read/write of these via Claude's tools; this hook adds a visible nudge for any path the deny rule misses):
- `*.env`, `*.env.*`, `*credentials*`, `*.pem`, `*.key`, `*id_rsa*`, `*.p12`, `*/secrets.{json,yml,yaml}`
- Warning text: `"WARNING: editing a sensitive-looking file. Verify it's in .gitignore. Never hardcode secrets — use env vars or a secrets manager."`

### 7.6 Anti-rationalization Stop hook

Wired up by default as a `type: "prompt"` hook in `settings.json` — no script file needed (Claude Code dispatches the prompt to a fast model directly). Prompt text from existing README example, used verbatim. Sends Claude's final response to a fast model (Haiku) which returns `{"ok": false, "reason": "..."}` to force continuation, or `{"ok": true}` to allow stop. See `settings.json` block in §7.1.

### 7.7 CLAUDE.md — `claude-md-template.md`

Existing template preserved (Python/uv/ruff/ty, TypeScript/oxlint/oxfmt/vitest, Rust/clippy/cargo deny/cargo careful, Bash, GitHub Actions, philosophy, code quality, testing). Extensions:

1. **New section: Go** (added between Rust and Bash)
   - Runtime: latest stable Go via `gobrew` or system install
   - Toolchain: `go fmt`, `go vet`, `golangci-lint`, `go test ./... -race -count=1`
   - Style: standard `go fmt` (no opinions); table-driven tests; never panic in libraries; wrap errors with `%w`
   - Dependency management: pinned via `go.sum`; `go mod tidy` after dep changes
2. **New subsection in Workflow: Output preferences**
   - Terse responses; no trailing summaries; no preamble
   - One-sentence updates between tool calls
   - No emojis unless explicitly requested
   - Match response shape to task complexity
3. **New subsection in Code Quality: Comments policy**
   - Default to no comments
   - Add only when WHY is non-obvious (hidden constraint, subtle invariant, workaround)
   - Never narrate WHAT (well-named identifiers do that)
   - Never reference task/fix/callers ("used by X", "added for Y" — belongs in PR description)
4. **Pointer footer:** explicit reference to `~/Desktop/Projects/claude-defaults/docs/HOOKS.md` and `LOGGING.md` so a future Claude session can self-discover the local infra

### 7.8 Statusline — `scripts/statusline.sh`

Unchanged. Symlinked to `~/.claude/statusline.sh`. `settings.json` already references it.

### 7.9 Commands

Existing three (`/review-pr`, `/fix-issue`, `/merge-dependabot`) preserved. Each becomes a per-file symlink at `~/.claude/commands/`.

No commands promoted from resurgent (rationale in `docs/PROMOTION-RATIONALE.md`).

### 7.10 Skills

`<repo>/skills/` starts empty. Per-skill symlink strategy is fully scaffolded in `install.sh` so dropping a new directory into `<repo>/skills/<name>/` and re-running `install.sh` symlinks it into `~/.claude/skills/<name>/`. Existing `~/.claude/skills/agent-browser/` is untouched (it lives as a real directory; install.sh skips any skill name that already exists as a non-symlink).

### 7.11 Agents

`<repo>/agents/` starts empty. Same per-file symlink scaffold as commands.

No agents promoted from resurgent. Compound-engineering and pr-review-toolkit plugins already cover generic agent equivalents.

### 7.12 MCP — `mcp-template.json`

Unchanged. Install.sh continues to substitute `EXA_API_KEY` from env (or remove `exa` server entry if env var absent).

## 8. Data Flow

**Session start:**
1. Claude Code reads `~/.claude/settings.json` (real file, jq-merged) → loads `enabledPlugins`, `permissions`, `hooks`, env vars
2. Reads `~/.claude/CLAUDE.md` (symlink to `<repo>/claude-md-template.md`) → loaded into system prompt
3. Reads `~/.claude/skills/*/SKILL.md` (mix of symlinks to repo and real dirs like `agent-browser`)
4. Project `.claude/settings.local.json` and project `CLAUDE.md` overlay (Claude Code's existing layering — unchanged)
5. Statusline script (`~/.claude/statusline.sh` symlink) invoked on each render

**Per tool call:**
1. Claude Code dispatches a tool call (e.g., `Bash`)
2. **PreToolUse `*`** fires → `log-tool-calls.sh pre`: parses stdin JSON (Claude Code's hook input contract), generates `call_id`, writes `${TMPDIR}/claude-tool-${call_id}`, redacts args, appends pre-row JSONL
3. **PreToolUse `Bash`** fires (in order): existing `block-rm-rf.sh` inline, existing `block-push-main.sh` inline, then `safety-block.sh` (extended patterns). Any one exiting 2 cancels the call and feeds rejection to Claude
4. **PreToolUse `Edit|Write`** fires → `safety-warn.sh`: stderr warning if sensitive path, exits 0
5. Tool executes
6. **PostToolUse `*`** fires → `log-tool-calls.sh post`: reads start time from temp file, redacts output, truncates if > 1MB, appends post-row JSONL, deletes temp file

**Session end:**
1. **Stop** hook (prompt-type) fires → fast-model judges if response is rationalizing incomplete work. Rejection forces continuation; approval allows stop.
2. **SessionEnd** fires → `log-rotate.sh`: gzip-rotate today's log if > 100 MB; delete logs older than 90 days

**Inheritance:**
- Project `.claude/settings.local.json` can add additional hooks (Claude Code merges)
- Project can override a global hook by re-defining the same matcher entry (project beats global)
- Project `permissions` overlay on global `permissions`

## 9. Error Handling

| Failure | Behavior |
|---|---|
| `~/.claude/logs/` missing | `log-tool-calls.sh` runs `mkdir -p` on first call (idempotent) |
| Disk full while writing log | `jsonl-write.py` catches `OSError(ENOSPC)`, drops line, exits 0 — never breaks tool call |
| Malformed Claude hook input JSON | `jq` failures handled with `// null` fallbacks; missing fields substituted with `null` |
| Hook script crashes (syntax error, missing dep) | Settings.json command spec wraps in shell; hook exits non-zero → Claude sees stderr but tool proceeds (PostToolUse cannot block; PreToolUse blocks only on exit 2 specifically) |
| `safety-block.sh` false positive | User edits the script directly; symlink means edit takes effect on next tool call (no reload) |
| Symlink target moved/deleted | `validate.sh` re-checks every link; broken links print to stderr, exit 1 |
| Concurrent sessions writing same log file | `jsonl-write.py` uses `os.O_APPEND` single-syscall write of one JSON line; atomic on macOS APFS for line sizes ≤ 1 MB (the truncation cap) |
| Backup collision (running install twice in same second) | Backup dir name includes PID: `pre-claude-defaults-20260426-130411-7421/` |
| Existing `~/.claude/skills/agent-browser/` (non-symlink dir) | Per-skill strategy: install.sh iterates `<repo>/skills/*` and skips any name that exists as a non-symlink dir; logs the skip. `agent-browser` survives untouched. |
| User edits a hook script | Next tool call subprocess-invokes the updated script; no reload needed |
| `settings.json` syntax error after merge | `validate.sh` runs `python3 -m json.tool < ~/.claude/settings.json`; `install.sh` validates the merged result before atomic-rename in place |
| Existing `~/.claude/CLAUDE.md` has user customizations | install.sh backs up to `~/.claude/backups/...` before symlinking; user can manually merge their customizations into `<repo>/claude-md-template.md` |
| Secret accidentally captured pre-redaction | Patterns documented in `docs/LOGGING.md`; `scripts/redact-existing-logs.py` (one-off) re-redacts existing files |
| `lib/redact.py` regex catastrophic backtracking | Patterns explicitly bounded; CI test `test-redaction.sh` includes adversarial inputs with timeout assertions |

## 10. Testing

**Automated** (`tests/run-all.sh`):

1. **`test-install.sh`** — uses `HOME=$(mktemp -d)`; runs `install.sh`; asserts:
   - All expected symlinks exist and `readlink` returns expected target
   - `settings.json` is a real file (not symlink) and parses as valid JSON
   - `~/.claude/logs/` is a real directory
   - All hook scripts (via symlink target) are executable
   - Backup directory created if any conflicting source files were present
   - Running `install.sh` a second time is idempotent (no extra backups, no broken links)
   - `uninstall.sh` restores backup correctly and removes only repo-installed symlinks

2. **`test-hooks.sh`** — for each hook script, parametrized cases:
   - `safety-block.sh`: feed 15+ dangerous commands → all exit 2 with rejection text; feed 10+ safe commands → all exit 0
   - `safety-warn.sh`: sensitive paths → stderr warning present, exit 0; normal paths → no warning, exit 0
   - `log-tool-calls.sh pre|post`: feed mock Claude hook JSON inputs → assert JSONL line written matches expected schema (validated via `python3 -c "import json; json.loads(...)"` and field-presence checks)
   - `log-rotate.sh`: pre-create a >100 MB log file (sparse via `truncate`) → assert it's gzipped after run; pre-create a 91-day-old log → assert deleted
   - Existing `block-rm-rf.sh` and `block-push-main.sh`: regression tests for existing patterns

3. **`test-redaction.sh`** — feed strings containing JWTs, AWS keys, GitHub tokens, Anthropic keys, OpenAI keys, `password=foo`, `--token=bar`, `Authorization: Bearer xyz` → assert all redacted in output. Includes adversarial regex inputs with 5s timeout to detect catastrophic backtracking.

4. **`test-settings-valid.sh`** — `python3 -m json.tool < settings.json` (parse check); verify every hook script path referenced in `settings.json` exists in `<repo>/hooks/` and is executable.

**Manual smoke** (added to README.md):

1. `./scripts/install.sh --dry-run` — review output
2. `./scripts/install.sh` — apply
3. Open a fresh Claude Code session in any project
4. Issue tool calls (Read, Bash echo, Edit a tmp file, an MCP call)
5. `tail -f ~/.claude/logs/tool-calls-$(date +%Y-%m-%d).jsonl` in another terminal — confirm pre/post pairs appear, MCP calls captured with `mcp_server` field populated, output truncation marker appears for large outputs
6. `Bash: rm -rf /tmp/this-should-not-exist-xyz` — confirm `safety-block.sh` rejects (Claude shows the rejection)
7. `Edit: /tmp/test.env` — confirm warning printed but Edit proceeds
8. `./scripts/uninstall.sh` — confirm `~/.claude/` restored from backup

**CI** (optional `.github/workflows/test.yml`): runs `tests/run-all.sh` on push using `macos-latest` runner. Skip if user doesn't want CI noise.

## 11. Migration / Rollout

Detailed step list lives in the implementation plan (writing-plans phase). Top-level shape:

1. Clone GitHub repo over the empty local directory (preserve this spec)
2. Add new files (hooks, lib, tests, docs) in a feature branch
3. Extend existing files (`settings.json`, `claude-md-template.md`, `scripts/install.sh`, `scripts/validate.sh`, `README.md`)
4. Write `scripts/uninstall.sh`
5. Run `tests/run-all.sh` against isolated `$HOME`
6. Run `./scripts/install.sh --dry-run` against real `$HOME`; review
7. Run `./scripts/install.sh` for real; verify with `./scripts/validate.sh`
8. Open a smoke-test session, exercise hooks/logging
9. Commit + push to GitHub
10. (Future, optional) per-machine override: a `~/.claude/CLAUDE.local.md` (gitignored, real file not symlink) for personal facts the user doesn't want in the public repo

## 12. Open Questions / Future Work

- **Anti-rationalization tuning**: The Stop-hook prompt may produce false-positive rejections on tasks with legitimate scope deferrals. If it gets in the way, revise the prompt to allow explicit "out of scope, captured at <link>" patterns.
- **Cross-machine sync**: Symlinked repo means `git pull` updates live config instantly. If user adds a second machine, they clone repo to same path and run `install.sh` again. Multi-machine drift (machine-specific allowlist additions in `settings.json`) is handled by the merge being one-way (repo → `~/.claude/`); user manually adds machine-specific entries to repo when desired.
- **Plugin enable list drift**: `enabledPlugins` is currently in `~/.claude/settings.json`. After merge, it lives there permanently (not in repo). If user wants the plugin list version-controlled, they can move it into `<repo>/settings.json` later. Out of scope for this iteration.
- **Project `.claude/` cleanup**: Most projects have only Claude Code-managed `settings.local.json` (auto-permission state). Once global config provides good defaults, those files mostly become "delete and let Claude Code recreate". Not done as part of this — user can prune incrementally.
- **resurgent generalization**: Some resurgent skills (gen-test, security-scan, dependency-audit) could be made generic in a future pass. Captured in `docs/PROMOTION-RATIONALE.md` as future-work candidates.

## 13. Decisions Made During Brainstorming

| Decision | Choice | Rationale |
|---|---|---|
| Distribution mechanism | Hybrid: symlinks for content, jq-merge for `settings.json` | Preserves machine-specific entries (plugin list); live edits for content |
| Logging tier | Tier-2 rich: full args, full output (1MB cap), redaction | User opted in; not concerned about disk |
| Layering vs project | Global = baseline, project = additive | Resurgent stays homelab-specific |
| Safety stance | Block destructive + warn sensitive | Existing repo's deny rules + new soft warns |
| Global CLAUDE.md content | Comprehensive style guide | Existing template + Go + output/comments policy |
| What to promote from resurgent | Nothing initially | All homelab-specific; plugins cover generic equivalents |
| CLAUDE.md languages | Python, TS, Rust (existing), + Go (added) | Don't drop Rust template; Go used actively |
| Anti-rationalization Stop hook | Wired up by default | User chose default-on |
| Foundation | Evolve existing GitHub repo | ~80% of design already exists, proven |
