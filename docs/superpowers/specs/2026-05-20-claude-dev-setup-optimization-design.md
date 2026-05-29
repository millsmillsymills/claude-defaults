# Claude Code Dev Setup Optimization — Design

**Date:** 2026-05-20
**Status:** Approved (pending Codex review)
**Owner:** mills

## Problem

The current Claude Code setup loads 22 plugins globally on every session, regardless of whether the session is editing a Python MCP server, drafting a blog post, or triaging Sonarr config. The global tool surface is wide enough that context, latency, and tool-search noise all suffer in unrelated work. Specialized plugins (`plugin-dev`, `skill-creator`, `mcp-server-dev`, `agent-sdk-dev`, three language LSPs, `frontend-design`, `playwright`) load everywhere they're not needed.

At the same time, several intentional dev domains — Claude plugin development, skill development, MCP server development, Agent SDK app development — have no dedicated workspace. MCP server projects (`gandi-mcp`, `protonmail-mcp`, `unifi-mcp`, `unraid-mcp`) live as peers to unrelated repos in `~/Desktop/Projects/`, with no shared CLAUDE.md or config-as-code scaffolding.

This design rationalizes the global plugin/MCP set and stands up four new meta-dev workspaces, each modeled on the existing `claude-defaults` config-repo pattern.

## Goals

1. Cut the globally-loaded plugin set from 22 to 10 (9 from the existing official marketplace + Matt Pocock skills once added), keeping only what genuinely applies to every session.
2. Stand up four new meta-dev workspaces (`claude-plugin-dev`, `claude-skill-dev`, `mcp-server-dev`, `agent-sdk-dev`) using the `claude-defaults` install-and-symlink pattern.
3. Establish a three-tier MCP scope policy (global / workspace / project) and place every MCP at the right tier.
4. Migrate the four existing MCP server projects into the new `mcp-server-dev` workspace.
5. Add two missing pieces: Exa MCP (global search) and Matt Pocock's skills (global skills marketplace).

## Non-goals

- Reworking `claude-defaults` itself. It already works; new workspaces are *siblings*, not replacements.
- Changing the hook/safety machinery (`block-rm-rf.sh`, `safety-block.sh`, etc.). Those stay global.
- Touching unrelated project directories (`Sonarr`, `resurgent`, `millsymills.com`, etc.).
- Publishing the new workspace-defaults repos to GitHub. They start as local-only; publication is a follow-up.

## Architecture

### The pattern

Each meta-dev workspace is two things:

1. **Config repo** at `~/Desktop/Projects/<workspace>-defaults/` — owns CLAUDE.md, settings.json, .mcp.json, install scripts. Mirrors `claude-defaults`'s structure.
2. **Active dev folder** at `~/Desktop/Projects/<workspace>/` — hosts the actual sub-projects (cloned plugins, MCP server repos, skill directories). Its `.claude/` and `CLAUDE.md` are symlinks back to the config repo.

```
~/Desktop/Projects/
├── claude-defaults/                    ← existing, untouched
├── claude-plugin-dev-defaults/         ← new config repo
├── claude-plugin-dev/                  ← new active folder (sub-projects live here)
│   ├── CLAUDE.md   → ../claude-plugin-dev-defaults/CLAUDE.md
│   ├── .mcp.json   → ../claude-plugin-dev-defaults/.mcp.json (if present; project-scope MCP lives at repo root)
│   ├── .claude/
│   │   └── settings.json  → ../../claude-plugin-dev-defaults/settings.json
│   ├── <plugin-A>/
│   └── <plugin-B>/
├── claude-skill-dev-defaults/
├── claude-skill-dev/
├── mcp-server-dev-defaults/
├── mcp-server-dev/
│   ├── gandi-mcp/                      ← migrated from ~/Desktop/Projects/
│   ├── protonmail-mcp/
│   ├── unifi-mcp/
│   └── unraid-mcp/
├── agent-sdk-dev-defaults/
└── agent-sdk-dev/
```

### Why symlinks (not file copies)

Same reasoning as `claude-defaults`: edits in either place take effect immediately, no drift, no install-step required after every change. The install script is idempotent and supports `--dry-run` and `--force`.

### Why a config-repo per workspace (not profiles in one repo)

Independent evolution: `mcp-server-dev` may add Go tooling that `claude-skill-dev` shouldn't see. Independent publishability: if a workspace turns out to be broadly useful, it can be open-sourced without dragging the others along. Cost is small — each repo is ~10 files copied from a template.

## Global trim

### Plugins to keep global (9)

| Plugin | Reason |
|---|---|
| `superpowers` | Universal workflow skills (brainstorming, TDD, plans, code review). |
| `codex` | Cross-cutting; codex rescue applies to any task. |
| `code-review` | Used in every PR review. |
| `code-simplifier` | Used in every codebase. |
| `pr-review-toolkit` | Applies to every repo with PRs. |
| `claude-md-management` | Every repo benefits from CLAUDE.md maintenance. |
| `github` | Every repo uses GitHub. |
| `commit-commands` | Universal commit workflow. |
| `pyright-lsp` | Enough projects touch Python that loading globally is justified. |

Plus, once available: `matt-pocock-skills` (global skills marketplace — installation details below).

### Plugins to demote (13)

Removed from `~/.claude/settings.json` `enabledPlugins`; re-enabled per workspace where applicable:

| Plugin | Destination |
|---|---|
| `plugin-dev` | `claude-plugin-dev` workspace |
| `skill-creator` | `claude-skill-dev` + `claude-plugin-dev` workspaces |
| `mcp-server-dev` | `mcp-server-dev` workspace |
| `agent-sdk-dev` | `agent-sdk-dev` workspace |
| `typescript-lsp` | `mcp-server-dev`, `agent-sdk-dev`, `claude-plugin-dev` |
| `gopls-lsp` | `mcp-server-dev` (Go MCP servers) |
| `frontend-design` | Disabled by default; enable per-repo for frontend work |
| `playwright` | Disabled by default; enable per-repo where browser automation is used |
| `security-guidance` | Disabled globally; enable in `security-research/` if desired |
| `feature-dev` | Disabled globally; enable per-repo when starting a multi-step feature |
| `claude-code-setup` | `claude-plugin-dev` workspace (and rare manual use) |
| `ralph-loop` | Disabled globally; enable per-repo when running long-loop automation |
| `context7` (plugin) | Replaced by global `context7` MCP entry (deduplicate) |

### Note on `context7` deduplication

`context7` is currently enabled twice: as a plugin and as a project-scope MCP (`Projects/.claude/settings.local.json` under `enabledMcpjsonServers`). The plugin and the MCP serve the same purpose. Final state: one entry only, in `~/.claude.json` `mcpServers`. Both the plugin enable and the project-scope MCP entry get removed.

## MCP scope policy

Three tiers, applied consistently:

### Global MCPs (`~/.claude.json` → `mcpServers`)

Always available, on every session:

| MCP | Purpose | Already global? |
|---|---|---|
| `aws-mcp` | AWS CLI / docs | Yes |
| `gandi` | Domains, DNS | Yes |
| `protonmail` | Mail | Yes |
| `context7` | Library docs (promote from project-scope) | No — adding |
| `exa` | Web search via Exa AI | No — adding |

### Workspace MCPs (`<workspace>/.mcp.json` at workspace root)

None planned at design time. Slot reserved — workspace plugins (`mcp-server-dev`, `agent-sdk-dev`, etc.) carry their own tooling, so no workspace-scoped MCPs are needed initially. Note: project-scope MCP config in Claude Code lives at the *repo root* (`<dir>/.mcp.json`), not under `.claude/`.

### Project MCPs (`<repo>/.mcp.json`)

Project-specific only, at the repo root. Examples: a test instance of `gandi-mcp` itself for integration tests; the `Sonarr` repo pointing at its local Sonarr API. Enable via `enabledMcpjsonServers` in `.claude/settings.local.json`.

### Pyright resolution

The user's initial framing included "pyright" as a global MCP. Pyright is an LSP, surfaced through the `pyright-lsp` plugin (not an MCP). Final placement: `pyright-lsp` stays globally enabled (decision above), because enough projects touch Python that demoting it would cause more friction than it saves. No separate "pyright MCP" exists or needs to exist.

## Per-workspace configuration

Each workspace's `settings.json` enables the specialized plugin set. Disable directives target the *global* enabled list so the demoted plugins only re-enter scope inside the matching workspace.

| Workspace | Plugins enabled | MCPs added | Notes |
|---|---|---|---|
| `claude-plugin-dev` | `plugin-dev`, `skill-creator`, `claude-code-setup`, `typescript-lsp` | none | Plugins are often TS/JS, so typescript-lsp is included. |
| `claude-skill-dev` | `skill-creator` | none | Skills are mostly markdown; no LSP needed. |
| `mcp-server-dev` | `mcp-server-dev`, `typescript-lsp`, `gopls-lsp` | none | `pyright-lsp` already global. Hosts gandi/protonmail/unifi/unraid MCPs. |
| `agent-sdk-dev` | `agent-sdk-dev`, `typescript-lsp` | none | `pyright-lsp` already global. |

CLAUDE.md per workspace inherits global `~/.claude/CLAUDE.md` and adds workspace-specific guidance (e.g. plugin testing commands, skill structure conventions).

## Matt Pocock skills installation

Upstream `mattpocock/skills` does not currently ship a `.claude-plugin/marketplace.json` (tracked in [Issue #21](https://github.com/mattpocock/skills/issues/21); PR #41 proposes the fix). Until upstream merges marketplace support:

- **Stopgap:** install the `dstroe2000/mattpocock_skills` fork via `/plugin marketplace add dstroe2000/mattpocock_skills` then `/plugin install mattpocock@mattpocock-skills`. The fork repackages Matt's skills 1:1 with marketplace metadata.
- **Pin the fork.** In `extraKnownMarketplaces`, pin the source to a specific commit SHA (not just `main`). Otherwise an upstream fork-owner change ships silently into every session.
- **Drift check.** Add a monthly reminder (calendar / cron / Ralph loop) to `git diff` the fork against upstream `mattpocock/skills` and surface any non-marketplace changes for review.
- **Switch trigger:** when `mattpocock/skills` merges PR #41 (or equivalent), swap the fork out for upstream in `extraKnownMarketplaces`.

The marketplace entry lives in `~/.claude/settings.json` under `extraKnownMarketplaces` (same place as `claude-plugins-official` and `openai-codex`).

## Migration plan

Ordered for independent reversibility. Each step is verified before moving on.

### Step 1 — Snapshot
- `cp ~/.claude/settings.json ~/.claude/backups/pre-trim-2026-05-20.json`
- `cp ~/.claude.json ~/.claude.json.pre-trim-2026-05-20`
- `cd ~/Desktop/Projects/claude-defaults && git status` — commit anything outstanding.

### Step 2 — Add missing globals
- Add `exa` MCP to `~/.claude.json` (`mcpServers.exa`). Source `EXA_API_KEY` from `~/.zshrc` or 1Password; do not commit the key.
- Add `dstroe2000/mattpocock_skills` to `extraKnownMarketplaces` in `~/.claude/settings.json`. Run `/plugin install mattpocock@mattpocock-skills`.
- Promote `context7` MCP from `~/Desktop/Projects/.claude/settings.local.json` to `~/.claude.json` `mcpServers`. Remove the project-scope entry. Disable `context7` plugin in global `enabledPlugins`.

### Step 3 — Verify demotion mechanism
Per Claude Code's settings precedence (project `settings.json` overrides user, `.claude/settings.local.json` overrides project), setting `"enabledPlugins": {"plugin-dev@claude-plugins-official": false}` at project scope *should* suppress a globally-enabled plugin. Still verify empirically before relying on it:

- Pick a known-good plugin (e.g. `plugin-dev`) currently enabled globally.
- Add a project-scope `.claude/settings.json` with that plugin set to `false`.
- Open a session, confirm the plugin's commands/agents/skills are absent.

- **If verified:** workspaces only need to *re-enable* specific plugins; the demoted plugins remain enabled globally (so plugin tooling stays available everywhere by default) but get explicitly disabled inside any workspace that doesn't need them. Actually — simpler path: remove demoted plugins from global `enabledPlugins` and re-enable them only in workspaces that need them.
- **If empirically blocked:** the only working mechanism is removing from global and re-enabling per workspace. Use that.

Either way, Step 7 (global trim) is the actual disable. Step 3 is just confirming whether project-override works as a *future* override knob. Document the result in `claude-defaults/docs/`.

### Step 4 — Stand up `claude-plugin-dev-defaults` first
Lowest risk: no in-flight plugin work to disrupt.

- Create `~/Desktop/Projects/claude-plugin-dev-defaults/` from `claude-defaults` template (copy structure, blank out specifics).
- Author workspace-specific `CLAUDE.md` and `settings.json`.
- Create `~/Desktop/Projects/claude-plugin-dev/` and run the install script.
- Verify install: symlinks resolve, install script's `--dry-run` shows no surprises, `validate.sh` (or equivalent) passes. The "doesn't load elsewhere" assertion is checked in Step 7 after global trim — at this point `plugin-dev` still loads globally.

### Step 5 — Stand up remaining three workspaces
Repeat Step 4 for `claude-skill-dev`, `mcp-server-dev`, `agent-sdk-dev`. Each in its own day to keep cognitive load low.

### Step 6 — Migrate MCP server projects
**Preflight (all four repos before moving any):**
- `git status` and `git worktree list --porcelain` per repo. Resolve any dirty trees or in-flight worktrees first. As of 2026-05-20, `protonmail-mcp` has a non-clean worktree (`issue-76-persist-degraded`) — finish or stash before migration.
- Snapshot `~/.claude.json` again right before the move (Step 1's snapshot may be stale by now).

For each of `gandi-mcp`, `protonmail-mcp`, `unifi-mcp`, `unraid-mcp`:

1. Confirm clean tree + no active worktrees.
2. `mv ~/Desktop/Projects/<name>/ ~/Desktop/Projects/mcp-server-dev/<name>/`.
3. If the repo had worktrees alongside (e.g. `<name>.worktrees/`), `git worktree remove` each before the move, then re-create after — moving worktree directories doesn't update their internal `.git` references.
4. Rewrite the path keys in `~/.claude.json` using `jq` (project entries, per-project trust state, history references, `enabledMcpjsonServers` approvals). Do NOT use `sed` — keys may appear in nested contexts (trust state, history) that need structural rewrites.
   ```bash
   jq --arg old "/Users/mills/Desktop/Projects/<name>" \
      --arg new "/Users/mills/Desktop/Projects/mcp-server-dev/<name>" \
      'walk(if type == "string" and . == $old then $new else . end)' \
      ~/.claude.json > ~/.claude.json.new && mv ~/.claude.json.new ~/.claude.json
   ```
   Diff before saving.
5. Open a session at the new path, confirm tooling works (LSP, tests, MCP server runs).

### Step 7 — Trim global plugin set
- Edit `~/.claude/settings.json`: remove the 13 demoted plugins from `enabledPlugins` (set to `false` or omit).
- Open a session in a non-workspace folder (e.g. `~/Desktop/Projects/Sonarr/`). Confirm reduced tool surface.
- Open one in each new workspace. Confirm specialized plugins re-load.

### Step 8 — Document
- Update `~/Desktop/Projects/claude-defaults/README.md` with a "Sibling workspaces" section pointing at the four new repos.
- Cross-link each workspace's README back to `claude-defaults`.

## Risks

1. **Project-scope plugin disable may not work as documented.** Docs say it should; verify empirically (Step 3). Worst case: the design still works, just with a different toggle location (global remove + per-workspace re-enable).
2. **`~/.claude.json` is large (23 project entries plus cached state).** String references to the moved repos may appear in multiple nested keys (project entries, trust state, history, `enabledMcpjsonServers`). Mitigation: use `jq walk` (Step 6.4), not `sed`. Snapshot before, diff after, and inspect every changed line.
3. **Worktrees in any migrated repo carry stale `.git` references.** Not just `gandi-mcp` — run `git worktree list --porcelain` per repo before the move. Mitigation: `git worktree remove` each one before moving, recreate via `wt switch` after.
4. **Matt Pocock marketplace is via a third-party fork that floats.** Mitigation: pin to a specific commit SHA in `extraKnownMarketplaces`; periodically (monthly) `git diff` the fork against `mattpocock/skills` to confirm no divergence. Switch to upstream once PR #41 merges.
5. **`pyright-lsp` global is a judgment call.** If a future session in a non-Python repo shows noticeable overhead from the LSP, revisit and demote.
6. **Migration during in-flight work.** Don't migrate a repo while the user has uncommitted changes or active branches in worktrees. Step 6 preflight enforces this.

## Open questions

None blocking — listed for follow-up:

- Should `pr-review-toolkit` and `code-review` be consolidated? Both exist globally and may overlap.
- Long-term, should the four workspace-defaults repos be hoisted into a single `claude-workspace-defaults` umbrella once the pattern proves out? Defer until at least three workspaces have been used in anger.

## Verification

After the migration, the following should hold:

- `cat ~/.claude/settings.json | jq '.enabledPlugins | keys | length'` returns 10 (the 9 from the official marketplace + `matt-pocock-skills`).
- `cat ~/.claude.json | jq '.mcpServers | keys'` returns `["aws-mcp", "context7", "exa", "gandi", "protonmail"]`.
- A session opened in `~/Desktop/Projects/Sonarr/` sees only the 10 global plugins.
- A session opened in `~/Desktop/Projects/mcp-server-dev/gandi-mcp/` sees the 10 global plus `mcp-server-dev`, `typescript-lsp`, `gopls-lsp`.
- Existing project workflows (commits, PRs, code review) work unchanged.

## References

- `claude-defaults` repo: `~/Desktop/Projects/claude-defaults/` — the pattern these workspaces extend.
- [mattpocock/skills](https://github.com/mattpocock/skills) — upstream skills repo.
- [dstroe2000/mattpocock_skills](https://github.com/dstroe2000/mattpocock_skills) — fork with marketplace support.
- [mattpocock/skills Issue #21](https://github.com/mattpocock/skills/issues/21), [PR #41](https://github.com/mattpocock/skills/pull/41) — upstream marketplace tracking.
- Claude Code memory docs — settings precedence behavior the design relies on.
