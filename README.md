# claude-defaults

Claude Code configuration defaults. Covers sandboxing, permissions, hooks, skills, MCP servers, and usage patterns we've found effective across security audits, development, and research.

## Sibling workspaces

`claude-defaults` is the global config repo. For domain-specific Claude Code work, four sibling workspace-defaults repos extend the same install pattern:

| Repo | Active folder | Purpose |
|---|---|---|
| `claude-plugin-dev-defaults` | `~/Desktop/Projects/claude-plugin-dev/` | Claude Code plugin development |
| `claude-skill-dev-defaults`  | `~/Desktop/Projects/claude-skill-dev/`  | Standalone skill development |
| `mcp-server-dev-defaults`    | `~/Desktop/Projects/mcp-server-dev/`    | MCP server development (Python/Go/TS) |
| `agent-sdk-dev-defaults`     | `~/Desktop/Projects/agent-sdk-dev/`     | Claude Agent SDK app development |

Each enables a specialized plugin set on top of the global 10. See the spec at `docs/superpowers/specs/2026-05-20-claude-dev-setup-optimization-design.md` and the implementation plan at `docs/superpowers/plans/2026-05-20-claude-dev-setup-optimization.md`.

## First-time setup

```bash
git clone https://github.com/millsmillsymills/claude-defaults.git
cd claude-defaults
./scripts/install.sh          # Install all components
./scripts/validate.sh         # Verify installation
```

The install script is idempotent and uses a hybrid model: `settings.json` is jq-merged in place (preserves your existing `enabledPlugins`, `extraKnownMarketplaces`, and `skipAutoPermissionPrompt`); everything else (`CLAUDE.md`, `commands/`, `hooks/`, `hooks/lib/`, `agents/`, `skills/`, `statusline.sh`) is symlinked into `~/.claude/` so edits in either place take effect immediately. Skills are symlinked per-skill so existing non-symlink skills (like `agent-browser`) survive untouched. The first install backs up any conflicting files to `~/.claude/backups/pre-claude-defaults-<ts>/`.

Use `--dry-run` to preview changes, `--force` to overwrite foreign symlinks, or pass specific components (`settings`, `mcp`, `claude-md`, `statusline`, `commands`, `hooks`, `agents`, `skills`, `logs-dir`). Run `./scripts/uninstall.sh` to reverse the install (removes our symlinks, restores latest backup).

For manual setup or selective installation, see the sections below.

## Shell Setup

Add to `~/.zshrc` (or `~/.bashrc`):

```bash
alias claude-yolo="claude --dangerously-skip-permissions"
```

`--dangerously-skip-permissions` bypasses all permission prompts. This is the recommended way to run Claude Code for maximum throughput -- pair it with sandboxing (below).

If you're using local models, also add:

```bash
claude-local() {
  ANTHROPIC_BASE_URL=http://localhost:1234 \
  ANTHROPIC_AUTH_TOKEN=lmstudio \
  CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 \
  claude --model qwen/qwen3-coder-next "$@"
}
```

`claude-local` wraps claude with the local server env vars and disables telemetry pings that won't reach Anthropic anyway. Use it anywhere you'd normally run `claude`.

## Settings

Copy `settings.json` to `~/.claude/settings.json` (or merge entries into your existing file). The `$schema` key enables autocomplete and validation in editors that support JSON Schema. The template includes:

- **env (privacy)** -- disables three non-essential outbound streams: Statsig telemetry (`DISABLE_TELEMETRY`), Sentry error reporting (`DISABLE_ERROR_REPORTING`), and feedback surveys (`CLAUDE_CODE_DISABLE_FEEDBACK_SURVEY`). Avoid the umbrella `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC` -- it also disables auto-updates.
- **env (agent teams)** -- `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS` enables multi-agent teams where one session coordinates multiple teammates with independent context windows. Experimental -- known limitations around session resumption and task coordination.
- **enableAllProjectMcpServers: false** -- this is the default, set explicitly so it doesn't get flipped by accident. Project `.mcp.json` files live in git, so a compromised repo could ship malicious MCP servers.
- **alwaysThinkingEnabled: true** -- persists extended thinking across sessions. Toggle per-session with Option+T. Adds latency and cost on simple tasks; worth it for complex reasoning.
- **permissions** -- deny rules that block reading credentials/secrets and editing shell config (see [Sandboxing](#sandboxing))
- **cleanupPeriodDays: 365** -- keeps conversation history for a year instead of the default 30 days, so `/insights` has more data
- **hooks** -- two PreToolUse hooks on Bash that block `rm -rf` and direct push to main (see [Hooks](#hooks))
- **statusLine** -- points to the statusline script (see below)

## Statusline

A two-line status bar at the bottom of the terminal:

```
 [Opus 4.6] 📁 claude-defaults │ 🌿 main
 ████⣿⣿⣿⣿⣿⣿⣿⣿ 28% │ $0.83 │ ⏱ 12m 34s ↻89%
```

Line 1 shows the model, current folder, and git branch. Line 2 shows a visual context usage bar (color-coded: green <50%, yellow 50-79%, red 80%+), session cost, elapsed time, and prompt cache hit rate.

Copy the script:

```bash
mkdir -p ~/.claude
cp scripts/statusline.sh ~/.claude/statusline.sh
chmod +x ~/.claude/statusline.sh
```

The `statusLine` entry in `settings.json` points to this script. Requires `jq`.

## Global CLAUDE.md

The global `CLAUDE.md` file at `~/.claude/CLAUDE.md` sets default instructions for every Claude Code session. It covers development philosophy (no speculative features, no premature abstraction, replace don't deprecate), code quality hard limits (function length, complexity, line width), language-specific toolchains for Python (uv, ruff, ty), Node/TypeScript (oxlint, vitest), Rust (clippy, cargo deny), Bash, and GitHub Actions, plus testing methodology, code review order, and workflow conventions (commits, hooks, PRs).

Copy the template into place:

```bash
cp claude-md-template.md ~/.claude/CLAUDE.md
```

Review and customize it for your own preferences. The template is opinionated -- adjust the language sections, tool choices, and hard limits to match your stack. For background on how CLAUDE.md files work (hierarchy, auto memory, modular rules, imports), see [Manage Claude's memory](https://docs.anthropic.com/en/docs/claude-code/memory).

---

## Configuration

### Sandboxing

We run Claude Code in bypass-permissions mode (`--dangerously-skip-permissions`). This means you need to understand your sandboxing options -- the agent will execute commands without asking, so the sandbox is what keeps it from doing damage.

#### Built-in sandbox (/sandbox)

Claude Code has a native sandbox that provides filesystem and network isolation using OS-level primitives (Seatbelt on macOS, bubblewrap on Linux). Enable it by typing `/sandbox` in a session. In auto-allow mode, Bash commands that stay within sandbox boundaries run without permission prompts.

**Default behavior:** Writes are restricted to the current working directory and its subdirectories. Reads are unrestricted -- the agent can still read `~/.ssh`, `~/.aws`, etc. Network access is limited to explicitly allowed domains.

**Hardening reads:** The `settings.json` template includes Read and Edit deny rules that block access to credentials and secrets:

- **SSH/GPG keys** -- `~/.ssh/**`, `~/.gnupg/**`
- **Cloud credentials** -- `~/.aws/**`, `~/.azure/**`, `~/.kube/**`, `~/.docker/config.json`
- **Package registry tokens** -- `~/.npmrc`, `~/.npm/**`, `~/.pypirc`, `~/.gem/credentials`
- **Git credentials** -- `~/.git-credentials`, `~/.config/gh/**`
- **Shell config** -- `~/.bashrc`, `~/.zshrc` (edit denied, prevents backdoor planting)
- **macOS keychain** -- `~/Library/Keychains/**`
- **Crypto wallets** -- metamask, electrum, exodus, phantom, solflare app data

Without `/sandbox`, deny rules only block Claude's built-in tools -- Bash commands bypass them. With `/sandbox` enabled, the same rules are enforced at the OS level (Seatbelt/bubblewrap), so Bash commands are also blocked. Use both.

For the design rationale behind sandboxing, see [Anthropic's engineering blog post](https://www.anthropic.com/engineering/claude-code-sandbox). For the full configuration reference, see the [sandboxing docs](https://docs.anthropic.com/en/docs/claude-code/security#sandbox).

### Hooks

Hooks are shell commands (or LLM prompts) that fire at specific points in Claude Code's lifecycle. They are a way to talk to the LLM at decision points it wouldn't otherwise pause at. Every PreToolUse hook is a chance to say "stop, think about this" or "don't do that, do this instead." Every PostToolUse hook is a chance to say "now that you did that, here's what you should know." Every Stop hook is a chance to say "you're not done yet."

This is more powerful than system prompt instructions alone because hooks fire at specific, contextual moments. An instruction in your CLAUDE.md saying "never use rm -rf" can be forgotten or overridden by context pressure. A PreToolUse hook that blocks `rm -rf` fires every single time, with the error message right at the point of decision.

Hooks are not a security boundary -- a prompt injection can work around them. They are structured prompt injection at opportune times: intercepting tool calls, injecting context, blocking known-bad patterns, and steering agent behavior. Guardrails, not walls.

In practice, use them to:

- **Block known-bad patterns** -- `rm -rf`, push to main, wrong package manager
- **Add your own logging** -- audit trails, bash command logs, mutation tracking
- **Nudge Claude to keep going** -- a Stop hook can review Claude's final response and force it to continue if it's rationalizing incomplete work
- **Inject context at decision points** -- post-write lint results, pre-tool security warnings

Guide and examples: [Automate workflows with hooks](https://docs.anthropic.com/en/docs/claude-code/hooks)

#### Hook events

| Event | When it fires | Can block? |
|-------|---------------|------------|
| PreToolUse | Before a tool call executes | Yes |
| PostToolUse | After a tool call succeeds | No (already ran) |
| UserPromptSubmit | When user submits a prompt | Yes |
| Stop | When Claude finishes responding | Yes (forces continue) |
| SessionStart | When a session begins/resumes | No |
| SubagentStart/Stop | When a subagent spawns/finishes | Start: no, Stop: yes |
| TaskCompleted | When a task is marked complete | Yes |
| TeammateIdle | When a teammate is about to idle | Yes |

#### Exit codes

| Exit code | Behavior |
|-----------|----------|
| 0 | Action allowed (stdout parsed for JSON control) |
| 1 | Error, non-blocking (stderr shown in verbose mode) |
| 2 | Blocking error (stderr fed back to Claude as error message) |

#### Examples

These are patterns to adapt, not drop-in configs. Only the two blocking hooks in `settings.json` are recommended defaults. Everything else below is here for inspiration -- read the code, understand what it does, and tailor it to your workflow before using it.

**Blocking patterns** (PreToolUse, in settings.json): The two hooks in this repo's `settings.json` block `rm -rf` (suggests trash instead) and direct push to main/master (requires feature branches). Both read the Bash command from stdin via jq, match with regex, and exit 2 with an error message that tells Claude what to do instead. See `hooks/block-rm-rf.sh` and `hooks/block-push-main.sh`.

**Desktop notifications** (Notification): Fires a native OS notification when Claude needs your attention, so you can switch to other work during long autonomous runs instead of watching the terminal.

```json
{
  "Notification": [
    {
      "matcher": "",
      "hooks": [
        {
          "type": "command",
          "command": "osascript -e 'display notification \"Claude needs your attention\" with title \"Claude Code\"'"
        }
      ]
    }
  ]
}
```

On Linux, replace the command with `notify-send 'Claude Code' 'Claude needs your attention'`.

**Enforce package manager** (PreToolUse): `hooks/enforce-package-manager.sh` blocks npm commands in projects that use pnpm and tells Claude to use the right tool. Generalizes to any "use X not Y" convention.

**Anti-rationalization gate** (Stop, prompt hook): Claude has a tendency to declare victory while leaving work undone. It rationalizes skipping things: "these issues were pre-existing," "fixing this is out of scope," "I'll leave these for a follow-up." A prompt-based Stop hook catches this by asking a fast model to review Claude's final response for cop-outs before allowing it to stop.

```json
{
  "Stop": [
    {
      "hooks": [
        {
          "type": "prompt",
          "prompt": "Review the assistant's final response. Reject it if the assistant is rationalizing incomplete work. Common patterns: claiming issues are 'pre-existing' or 'out of scope' to avoid fixing them, saying there are 'too many issues' to address all of them, deferring work to a 'follow-up' that was not requested, listing problems without fixing them and calling that done, or skipping test/lint failures with excuses. If the response shows any of these patterns, respond {\"ok\": false, \"reason\": \"You are rationalizing incomplete work. [specific issue]. Go back and finish.\"}. If the work is genuinely complete, respond {\"ok\": true}."
        }
      ]
    }
  ]
}
```

This uses `type: "prompt"` instead of `type: "command"` -- Claude Code sends the hook's prompt plus the assistant's response to a fast model (Haiku), which returns a yes/no judgment. If rejected, the reason is fed back to Claude as its next instruction, forcing it to continue.

---

## Logging

Every tool call (including all `mcp__*` invocations) is captured to a structured JSONL log via `hooks/log-tool-calls.sh`, fired on `PreToolUse *` and `PostToolUse *`. The log includes full tool args and output (capped at 1 MB per line, with a truncation marker), timing, exit status, and the parsed MCP server name when applicable.

- **Where:** `~/.claude/logs/tool-calls-YYYY-MM-DD.jsonl`
- **Schema, query examples, redaction rules, rotation:** [`docs/LOGGING.md`](docs/LOGGING.md)
- **Rotation:** `hooks/log-rotate.sh` runs on `SessionEnd` — gzip-rotates files >100 MB, prunes files >365 days old (long retention supports cross-session `/ce` analytics)
- **Redaction:** secrets stripped before write — JWTs, AWS/GitHub/Anthropic/OpenAI keys, `password=`, `token=`, etc. Patterns in `hooks/lib/redact.py`

Logging never breaks a tool call: write failures (disk full, missing dir, malformed JSON) are silently dropped.

## Anti-rationalization

A `Stop` hook of `type: "prompt"` (configured in `settings.json`) reviews Claude's final response with a fast model and forces continuation if Claude is rationalizing incomplete work ("out of scope," "pre-existing," "follow-up," etc.). Tune the prompt in `settings.json`'s `hooks.Stop[0].hooks[0].prompt` if it's too strict or too lax.

## Plugins and Skills

Claude Code's capabilities come from plugins, which provide skills (reusable workflows), agents (specialized subagents), and commands (slash commands). Plugins are distributed through marketplaces.

### agent-browser skill

The agent-browser CLI ships its own marketplace with a first-party skill that teaches Claude the snapshot/ref workflow, command syntax, session management, authentication flows, video recording, and proxy support. agent-browser is new enough that it's not in the model's pretraining data -- without this skill, Claude won't know the ref lifecycle or command API.

```
/plugin marketplace add vercel-labs/agent-browser
/plugin install agent-browser@agent-browser
```

### Superpowers (obra/superpowers)

Workflow discipline -- enforces planning before coding, structured debugging, and verification before declaring victory. The skills chain together: brainstorm -> plan -> execute -> verify.

| Skill | What it does | When to use it |
|-------|-------------|----------------|
| `/superpowers:brainstorm` | Refines ideas through Socratic questioning before implementation | Starting any non-trivial feature -- catches unclear requirements early |
| `/superpowers:systematic-debugging` | Structured 4-phase root cause analysis | Any bug where the cause isn't obvious -- prevents treating symptoms |

### Anthropic Official (anthropics/claude-code/plugins)

Official plugins maintained in the Claude Code repo. Install via the `claude-plugins-official` marketplace.

| Skill | What it does | When to use it |
|-------|-------------|----------------|
| `frontend-design` | Auto-invoked on frontend tasks with guidance on bold design, typography, animations, and visual polish -- avoids generic AI aesthetics | Building web components, pages, or applications where visual quality matters |
| `/pr-review-toolkit:review-pr` | Runs 6 specialized agents in parallel: comments, tests, error handling, type design, code quality, and code simplification | PR review -- run with `all` or pick specific aspects (`simplify`, `tests`, `errors`, etc.) |

The code-simplifier agent inside pr-review-toolkit can also be targeted individually with `/pr-review-toolkit:review-pr simplify` for a focused simplification pass.

### Compound Engineering (EveryInc/compound-engineering-plugin)

Multi-agent workflows for planning and review.

| Skill | What it does | When to use it |
|-------|-------------|----------------|
| `/workflows:plan` | Turns feature descriptions into implementation plans with parallel research agents | Starting a feature that touches multiple files or components |
| `/workflows:review` | Runs 15 specialized review agents in parallel (security, performance, architecture, style) | Before merging any significant PR -- catches what solo review misses |

---

## MCP Servers

Set up at least Context7 and Exa as global MCP servers.

| Server | What it does | Requirements |
|--------|-------------|--------------|
| Context7 | Up-to-date library documentation lookup | None (no API key) |
| Exa | Web and code search | `EXA_API_KEY` env var (get one at [exa.ai](https://exa.ai)) |

### Setup

MCP servers are configured in `.mcp.json` files. Claude Code merges configs from two locations:

- `~/.mcp.json` -- global servers available in every session
- `.mcp.json` in the project root -- project-specific servers

Copy `mcp-template.json` from this repo to `~/.mcp.json` for global availability. Replace `your-exa-api-key-here` with your actual key, or remove the exa entry if you don't have one. Add project-specific MCP servers (e.g., a local database tool) to the project's `.mcp.json`.

---

## Commands

Custom slash commands are markdown files that define parameterized procedures. They take arguments, run a specific sequence of steps, and produce a result. Once a workflow is a command, it's something an agent can run too.

```bash
mkdir -p ~/.claude/commands
cp commands/review-pr.md ~/.claude/commands/
cp commands/fix-issue.md ~/.claude/commands/
cp commands/merge-dependabot.md ~/.claude/commands/
```

### Review PR

`commands/review-pr.md` -- Reviews a GitHub PR with parallel agents, fixes findings, and pushes. Invoke with `/review-pr 456` where 456 is the PR number.

### Fix Issue

`commands/fix-issue.md` -- Takes a GitHub issue and autonomously completes it -- researches, plans, implements, tests, creates a PR, self-reviews, and comments on the issue when done. Invoke with `/fix-issue 123` where 123 is the issue number.

### Merge Dependabot

`commands/merge-dependabot.md` -- Evaluates and merges open Dependabot PRs for a repo. Audits dependabot config, builds a transitive dependency map, batches overlapping PRs, evaluates each in parallel, and merges passing PRs sequentially with post-merge re-testing. Invoke with `/merge-dependabot owner/repo`.

---

## Project-level CLAUDE.md

For each project you work on, add a `CLAUDE.md` at the repo root with project-specific context. The global `CLAUDE.md` sets defaults; the project file layers on what's unique to this codebase. A good project `CLAUDE.md` includes architecture (directory tree, key abstractions), build and test commands, codebase navigation patterns, domain-specific APIs and gotchas, and testing conventions.

---

## File structure

```
claude-defaults/
├── README.md                       # This file
├── LICENSE
├── settings.json                   # Global settings template (merged into ~/.claude/settings.json)
├── mcp-template.json               # MCP server config template
├── claude-md-template.md           # Global CLAUDE.md template (Python/TS/Rust/Go/Bash/GH Actions)
├── scripts/
│   ├── install.sh                  # Hybrid installer (--dry-run, --force, components)
│   ├── uninstall.sh                # Reverse install, restore backup
│   ├── validate.sh                 # Verify symlinks, log dir, hooks wired
│   └── statusline.sh               # Two-line terminal status bar
├── hooks/
│   ├── block-rm-rf.sh              # legacy: block rm -rf (active)
│   ├── block-push-main.sh          # legacy: block push to main (active)
│   ├── enforce-package-manager.sh  # opt-in: enforce pnpm/yarn
│   ├── safety-block.sh             # NEW: extended destructive-pattern blocks (active)
│   ├── safety-warn.sh              # NEW: warn on sensitive Edit/Write (active)
│   ├── log-tool-calls.sh           # NEW: rich JSONL log of every tool call (active)
│   ├── log-rotate.sh               # NEW: SessionEnd gzip+prune (active)
│   └── lib/
│       ├── _log_core.py            # shared patterns + truncation + atomic append
│       ├── redact.py               # secret-pattern redaction CLI (uses _log_core)
│       ├── jsonl_write.py          # atomic JSONL append + truncation CLI
│       └── log_tool_call.py        # consolidated pre/post logger (uses _log_core)
├── commands/
│   ├── review-pr.md                # /review-pr <number>
│   ├── fix-issue.md                # /fix-issue <number>
│   └── merge-dependabot.md         # /merge-dependabot <owner/repo>
├── agents/                         # scaffold for global agents (empty)
├── skills/                         # scaffold for global skills (empty)
├── docs/
│   ├── HOOKS.md                    # every hook documented
│   ├── LOGGING.md                  # log schema, queries, rotation
│   └── PROMOTION-RATIONALE.md      # what was/wasn't promoted from resurgent
└── tests/
    ├── run-all.sh                  # dispatcher
    ├── test-install.sh             # install/uninstall roundtrip
    ├── test-hooks.sh               # per-hook assertions
    ├── test-redaction.sh           # secret-pattern coverage
    ├── test-settings-valid.sh      # JSON parse + hook path checks
    └── fixtures/                   # mock Claude hook stdin inputs
```
