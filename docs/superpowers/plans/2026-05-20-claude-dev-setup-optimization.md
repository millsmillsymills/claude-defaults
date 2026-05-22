# Claude Code Dev Setup Optimization Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Trim globally-loaded plugins from 22 to 10, stand up four new meta-dev workspaces (`claude-plugin-dev`, `claude-skill-dev`, `mcp-server-dev`, `agent-sdk-dev`) modeled on `claude-defaults`, rationalize MCP scope, migrate four existing MCP server repos, and add Exa MCP + Matt Pocock skills.

**Architecture:** Each workspace is a pair: a `<workspace>-defaults/` config repo (CLAUDE.md, settings.json, install.sh, validate.sh) and a `<workspace>/` active dev folder hosting sub-projects. Active folder's `CLAUDE.md`, `.claude/settings.json`, and (optionally) `.mcp.json` are symlinks back to the config repo. Global `~/.claude/settings.json` and `~/.claude.json` get trimmed and rewritten at the end so the system stays usable throughout.

**Tech Stack:** zsh, jq (JSON manipulation), git + git worktree, Claude Code's `/plugin` subcommands, ripgrep / fd / trash (per global CLAUDE.md tooling).

**Spec:** [2026-05-20-claude-dev-setup-optimization-design.md](../specs/2026-05-20-claude-dev-setup-optimization-design.md) — commit `f0e63c6` in `claude-defaults`.

---

## File Structure

**Created (per workspace, four times):**
- `~/Desktop/Projects/<workspace>-defaults/CLAUDE.md` — workspace-specific instructions
- `~/Desktop/Projects/<workspace>-defaults/settings.json` — template for the active folder's `.claude/settings.json`
- `~/Desktop/Projects/<workspace>-defaults/.mcp.json` — optional, per workspace (none initially)
- `~/Desktop/Projects/<workspace>-defaults/README.md`
- `~/Desktop/Projects/<workspace>-defaults/scripts/install.sh` — symlink installer (small, ~60 lines)
- `~/Desktop/Projects/<workspace>-defaults/scripts/validate.sh` — symlink verifier
- `~/Desktop/Projects/<workspace>-defaults/.gitignore`
- `~/Desktop/Projects/<workspace>/` — active dev folder (created by install.sh, plus symlinks)

**Modified (existing files):**
- `~/.claude/settings.json` — trim `enabledPlugins`; add `extraKnownMarketplaces.mattpocock-skills`
- `~/.claude.json` — add `mcpServers.exa`, `mcpServers.context7`; rewrite paths for four migrated MCP repos
- `~/Desktop/Projects/.claude/settings.local.json` — remove `enabledMcpjsonServers: ["context7"]`
- `~/Desktop/Projects/claude-defaults/README.md` — add "Sibling workspaces" section
- `~/Desktop/Projects/claude-defaults/docs/` — add demotion-mechanism findings file

**Moved:**
- `~/Desktop/Projects/{gandi,protonmail,unifi,unraid}-mcp/` → `~/Desktop/Projects/mcp-server-dev/{gandi,protonmail,unifi,unraid}-mcp/`
- Worktrees beside any of those repos (notably `gandi-mcp.worktrees/`) get rebuilt at the new location.

---

## Phase 1 — Snapshot & global additions

### Task 1: Snapshot current state

**Files:**
- Create: `~/.claude/backups/pre-trim-2026-05-20/`
- Create: `~/.claude/backups/pre-trim-2026-05-20/settings.json`
- Create: `~/.claude/backups/pre-trim-2026-05-20/dot-claude.json`
- Modify: `~/Desktop/Projects/claude-defaults/` (commit any uncommitted state)

- [ ] **Step 1: Create backup directory**

```bash
mkdir -p ~/.claude/backups/pre-trim-2026-05-20
```

- [ ] **Step 2: Snapshot `~/.claude/settings.json`**

```bash
cp ~/.claude/settings.json ~/.claude/backups/pre-trim-2026-05-20/settings.json
```

Verify:
```bash
diff -q ~/.claude/settings.json ~/.claude/backups/pre-trim-2026-05-20/settings.json
```
Expected: no output (files identical).

- [ ] **Step 3: Snapshot `~/.claude.json`** (large state file, not a config file)

```bash
cp ~/.claude.json ~/.claude/backups/pre-trim-2026-05-20/dot-claude.json
```

- [ ] **Step 4: Confirm `claude-defaults` working tree is clean**

```bash
cd ~/Desktop/Projects/claude-defaults
git status --short
```
Expected: empty output, or only `.context/` (untracked). If anything else is dirty, commit or stash before proceeding.

- [ ] **Step 5: Record snapshot in plan notes**

Append to `~/Desktop/Projects/claude-defaults/docs/superpowers/plans/2026-05-20-claude-dev-setup-optimization.md` a small "Execution log" section noting the snapshot timestamp (manual edit; no commit needed — this is operational).

---

### Task 2: Pin matt-pocock fork commit SHA

**Files:**
- Read: GitHub upstream `dstroe2000/mattpocock_skills` (no local change yet)

- [ ] **Step 1: Look up the fork's current `main` commit SHA**

```bash
gh api repos/dstroe2000/mattpocock_skills/commits/main --jq '.sha'
```
Expected: a 40-char SHA. Save it for Step 4 (and Task 3).

- [ ] **Step 2: Check fork is still in sync with upstream `mattpocock/skills`**

```bash
gh api repos/mattpocock/skills/commits/main --jq '.sha'
gh api repos/dstroe2000/mattpocock_skills/compare/main...mattpocock:main \
  --jq '{ahead_by, behind_by, total_commits}'
```
Expected: `behind_by: 0` (or very small). If `behind_by > 5`, the fork is stale — file an issue on the fork, or fall back to manual skill copy.

- [ ] **Step 3: Verify the fork has a marketplace.json**

```bash
gh api repos/dstroe2000/mattpocock_skills/contents/.claude-plugin/marketplace.json \
  --jq '.name' 2>&1
```
Expected: returns the file's encoded content, not "Not Found". If missing, the fork doesn't yet provide marketplace support — stop and reassess.

- [ ] **Step 4: Note the pin SHA in your scratch notes**

Record the SHA somewhere persistent (e.g. a note file in `~/.claude/`). Used in Task 3.

---

### Task 3: Add Matt Pocock skills marketplace and install plugin

**Files:**
- Modify: `~/.claude/settings.json` (add to `extraKnownMarketplaces`)

- [ ] **Step 1: Read current `extraKnownMarketplaces`**

```bash
jq '.extraKnownMarketplaces' ~/.claude/settings.json
```
Expected: object containing `claude-plugins-official`, `openai-codex`, `compound-engineering-plugin`. Confirm the schema.

- [ ] **Step 2: Add the pinned fork entry**

Replace `<PIN_SHA>` with the SHA captured in Task 2 Step 1.

```bash
SHA="<PIN_SHA>"
jq --arg sha "$SHA" '
  .extraKnownMarketplaces["mattpocock-skills"] = {
    "source": {
      "source": "github",
      "repo": "dstroe2000/mattpocock_skills",
      "ref": $sha
    }
  }
' ~/.claude/settings.json > ~/.claude/settings.json.new
```

- [ ] **Step 3: Diff and apply**

```bash
diff ~/.claude/settings.json ~/.claude/settings.json.new
```
Expected: only an addition under `extraKnownMarketplaces`. If anything else changed, abort.

```bash
mv ~/.claude/settings.json.new ~/.claude/settings.json
```

- [ ] **Step 4: Install the plugin inside Claude Code**

Open a Claude Code session in `~/Desktop/Projects/` and run:
```
/plugin marketplace add dstroe2000/mattpocock_skills
/plugin install mattpocock@mattpocock-skills
```
(or whatever the exact plugin name resolves to — `/plugin marketplace list` will show available installables.)

- [ ] **Step 5: Verify enabled**

```bash
jq '.enabledPlugins | with_entries(select(.key | test("matt|pocock"; "i")))' \
  ~/.claude/settings.json
```
Expected: one entry, set to `true`.

- [ ] **Step 6: Confirm skills are loaded**

In a new Claude Code session, run `/skills` (or check skill list). Matt Pocock's skills (`tdd`, `to-issues`, `to-prd`, `triage`, etc.) should appear.

---

### Task 4: Add Exa MCP to global `~/.claude.json`

**Files:**
- Modify: `~/.claude.json` (`mcpServers.exa`)
- Read: `~/.zshrc` or 1Password vault (for `EXA_API_KEY`)

- [ ] **Step 1: Confirm `EXA_API_KEY` is available in the environment**

```bash
echo "${EXA_API_KEY:-MISSING}"
```
If `MISSING`, fetch from 1Password (`op item get "Exa API Key" --reveal --field credential`) or your password manager. Add to `~/.zshrc` as `export EXA_API_KEY=...` (do NOT commit to any repo). Reload: `source ~/.zshrc`.

- [ ] **Step 2: Confirm `exa-mcp-server` runs**

```bash
EXA_API_KEY="$EXA_API_KEY" npx -y exa-mcp-server --help 2>&1 | head -5
```
Expected: usage text. If it errors, fix before continuing (likely Node version or npm cache).

- [ ] **Step 3: Add `mcpServers.exa` entry to `~/.claude.json`**

The MCP server reads `EXA_API_KEY` from its environment. We want the env var resolved at session-start time, not baked into the file. Use jq with the literal string `${EXA_API_KEY}`:

```bash
jq '.mcpServers.exa = {
  "command": "npx",
  "args": ["-y", "exa-mcp-server"],
  "env": {"EXA_API_KEY": "${EXA_API_KEY}"}
}' ~/.claude.json > ~/.claude.json.new
```

- [ ] **Step 4: Diff and apply**

```bash
diff <(jq '.mcpServers' ~/.claude.json) <(jq '.mcpServers' ~/.claude.json.new)
```
Expected: only an addition for `exa`. Then:
```bash
mv ~/.claude.json.new ~/.claude.json
```

- [ ] **Step 5: Verify in a new session**

Open a Claude Code session, run `/mcp` (or check MCP server list). `exa` should be listed and connected.

---

### Task 5: Promote `context7` from project-scope to global MCP

**Files:**
- Modify: `~/.claude.json` (add `mcpServers.context7`)
- Modify: `~/Desktop/Projects/.claude/settings.local.json` (remove `enabledMcpjsonServers: ["context7"]`)
- Modify: `~/.claude/settings.json` (set `enabledPlugins["context7@claude-plugins-official"]` to `false`)

- [ ] **Step 1: Add `context7` to global `mcpServers`**

```bash
jq '.mcpServers.context7 = {
  "command": "npx",
  "args": ["-y", "@upstash/context7-mcp"]
}' ~/.claude.json > ~/.claude.json.new
diff <(jq '.mcpServers' ~/.claude.json) <(jq '.mcpServers' ~/.claude.json.new)
mv ~/.claude.json.new ~/.claude.json
```

- [ ] **Step 2: Remove the project-scope context7 enable**

```bash
jq 'del(.enabledMcpjsonServers)' \
  ~/Desktop/Projects/.claude/settings.local.json \
  > ~/Desktop/Projects/.claude/settings.local.json.new
diff ~/Desktop/Projects/.claude/settings.local.json \
     ~/Desktop/Projects/.claude/settings.local.json.new
mv ~/Desktop/Projects/.claude/settings.local.json.new \
   ~/Desktop/Projects/.claude/settings.local.json
```

- [ ] **Step 3: Disable the `context7` plugin (deduplicate with the MCP)**

```bash
jq '.enabledPlugins["context7@claude-plugins-official"] = false' \
  ~/.claude/settings.json > ~/.claude/settings.json.new
diff ~/.claude/settings.json ~/.claude/settings.json.new
mv ~/.claude/settings.json.new ~/.claude/settings.json
```

- [ ] **Step 4: Verify**

Open a new Claude Code session. Confirm `context7` MCP loads (visible in `/mcp`) and the `context7` plugin's commands/agents are gone.

---

### Task 6: Verify project-scope plugin disable mechanism

**Files:**
- Create (temporary): `/tmp/plugin-disable-test/.claude/settings.json`

This is an empirical check. The outcome determines whether per-workspace `enabledPlugins: { ...: false }` works (preferred) or whether the only working mechanism is global-remove + per-workspace re-enable.

- [ ] **Step 1: Pick a victim plugin and confirm it's currently globally enabled**

```bash
jq '.enabledPlugins["plugin-dev@claude-plugins-official"]' ~/.claude/settings.json
```
Expected: `true`.

- [ ] **Step 2: Create a test directory with project-scope disable**

```bash
mkdir -p /tmp/plugin-disable-test/.claude
cat > /tmp/plugin-disable-test/.claude/settings.json <<'JSON'
{
  "enabledPlugins": {
    "plugin-dev@claude-plugins-official": false
  }
}
JSON
```

- [ ] **Step 3: Open a Claude Code session in `/tmp/plugin-disable-test/`**

Inside the session, ask Claude to list available agents:
```
/agents
```
Look for `plugin-dev:plugin-validator` and `plugin-dev:agent-creator`. If absent, project-scope disable works.

- [ ] **Step 4: Record the result**

Write the outcome to a new file:
```bash
cat > ~/Desktop/Projects/claude-defaults/docs/PLUGIN-SCOPE-FINDINGS.md <<'EOF'
# Plugin scope precedence (empirical, 2026-05-20)

**Question:** Does setting `enabledPlugins["X"] = false` in a project-scope
`.claude/settings.json` suppress a plugin enabled in `~/.claude/settings.json`?

**Result:** YES | NO  (fill in)

**Test method:** Created `/tmp/plugin-disable-test/.claude/settings.json` with
`plugin-dev@claude-plugins-official: false`. Opened a session there, checked
`/agents` for plugin-dev agents.

**Implication for design:** ...
EOF
```
Fill in `YES`/`NO` and the implication. Commit this file in `claude-defaults`.

- [ ] **Step 5: Clean up the test dir**

```bash
trash /tmp/plugin-disable-test
```

- [ ] **Step 6: Commit the findings**

```bash
cd ~/Desktop/Projects/claude-defaults
git add docs/PLUGIN-SCOPE-FINDINGS.md
git commit -m "Document empirical plugin scope precedence finding"
```

---

## Phase 2 — Scaffold first workspace (claude-plugin-dev)

### Task 7: Initialize `claude-plugin-dev-defaults` config repo

**Files:**
- Create: `~/Desktop/Projects/claude-plugin-dev-defaults/.git`
- Create: `~/Desktop/Projects/claude-plugin-dev-defaults/.gitignore`
- Create: `~/Desktop/Projects/claude-plugin-dev-defaults/README.md`
- Create: `~/Desktop/Projects/claude-plugin-dev-defaults/LICENSE` (copy from `claude-defaults`)

- [ ] **Step 1: Create the directory and init git**

```bash
mkdir -p ~/Desktop/Projects/claude-plugin-dev-defaults/scripts
cd ~/Desktop/Projects/claude-plugin-dev-defaults
git init -b main
```

- [ ] **Step 2: Write `.gitignore`**

Create `~/Desktop/Projects/claude-plugin-dev-defaults/.gitignore`:
```
.DS_Store
*.bak
*.tmp
.context/
```

- [ ] **Step 3: Copy the LICENSE from `claude-defaults`**

```bash
cp ~/Desktop/Projects/claude-defaults/LICENSE \
   ~/Desktop/Projects/claude-plugin-dev-defaults/LICENSE
```

- [ ] **Step 4: Write `README.md`**

Create `~/Desktop/Projects/claude-plugin-dev-defaults/README.md`:
```markdown
# claude-plugin-dev-defaults

Config repo for Claude Code plugin development. Sibling of
[claude-defaults](https://github.com/millsmillsymills/claude-defaults).

Installs `CLAUDE.md`, `.claude/settings.json`, and (optionally) `.mcp.json`
into `~/Desktop/Projects/claude-plugin-dev/` so that any Claude Code session
opened in that workspace (or any sub-project under it) gets plugin-dev tooling
(`plugin-dev`, `skill-creator`, `claude-code-setup`, `typescript-lsp`) loaded
on top of the global set.

## Install

\`\`\`bash
./scripts/install.sh           # default: install all into ../claude-plugin-dev/
./scripts/install.sh --dry-run # preview
./scripts/validate.sh          # verify symlinks
\`\`\`

See `claude-defaults` for the canonical pattern.
```

- [ ] **Step 5: First commit**

```bash
cd ~/Desktop/Projects/claude-plugin-dev-defaults
git add -A
git commit -m "Initial scaffolding"
```

---

### Task 8: Author `claude-plugin-dev` `CLAUDE.md` and `settings.json`

**Files:**
- Create: `~/Desktop/Projects/claude-plugin-dev-defaults/CLAUDE.md`
- Create: `~/Desktop/Projects/claude-plugin-dev-defaults/settings.json`

- [ ] **Step 1: Write `CLAUDE.md`**

Create `~/Desktop/Projects/claude-plugin-dev-defaults/CLAUDE.md`:
```markdown
# claude-plugin-dev workspace

This workspace hosts Claude Code plugin development. Each sub-directory is one
plugin in development or being maintained.

## Workspace conventions

- One plugin per sub-directory: `<plugin-name>/.claude-plugin/plugin.json`.
- Use `plugin-dev:create-plugin` (slash command) for new plugins.
- Validate before committing: `plugin-dev:plugin-validator` agent.
- Test plugins by symlinking into `~/.claude/plugins/cache/local/<plugin>/` and
  enabling via `/plugin install`.

## Plugins enabled here (in addition to global)

- `plugin-dev` — plugin development tooling.
- `skill-creator` — skill authoring (plugins frequently bundle skills).
- `claude-code-setup` — meta plugin for setup recommendations.
- `typescript-lsp` — most plugin commands/agents are markdown but tooling around
  them is often TS.

## Useful commands

- `plugin-dev:create-plugin` — guided plugin creation.
- `plugin-dev:plugin-validator` — agent that lints plugin structure.
- `skill-creator:skill-creator` — create or improve a skill.

Defer to global `~/.claude/CLAUDE.md` for code-quality limits, language
toolchains, and commit/PR conventions.
```

- [ ] **Step 2: Write `settings.json`**

Create `~/Desktop/Projects/claude-plugin-dev-defaults/settings.json`:
```json
{
  "$schema": "https://json.schemastore.org/claude-code-settings.json",
  "enabledPlugins": {
    "plugin-dev@claude-plugins-official": true,
    "skill-creator@claude-plugins-official": true,
    "claude-code-setup@claude-plugins-official": true,
    "typescript-lsp@claude-plugins-official": true
  }
}
```

- [ ] **Step 3: Validate JSON**

```bash
jq . ~/Desktop/Projects/claude-plugin-dev-defaults/settings.json > /dev/null
```
Expected: no output, exit 0.

- [ ] **Step 4: Commit**

```bash
cd ~/Desktop/Projects/claude-plugin-dev-defaults
git add CLAUDE.md settings.json
git commit -m "Add CLAUDE.md and settings.json for plugin-dev workspace"
```

---

### Task 9: Write `claude-plugin-dev-defaults` install + validate scripts

**Files:**
- Create: `~/Desktop/Projects/claude-plugin-dev-defaults/scripts/install.sh`
- Create: `~/Desktop/Projects/claude-plugin-dev-defaults/scripts/validate.sh`

These scripts are generic across all four workspaces — only the directory names differ. Each workspace-defaults repo gets its own copy.

- [ ] **Step 1: Write `install.sh`**

Create `~/Desktop/Projects/claude-plugin-dev-defaults/scripts/install.sh`:
```bash
#!/usr/bin/env bash
set -euo pipefail

# Install workspace defaults into ../<active-folder>/ via symlinks.
# Usage:
#   ./scripts/install.sh [--dry-run] [--force]
#
# Symlinks:
#   <active>/CLAUDE.md          -> ../<repo>/CLAUDE.md
#   <active>/.claude/settings.json -> ../../<repo>/settings.json
#   <active>/.mcp.json          -> ../<repo>/.mcp.json  (only if present)

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
REPO_NAME="$(basename "$REPO_DIR")"           # e.g. claude-plugin-dev-defaults
ACTIVE_NAME="${REPO_NAME%-defaults}"          # e.g. claude-plugin-dev
ACTIVE_DIR="$(dirname "$REPO_DIR")/$ACTIVE_NAME"

DRY_RUN=0
FORCE=0
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=1 ;;
        --force)   FORCE=1 ;;
        *) echo "Unknown arg: $arg" >&2; exit 2 ;;
    esac
done

log()  { echo "  $1"; }
ok()   { echo "  OK: $1"; }
dry()  { echo "  DRY-RUN: $1"; }

ensure_active_dir() {
    if [ ! -d "$ACTIVE_DIR" ]; then
        if [ "$DRY_RUN" = "1" ]; then
            dry "create $ACTIVE_DIR"
        else
            mkdir -p "$ACTIVE_DIR/.claude"
            ok "created $ACTIVE_DIR"
        fi
    fi
    if [ ! -d "$ACTIVE_DIR/.claude" ]; then
        if [ "$DRY_RUN" = "1" ]; then
            dry "create $ACTIVE_DIR/.claude"
        else
            mkdir -p "$ACTIVE_DIR/.claude"
        fi
    fi
}

link_one() {
    local src="$1" dst="$2"
    if [ ! -e "$src" ]; then
        log "skip $dst (source missing: $src)"
        return 0
    fi
    if [ -L "$dst" ]; then
        local current
        current="$(readlink "$dst")"
        local want_rel
        want_rel="$(python3 -c 'import os,sys; print(os.path.relpath(sys.argv[1], os.path.dirname(sys.argv[2])))' "$src" "$dst")"
        if [ "$current" = "$want_rel" ]; then
            ok "$dst already points to $src"
            return 0
        fi
        if [ "$FORCE" != "1" ]; then
            log "skip $dst (existing symlink -> $current; use --force)"
            return 0
        fi
        if [ "$DRY_RUN" = "1" ]; then
            dry "replace symlink $dst"; return 0
        fi
        rm "$dst"
    elif [ -e "$dst" ]; then
        log "skip $dst (existing non-symlink; move aside manually)"
        return 0
    fi
    if [ "$DRY_RUN" = "1" ]; then
        dry "symlink $dst -> $src"
        return 0
    fi
    local rel
    rel="$(python3 -c 'import os,sys; print(os.path.relpath(sys.argv[1], os.path.dirname(sys.argv[2])))' "$src" "$dst")"
    ln -s "$rel" "$dst"
    ok "linked $dst -> $rel"
}

ensure_active_dir

link_one "$REPO_DIR/CLAUDE.md"     "$ACTIVE_DIR/CLAUDE.md"
link_one "$REPO_DIR/settings.json" "$ACTIVE_DIR/.claude/settings.json"
link_one "$REPO_DIR/.mcp.json"     "$ACTIVE_DIR/.mcp.json"

echo ""
echo "Install complete. Active dir: $ACTIVE_DIR"
```

Make it executable:
```bash
chmod +x ~/Desktop/Projects/claude-plugin-dev-defaults/scripts/install.sh
```

- [ ] **Step 2: Write `validate.sh`**

Create `~/Desktop/Projects/claude-plugin-dev-defaults/scripts/validate.sh`:
```bash
#!/usr/bin/env bash
set -uo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
REPO_NAME="$(basename "$REPO_DIR")"
ACTIVE_NAME="${REPO_NAME%-defaults}"
ACTIVE_DIR="$(dirname "$REPO_DIR")/$ACTIVE_NAME"

errors=0
pass() { printf "  \033[32mOK\033[0m  %s\n" "$1"; }
fail() { printf "  \033[31mFAIL\033[0m  %s\n" "$1"; ((errors++)) || true; }

echo "Validating $REPO_NAME -> $ACTIVE_DIR"
echo ""

check_link() {
    local dst="$1" expected_target_basename="$2"
    if [ ! -L "$dst" ]; then
        fail "$dst is not a symlink"
        return
    fi
    local resolved
    resolved="$(readlink -f "$dst" 2>/dev/null || python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$dst")"
    if [ ! -e "$resolved" ]; then
        fail "$dst -> $resolved (broken)"
        return
    fi
    if [[ "$(basename "$resolved")" != "$expected_target_basename" ]]; then
        fail "$dst resolves to $(basename "$resolved"), expected $expected_target_basename"
        return
    fi
    pass "$dst -> $resolved"
}

if [ ! -d "$ACTIVE_DIR" ]; then
    fail "Active dir does not exist: $ACTIVE_DIR"
else
    pass "Active dir exists: $ACTIVE_DIR"
fi

check_link "$ACTIVE_DIR/CLAUDE.md" "CLAUDE.md"
check_link "$ACTIVE_DIR/.claude/settings.json" "settings.json"
if [ -e "$REPO_DIR/.mcp.json" ]; then
    check_link "$ACTIVE_DIR/.mcp.json" ".mcp.json"
fi

if [ -L "$ACTIVE_DIR/.claude/settings.json" ]; then
    if jq . "$ACTIVE_DIR/.claude/settings.json" > /dev/null 2>&1; then
        pass "settings.json is valid JSON"
    else
        fail "settings.json is invalid JSON"
    fi
fi

echo ""
if [ "$errors" -eq 0 ]; then
    echo "Validation passed."
    exit 0
else
    echo "Validation failed: $errors error(s)."
    exit 1
fi
```

Make it executable:
```bash
chmod +x ~/Desktop/Projects/claude-plugin-dev-defaults/scripts/validate.sh
```

- [ ] **Step 3: Commit scripts**

```bash
cd ~/Desktop/Projects/claude-plugin-dev-defaults
git add scripts/
git commit -m "Add install.sh and validate.sh"
```

---

### Task 10: Run install for `claude-plugin-dev`

**Files:**
- Create: `~/Desktop/Projects/claude-plugin-dev/CLAUDE.md` (symlink)
- Create: `~/Desktop/Projects/claude-plugin-dev/.claude/settings.json` (symlink)

- [ ] **Step 1: Dry-run the install**

```bash
~/Desktop/Projects/claude-plugin-dev-defaults/scripts/install.sh --dry-run
```
Expected output: shows it would create `~/Desktop/Projects/claude-plugin-dev/`, then symlink `CLAUDE.md` and `.claude/settings.json`. No `.mcp.json` because none exists in the defaults repo yet.

- [ ] **Step 2: Run the install**

```bash
~/Desktop/Projects/claude-plugin-dev-defaults/scripts/install.sh
```
Expected: three `OK:` lines (created dir, linked CLAUDE.md, linked settings.json).

- [ ] **Step 3: Verify symlinks resolve**

```bash
ls -la ~/Desktop/Projects/claude-plugin-dev/
ls -la ~/Desktop/Projects/claude-plugin-dev/.claude/
```
Expected: `CLAUDE.md` and `.claude/settings.json` shown as symlinks pointing into `claude-plugin-dev-defaults/`.

- [ ] **Step 4: Run validate**

```bash
~/Desktop/Projects/claude-plugin-dev-defaults/scripts/validate.sh
```
Expected: all checks `OK`, exit 0.

---

### Task 11: Validate `claude-plugin-dev` workspace loads correctly

**Files:** (none modified; this is a behavioral check)

- [ ] **Step 1: Open a Claude Code session in `claude-plugin-dev/`**

```bash
cd ~/Desktop/Projects/claude-plugin-dev
claude   # or: claude-yolo
```

- [ ] **Step 2: Confirm workspace CLAUDE.md is loaded**

In the session, ask: "What's in this workspace's CLAUDE.md?"
Expected: Claude paraphrases the workspace-specific content (plugin development conventions). If it only references the global CLAUDE.md, the symlink isn't being followed — debug before continuing.

- [ ] **Step 3: Confirm specialized plugins are available**

In the session, run `/agents` and confirm at least these are listed:
- `plugin-dev:plugin-validator`
- `plugin-dev:agent-creator`
- `skill-creator:skill-creator`

If these are missing here but present elsewhere (e.g. in `~/Desktop/Projects/`), the workspace's `enabledPlugins` is not merging correctly. Re-check the JSON.

- [ ] **Step 4: Smoke test with a scratch plugin**

In the session:
```
/plugin-dev:create-plugin
```
Walk through the prompts to scaffold a throwaway plugin in `~/Desktop/Projects/claude-plugin-dev/_scratch/`. Confirm files are generated correctly. `trash` the scratch directory afterward.

---

## Phase 3 — Scaffold remaining three workspaces

Each of Tasks 12, 13, 14 follows the **same shape as Tasks 7-11**:
1. Init repo, .gitignore, README, LICENSE.
2. Write `CLAUDE.md` + `settings.json` with workspace-specific content (shown below).
3. Copy `scripts/install.sh` + `scripts/validate.sh` verbatim from `claude-plugin-dev-defaults` (they're generic).
4. Run install, validate, smoke test.

The deltas (`CLAUDE.md` text, `settings.json` plugin list) appear in each task. Everything else is identical.

---

### Task 12: Scaffold `claude-skill-dev` workspace

**Files:**
- Create: `~/Desktop/Projects/claude-skill-dev-defaults/` (full structure)
- Create: `~/Desktop/Projects/claude-skill-dev/` (active folder + symlinks)

- [ ] **Step 1: Init repo and copy scaffolding**

```bash
mkdir -p ~/Desktop/Projects/claude-skill-dev-defaults/scripts
cd ~/Desktop/Projects/claude-skill-dev-defaults
git init -b main
cp ~/Desktop/Projects/claude-plugin-dev-defaults/.gitignore .
cp ~/Desktop/Projects/claude-plugin-dev-defaults/LICENSE .
cp ~/Desktop/Projects/claude-plugin-dev-defaults/scripts/install.sh scripts/
cp ~/Desktop/Projects/claude-plugin-dev-defaults/scripts/validate.sh scripts/
chmod +x scripts/*.sh
```

- [ ] **Step 2: Write `README.md`**

Create `~/Desktop/Projects/claude-skill-dev-defaults/README.md`:
```markdown
# claude-skill-dev-defaults

Config repo for Claude Code skill development. Sibling of
[claude-defaults](https://github.com/millsmillsymills/claude-defaults).

Installs `CLAUDE.md` and `.claude/settings.json` into
`~/Desktop/Projects/claude-skill-dev/` so that any Claude Code session opened
in that workspace gets `skill-creator` loaded on top of the global set.

## Install

\`\`\`bash
./scripts/install.sh           # default: install all into ../claude-skill-dev/
./scripts/install.sh --dry-run # preview
./scripts/validate.sh          # verify symlinks
\`\`\`

See `claude-defaults` for the canonical pattern.
```

- [ ] **Step 3: Write `CLAUDE.md`**

Create `~/Desktop/Projects/claude-skill-dev-defaults/CLAUDE.md`:
```markdown
# claude-skill-dev workspace

This workspace hosts standalone skill development. Each sub-directory is one
skill collection or one experimental skill.

## Workspace conventions

- A skill is a markdown file with YAML frontmatter (`name`, `description`).
- Long skills can bundle resources in a subdirectory (`<skill>/skill.md` +
  `<skill>/references/`).
- Validate by installing the skill into `~/.claude/skills/<name>/` (or via a
  plugin's `skills:` field) and exercising the trigger phrases.

## Plugins enabled here (in addition to global)

- `skill-creator` — guided skill creation, eval, optimization.

## Useful commands

- `skill-creator:skill-creator` — create or improve a skill.
- `superpowers:writing-skills` — disciplined skill-authoring workflow.

Defer to global `~/.claude/CLAUDE.md` for code-quality limits and conventions.
```

- [ ] **Step 4: Write `settings.json`**

Create `~/Desktop/Projects/claude-skill-dev-defaults/settings.json`:
```json
{
  "$schema": "https://json.schemastore.org/claude-code-settings.json",
  "enabledPlugins": {
    "skill-creator@claude-plugins-official": true
  }
}
```

- [ ] **Step 5: Validate JSON, commit**

```bash
jq . ~/Desktop/Projects/claude-skill-dev-defaults/settings.json > /dev/null
cd ~/Desktop/Projects/claude-skill-dev-defaults
git add -A
git commit -m "Initial scaffolding for claude-skill-dev-defaults"
```

- [ ] **Step 6: Install, validate, smoke test**

```bash
~/Desktop/Projects/claude-skill-dev-defaults/scripts/install.sh --dry-run
~/Desktop/Projects/claude-skill-dev-defaults/scripts/install.sh
~/Desktop/Projects/claude-skill-dev-defaults/scripts/validate.sh
```
Expected: all `OK`. Open a Claude Code session in `~/Desktop/Projects/claude-skill-dev/`, run `/agents`, confirm `skill-creator:skill-creator` is listed.

---

### Task 13: Scaffold `mcp-server-dev` workspace

**Files:**
- Create: `~/Desktop/Projects/mcp-server-dev-defaults/` (full structure)
- Create: `~/Desktop/Projects/mcp-server-dev/` (active folder + symlinks)

- [ ] **Step 1: Init repo and copy scaffolding**

```bash
mkdir -p ~/Desktop/Projects/mcp-server-dev-defaults/scripts
cd ~/Desktop/Projects/mcp-server-dev-defaults
git init -b main
cp ~/Desktop/Projects/claude-plugin-dev-defaults/.gitignore .
cp ~/Desktop/Projects/claude-plugin-dev-defaults/LICENSE .
cp ~/Desktop/Projects/claude-plugin-dev-defaults/scripts/install.sh scripts/
cp ~/Desktop/Projects/claude-plugin-dev-defaults/scripts/validate.sh scripts/
chmod +x scripts/*.sh
```

- [ ] **Step 2: Write `README.md`**

Create `~/Desktop/Projects/mcp-server-dev-defaults/README.md`:
```markdown
# mcp-server-dev-defaults

Config repo for Model Context Protocol server development. Sibling of
[claude-defaults](https://github.com/millsmillsymills/claude-defaults).

Installs `CLAUDE.md` and `.claude/settings.json` into
`~/Desktop/Projects/mcp-server-dev/`. Hosts four migrated MCP server projects:
`gandi-mcp`, `protonmail-mcp`, `unifi-mcp`, `unraid-mcp`.

## Install

\`\`\`bash
./scripts/install.sh           # default: install all into ../mcp-server-dev/
./scripts/install.sh --dry-run # preview
./scripts/validate.sh          # verify symlinks
\`\`\`

See `claude-defaults` for the canonical pattern.
```

- [ ] **Step 3: Write `CLAUDE.md`**

Create `~/Desktop/Projects/mcp-server-dev-defaults/CLAUDE.md`:
```markdown
# mcp-server-dev workspace

This workspace hosts Model Context Protocol server development. Sub-directories
are MCP server projects (Python, Go, TypeScript).

## Workspace conventions

- One server per sub-directory; each follows its own language's conventions
  (Python: `pyproject.toml` + `uv`; Go: `go.mod`; TS: `package.json`).
- Each server has its own CLAUDE.md inheriting from this one.
- Use `mcp-server-dev:build-mcp-server` (slash command) to bootstrap a new
  server; it picks deployment model (stdio / remote HTTP / MCPB) and tool
  patterns.
- Integration tests should hit a real instance (no mocking the server itself).

## Plugins enabled here (in addition to global)

- `mcp-server-dev` — server scaffolding, deployment-model selection.
- `typescript-lsp` — for TS-based servers.
- `gopls-lsp` — for Go-based servers.
- `pyright-lsp` is already global.

## Migrated servers

- `gandi-mcp` (Python) — Gandi domains/DNS.
- `protonmail-mcp` (Go) — Proton mail integration.
- `unifi-mcp` (Python) — UniFi network controller.
- `unraid-mcp` (Docker/Python) — Unraid server.

Defer to global `~/.claude/CLAUDE.md` for code-quality limits and conventions.
```

- [ ] **Step 4: Write `settings.json`**

Create `~/Desktop/Projects/mcp-server-dev-defaults/settings.json`:
```json
{
  "$schema": "https://json.schemastore.org/claude-code-settings.json",
  "enabledPlugins": {
    "mcp-server-dev@claude-plugins-official": true,
    "typescript-lsp@claude-plugins-official": true,
    "gopls-lsp@claude-plugins-official": true
  }
}
```

- [ ] **Step 5: Validate JSON, commit**

```bash
jq . ~/Desktop/Projects/mcp-server-dev-defaults/settings.json > /dev/null
cd ~/Desktop/Projects/mcp-server-dev-defaults
git add -A
git commit -m "Initial scaffolding for mcp-server-dev-defaults"
```

- [ ] **Step 6: Install, validate, smoke test**

```bash
~/Desktop/Projects/mcp-server-dev-defaults/scripts/install.sh --dry-run
~/Desktop/Projects/mcp-server-dev-defaults/scripts/install.sh
~/Desktop/Projects/mcp-server-dev-defaults/scripts/validate.sh
```
Expected: all `OK`. Open a Claude Code session in `~/Desktop/Projects/mcp-server-dev/`, run `/agents`, confirm `mcp-server-dev:build-mcp-server` is listed.

Note: at this point `mcp-server-dev/` is empty. The four MCP server repos move in during Phase 4.

---

### Task 14: Scaffold `agent-sdk-dev` workspace

**Files:**
- Create: `~/Desktop/Projects/agent-sdk-dev-defaults/` (full structure)
- Create: `~/Desktop/Projects/agent-sdk-dev/` (active folder + symlinks)

- [ ] **Step 1: Init repo and copy scaffolding**

```bash
mkdir -p ~/Desktop/Projects/agent-sdk-dev-defaults/scripts
cd ~/Desktop/Projects/agent-sdk-dev-defaults
git init -b main
cp ~/Desktop/Projects/claude-plugin-dev-defaults/.gitignore .
cp ~/Desktop/Projects/claude-plugin-dev-defaults/LICENSE .
cp ~/Desktop/Projects/claude-plugin-dev-defaults/scripts/install.sh scripts/
cp ~/Desktop/Projects/claude-plugin-dev-defaults/scripts/validate.sh scripts/
chmod +x scripts/*.sh
```

- [ ] **Step 2: Write `README.md`**

Create `~/Desktop/Projects/agent-sdk-dev-defaults/README.md`:
```markdown
# agent-sdk-dev-defaults

Config repo for Claude Agent SDK app development. Sibling of
[claude-defaults](https://github.com/millsmillsymills/claude-defaults).

Installs `CLAUDE.md` and `.claude/settings.json` into
`~/Desktop/Projects/agent-sdk-dev/`. Each sub-directory is one SDK app
(chatbot, internal tool, custom agent).

## Install

\`\`\`bash
./scripts/install.sh           # default: install all into ../agent-sdk-dev/
./scripts/install.sh --dry-run # preview
./scripts/validate.sh          # verify symlinks
\`\`\`

See `claude-defaults` for the canonical pattern.
```

- [ ] **Step 3: Write `CLAUDE.md`**

Create `~/Desktop/Projects/agent-sdk-dev-defaults/CLAUDE.md`:
```markdown
# agent-sdk-dev workspace

This workspace hosts Claude Agent SDK applications. Each sub-directory is one
SDK app (chatbot, internal tool, custom agent).

## Workspace conventions

- Python (3.13, `uv`) or TypeScript (Node 22, ESM) per app.
- Use `agent-sdk-dev:new-sdk-app` (slash command) to bootstrap.
- Hand off to `agent-sdk-dev:agent-sdk-verifier-py` or
  `agent-sdk-dev:agent-sdk-verifier-ts` after structural changes.

## Plugins enabled here (in addition to global)

- `agent-sdk-dev` — SDK app scaffolding and verification.
- `typescript-lsp` — for TS apps.
- `pyright-lsp` is already global.

Defer to global `~/.claude/CLAUDE.md` for toolchains and conventions.
```

- [ ] **Step 4: Write `settings.json`**

Create `~/Desktop/Projects/agent-sdk-dev-defaults/settings.json`:
```json
{
  "$schema": "https://json.schemastore.org/claude-code-settings.json",
  "enabledPlugins": {
    "agent-sdk-dev@claude-plugins-official": true,
    "typescript-lsp@claude-plugins-official": true
  }
}
```

- [ ] **Step 5: Validate JSON, commit**

```bash
jq . ~/Desktop/Projects/agent-sdk-dev-defaults/settings.json > /dev/null
cd ~/Desktop/Projects/agent-sdk-dev-defaults
git add -A
git commit -m "Initial scaffolding for agent-sdk-dev-defaults"
```

- [ ] **Step 6: Install, validate, smoke test**

```bash
~/Desktop/Projects/agent-sdk-dev-defaults/scripts/install.sh --dry-run
~/Desktop/Projects/agent-sdk-dev-defaults/scripts/install.sh
~/Desktop/Projects/agent-sdk-dev-defaults/scripts/validate.sh
```
Expected: all `OK`. Open a session in `~/Desktop/Projects/agent-sdk-dev/`, confirm `agent-sdk-dev:new-sdk-app` is available.

---

## Phase 4 — Migrate MCP server projects

### Task 15: MCP server migration preflight

**Files:** (read-only checks)

- [ ] **Step 1: Confirm all four repos are clean**

```bash
for repo in gandi-mcp protonmail-mcp unifi-mcp unraid-mcp; do
    echo "=== $repo ==="
    cd "$HOME/Desktop/Projects/$repo"
    git status --short
done
```
Expected: each block prints the repo header followed by no further output. If any repo has dirty state, commit, stash, or `trash` artifacts before continuing. As of 2026-05-20, `protonmail-mcp` has worktree `issue-76-persist-degraded` — finish or stash that branch first.

- [ ] **Step 2: List worktrees per repo**

```bash
for repo in gandi-mcp protonmail-mcp unifi-mcp unraid-mcp; do
    echo "=== $repo ==="
    cd "$HOME/Desktop/Projects/$repo"
    git worktree list --porcelain
done
```
Capture the output. Any worktree at a path NOT inside the repo's `.worktrees/` directory needs handling (they may have already been moved or have stale references).

- [ ] **Step 3: Remove all active worktrees**

For each worktree listed in Step 2 (other than the main worktree), run:
```bash
cd "$HOME/Desktop/Projects/<repo>"
git worktree remove <worktree-path>
```
Or, if remove fails because the worktree dir is gone:
```bash
git worktree prune
```

- [ ] **Step 4: Fresh snapshot of `~/.claude.json`**

```bash
cp ~/.claude.json ~/.claude/backups/pre-trim-2026-05-20/dot-claude-pre-mcp-move.json
```
This is in addition to Task 1's snapshot — that one may be stale by now.

- [ ] **Step 5: Confirm `mcp-server-dev/` is empty and ready**

```bash
ls -la ~/Desktop/Projects/mcp-server-dev/
```
Expected: only `CLAUDE.md` (symlink) and `.claude/`. No actual sub-projects yet.

---

### Task 16: Migrate `gandi-mcp`

**Files:**
- Move: `~/Desktop/Projects/gandi-mcp/` → `~/Desktop/Projects/mcp-server-dev/gandi-mcp/`
- Handle: `~/Desktop/Projects/gandi-mcp.worktrees/` (relocate or rebuild)
- Modify: `~/.claude.json` (path rewrites)

- [ ] **Step 1: Remove the `.worktrees` directory**

```bash
cd ~/Desktop/Projects/gandi-mcp
git worktree list --porcelain
```
If any worktrees in `~/Desktop/Projects/gandi-mcp.worktrees/` are listed:
```bash
git worktree remove ~/Desktop/Projects/gandi-mcp.worktrees/<each>
```
Then:
```bash
trash ~/Desktop/Projects/gandi-mcp.worktrees
```
(The directory will be recreated by `wt switch` after the move if needed.)

- [ ] **Step 2: Move the repo**

```bash
mv ~/Desktop/Projects/gandi-mcp ~/Desktop/Projects/mcp-server-dev/gandi-mcp
```

- [ ] **Step 3: Rewrite paths in `~/.claude.json`**

```bash
jq --arg old "/Users/mills/Desktop/Projects/gandi-mcp" \
   --arg new "/Users/mills/Desktop/Projects/mcp-server-dev/gandi-mcp" \
   'walk(if type == "string" and . == $old then $new
         elif type == "string" and startswith($old + "/") then $new + (.[$old|length:])
         else . end)' \
   ~/.claude.json > ~/.claude.json.new
```

- [ ] **Step 4: Diff and review**

```bash
diff ~/.claude.json ~/.claude.json.new | head -50
```
Expected: only changes are `gandi-mcp` paths becoming `mcp-server-dev/gandi-mcp`. No structural changes. If anything looks off, abort:
```bash
rm ~/.claude.json.new
```
and investigate.

- [ ] **Step 5: Apply**

```bash
mv ~/.claude.json.new ~/.claude.json
```

- [ ] **Step 6: Verify git in the new location works**

```bash
cd ~/Desktop/Projects/mcp-server-dev/gandi-mcp
git status
git log -1 --oneline
```
Expected: clean status, last commit shown. If git complains, the `.git` directory may need attention (rare, since git uses relative paths within the repo).

- [ ] **Step 7: Verify Claude session at new path**

Open a session at `~/Desktop/Projects/mcp-server-dev/gandi-mcp/`. Run `/agents` — confirm `mcp-server-dev` plugin agents are available (inherited from workspace `.claude/settings.json`). Run a sanity command (e.g. `uv sync` or `make help`) to confirm the project itself still works.

---

### Task 17: Migrate `protonmail-mcp`

Same shape as Task 16. Subscripted paths only.

**Files:**
- Move: `~/Desktop/Projects/protonmail-mcp/` → `~/Desktop/Projects/mcp-server-dev/protonmail-mcp/`
- Modify: `~/.claude.json` (path rewrites)

- [ ] **Step 1: Worktree teardown**

```bash
cd ~/Desktop/Projects/protonmail-mcp
git worktree list --porcelain
# remove each non-main worktree
git worktree prune
```

- [ ] **Step 2: Move the repo**

```bash
mv ~/Desktop/Projects/protonmail-mcp ~/Desktop/Projects/mcp-server-dev/protonmail-mcp
```

- [ ] **Step 3: Rewrite paths in `~/.claude.json`**

```bash
jq --arg old "/Users/mills/Desktop/Projects/protonmail-mcp" \
   --arg new "/Users/mills/Desktop/Projects/mcp-server-dev/protonmail-mcp" \
   'walk(if type == "string" and . == $old then $new
         elif type == "string" and startswith($old + "/") then $new + (.[$old|length:])
         else . end)' \
   ~/.claude.json > ~/.claude.json.new
diff ~/.claude.json ~/.claude.json.new | head -50
mv ~/.claude.json.new ~/.claude.json
```

- [ ] **Step 4: Verify**

```bash
cd ~/Desktop/Projects/mcp-server-dev/protonmail-mcp
git status
go build ./...   # or whatever the project's build command is
```
Expected: clean status, build succeeds.

---

### Task 18: Migrate `unifi-mcp`

**Files:**
- Move: `~/Desktop/Projects/unifi-mcp/` → `~/Desktop/Projects/mcp-server-dev/unifi-mcp/`
- Modify: `~/.claude.json`

- [ ] **Step 1: Worktree teardown**

```bash
cd ~/Desktop/Projects/unifi-mcp
git worktree list --porcelain
git worktree prune
```

- [ ] **Step 2: Move the repo**

```bash
mv ~/Desktop/Projects/unifi-mcp ~/Desktop/Projects/mcp-server-dev/unifi-mcp
```

- [ ] **Step 3: Rewrite paths**

```bash
jq --arg old "/Users/mills/Desktop/Projects/unifi-mcp" \
   --arg new "/Users/mills/Desktop/Projects/mcp-server-dev/unifi-mcp" \
   'walk(if type == "string" and . == $old then $new
         elif type == "string" and startswith($old + "/") then $new + (.[$old|length:])
         else . end)' \
   ~/.claude.json > ~/.claude.json.new
diff ~/.claude.json ~/.claude.json.new | head -50
mv ~/.claude.json.new ~/.claude.json
```

- [ ] **Step 4: Verify**

```bash
cd ~/Desktop/Projects/mcp-server-dev/unifi-mcp
git status
uv sync
```
Expected: clean status, env synced.

---

### Task 19: Migrate `unraid-mcp`

**Files:**
- Move: `~/Desktop/Projects/unraid-mcp/` → `~/Desktop/Projects/mcp-server-dev/unraid-mcp/`
- Modify: `~/.claude.json`

- [ ] **Step 1: Worktree teardown**

```bash
cd ~/Desktop/Projects/unraid-mcp
git worktree list --porcelain
git worktree prune
```

- [ ] **Step 2: Move the repo**

```bash
mv ~/Desktop/Projects/unraid-mcp ~/Desktop/Projects/mcp-server-dev/unraid-mcp
```

- [ ] **Step 3: Rewrite paths**

```bash
jq --arg old "/Users/mills/Desktop/Projects/unraid-mcp" \
   --arg new "/Users/mills/Desktop/Projects/mcp-server-dev/unraid-mcp" \
   'walk(if type == "string" and . == $old then $new
         elif type == "string" and startswith($old + "/") then $new + (.[$old|length:])
         else . end)' \
   ~/.claude.json > ~/.claude.json.new
diff ~/.claude.json ~/.claude.json.new | head -50
mv ~/.claude.json.new ~/.claude.json
```

- [ ] **Step 4: Verify**

```bash
cd ~/Desktop/Projects/mcp-server-dev/unraid-mcp
git status
```
Expected: clean status. (Run language-specific build step depending on the project's stack.)

---

## Phase 5 — Trim global plugin set & document

### Task 20: Trim global `enabledPlugins`

**Files:**
- Modify: `~/.claude/settings.json`

- [ ] **Step 1: Snapshot before the change**

```bash
cp ~/.claude/settings.json ~/.claude/backups/pre-trim-2026-05-20/settings.json.pre-trim
```

- [ ] **Step 2: Build the trimmed `enabledPlugins`**

The final set should be exactly these (in any order):
- `superpowers@claude-plugins-official`
- `codex@openai-codex`
- `code-review@claude-plugins-official`
- `code-simplifier@claude-plugins-official`
- `pr-review-toolkit@claude-plugins-official`
- `claude-md-management@claude-plugins-official`
- `github@claude-plugins-official`
- `commit-commands@claude-plugins-official`
- `pyright-lsp@claude-plugins-official`
- `mattpocock-skills@mattpocock-skills` (or the exact name from Task 3 Step 5)

All others must be removed or set to `false`.

```bash
jq '
  .enabledPlugins = {
    "superpowers@claude-plugins-official": true,
    "codex@openai-codex": true,
    "code-review@claude-plugins-official": true,
    "code-simplifier@claude-plugins-official": true,
    "pr-review-toolkit@claude-plugins-official": true,
    "claude-md-management@claude-plugins-official": true,
    "github@claude-plugins-official": true,
    "commit-commands@claude-plugins-official": true,
    "pyright-lsp@claude-plugins-official": true,
    "mattpocock@mattpocock-skills": true
  }
' ~/.claude/settings.json > ~/.claude/settings.json.new
```
Adjust `"mattpocock@mattpocock-skills"` to match whatever Task 3 actually installed (run `jq '.enabledPlugins | keys' ~/.claude/settings.json | rg -i pocock` against the pre-trim snapshot to find the exact key).

- [ ] **Step 3: Diff and review**

```bash
diff <(jq '.enabledPlugins' ~/.claude/settings.json) \
     <(jq '.enabledPlugins' ~/.claude/settings.json.new)
```
Expected: deletions for the 13 demoted plugins, no additions other than (potentially) the matt-pocock key if Task 3 didn't already add it.

- [ ] **Step 4: Apply**

```bash
mv ~/.claude/settings.json.new ~/.claude/settings.json
```

- [ ] **Step 5: Count**

```bash
jq '.enabledPlugins | keys | length' ~/.claude/settings.json
```
Expected: `10`.

---

### Task 21: Verify global trim end-to-end

**Files:** (none modified; behavioral verification)

- [ ] **Step 1: Open session in a non-workspace folder**

```bash
cd ~/Desktop/Projects/Sonarr
claude
```

- [ ] **Step 2: Check loaded plugins**

In the session: `/agents` — count entries. They should only come from the 10 global plugins. Specifically, NONE of these should appear:
- `plugin-dev:*`
- `skill-creator:*`
- `mcp-server-dev:*`
- `agent-sdk-dev:*`
- `frontend-design:*`
- `playwright:*`
- `typescript-lsp:*`
- `gopls-lsp:*`
- `security-guidance:*`
- `feature-dev:*`
- `claude-code-setup:*`
- `ralph-loop:*`
- `context7:*` (the plugin)

If any appear, the demote didn't take. Investigate.

- [ ] **Step 3: Verify MCPs in non-workspace session**

```
/mcp
```
Expected: `aws-mcp`, `context7`, `exa`, `gandi`, `protonmail`. No more.

- [ ] **Step 4: Open session in each workspace, confirm plugins re-load**

For each of the four workspaces:
```bash
cd ~/Desktop/Projects/<workspace>
claude
```
Then `/agents` and verify the workspace-specific plugins are present:

| Workspace | Expected extras (beyond global 10) |
|---|---|
| `claude-plugin-dev` | `plugin-dev:*`, `skill-creator:*`, `claude-code-setup:*`, `typescript-lsp:*` |
| `claude-skill-dev` | `skill-creator:*` |
| `mcp-server-dev` | `mcp-server-dev:*`, `typescript-lsp:*`, `gopls-lsp:*` |
| `agent-sdk-dev` | `agent-sdk-dev:*`, `typescript-lsp:*` |

- [ ] **Step 5: Verify migrated MCP project workflows**

```bash
cd ~/Desktop/Projects/mcp-server-dev/gandi-mcp
make help    # or uv sync, etc.
```
Repeat for each migrated repo. Confirm tooling still works (LSP attaches, build/tests run).

---

### Task 22: Document the changes

**Files:**
- Modify: `~/Desktop/Projects/claude-defaults/README.md`
- Modify: `~/Desktop/Projects/{claude-plugin-dev,claude-skill-dev,mcp-server-dev,agent-sdk-dev}-defaults/README.md`

- [ ] **Step 1: Add "Sibling workspaces" section to `claude-defaults/README.md`**

Edit `~/Desktop/Projects/claude-defaults/README.md`. After the introduction (or before "First-time setup"), add:

```markdown
## Sibling workspaces

`claude-defaults` is the global config repo. For domain-specific Claude Code
work, four sibling workspace-defaults repos extend the same install pattern:

| Repo | Active folder | Purpose |
|---|---|---|
| `claude-plugin-dev-defaults` | `~/Desktop/Projects/claude-plugin-dev/` | Claude Code plugin development |
| `claude-skill-dev-defaults`  | `~/Desktop/Projects/claude-skill-dev/`  | Standalone skill development |
| `mcp-server-dev-defaults`    | `~/Desktop/Projects/mcp-server-dev/`    | MCP server development (Python/Go/TS) |
| `agent-sdk-dev-defaults`     | `~/Desktop/Projects/agent-sdk-dev/`     | Claude Agent SDK app development |

Each enables a specialized plugin set on top of the global 10. See the spec at
`docs/superpowers/specs/2026-05-20-claude-dev-setup-optimization-design.md`.
```

- [ ] **Step 2: Update each workspace-defaults README**

In each of the four `<workspace>-defaults/README.md` files, add at the bottom:

```markdown
## See also

- [claude-defaults](../claude-defaults/) — global config repo. Shared CLAUDE.md,
  hooks, statusline, and the install-and-symlink pattern this repo extends.
```

- [ ] **Step 3: Commit each repo**

```bash
cd ~/Desktop/Projects/claude-defaults
git add README.md
git commit -m "Add Sibling workspaces section pointing to workspace-defaults repos"

for repo in claude-plugin-dev-defaults claude-skill-dev-defaults mcp-server-dev-defaults agent-sdk-dev-defaults; do
    cd "$HOME/Desktop/Projects/$repo"
    git add README.md
    git commit -m "Link to claude-defaults in See also"
done
```

- [ ] **Step 4: Final verification**

```bash
jq '.enabledPlugins | keys | length' ~/.claude/settings.json    # expect 10
jq '.mcpServers | keys' ~/.claude.json                          # expect ["aws-mcp", "context7", "exa", "gandi", "protonmail"]
ls -la ~/Desktop/Projects/mcp-server-dev/                       # expect 4 migrated MCP repos
```

---

## Execution log (2026-05-21)

**Completed autonomously:**
- Tasks 1, 2, 4, 5: snapshot, matt-pocock SHA pin (`ed4ea2c8`), Exa MCP added, context7 promoted to global, context7 plugin disabled. Final MCP set in `~/.claude.json` matches design: `aws-mcp, context7, exa, gandi, protonmail`.
- Tasks 7-14: all four workspace-defaults config repos created and installed. Active folders symlinked. Validation passes for all four.
- Tasks 16, 19: `gandi-mcp` and `unraid-mcp` migrated into `mcp-server-dev/`. `~/.claude.json` paths rewritten for both (values **and** project keys).
- Task 20: global `enabledPlugins` trimmed from 21 to 9 (matt-pocock excluded until install).
- Task 22: `claude-defaults/README.md` got the "Sibling workspaces" section. Each workspace-defaults README already has the "See also" cross-link.

**Deferred (need user-interactive Claude Code session):**
- Task 3 steps 4-6: `/plugin marketplace add dstroe2000/mattpocock_skills && /plugin install mattpocock@mattpocock-skills`. Will bring count from 9 to 10.
- Task 6 step 3: open `/tmp/plugin-disable-test/` in a session, check `/agents`, fill in `docs/PLUGIN-SCOPE-FINDINGS.md`.
- Task 11, plus the Step-6 smoke tests in Tasks 12-14: open each workspace, confirm specialized plugins load.
- Task 21: end-to-end verification (open Sonarr session, check `/agents` and `/mcp`; open each workspace, confirm re-enabling works).

**Deferred (in-flight work blocks safe migration):**
- Task 17 (`protonmail-mcp`): repo had 38 modified files + ~50 untracked on branch `fix/102-103-cleanup`, plus the `issue-76-persist-degraded` worktree. Resume migration after that work is committed/stashed.
- Task 18 (`unifi-mcp`): 4 locked Claude agent worktrees actively running (pid 94131): `test/271-touched-ap-guard`, `test/271-bump-poll-intervals`, `docs/271-no-full-sweep-warning`, `test/271-stop-on-unexpected-write-error`. Resume after agents finish.

**Plan bugs found during execution:**
- The `jq walk` filter only rewrites string *values*, not object *keys*. `~/.claude.json`'s `projects` keys ARE strings storing paths, so the walk missed them. Working command needs both `walk(...)` and `.projects |= with_entries(...)`. The Tasks 16-19 templates in this plan still show the buggy single-`walk` version — anyone resuming Tasks 17, 18 should use the corrected form below.

**Corrected `~/.claude.json` rewrite for any future repo migration:**
```bash
jq --arg old "/Users/mills/Desktop/Projects/<name>" \
   --arg new "/Users/mills/Desktop/Projects/mcp-server-dev/<name>" '
  walk(if type == "string" and . == $old then $new
       elif type == "string" and startswith($old + "/") then $new + (.[($old|length):])
       else . end)
  | .projects |= with_entries(
      if .key == $old then .key = $new
      elif (.key | startswith($old + "/")) then .key = ($new + (.key | .[($old|length):]))
      else . end
    )
' ~/.claude.json > ~/.claude.json.new
```

**Quirks observed:**
- `~/Desktop/Projects/.claude/settings.local.json` keeps having `enabledMcpjsonServers: ["context7"]` re-added by the harness's permission-grant writeback. Functionally inert (no `.mcp.json` exists at `Projects/` root, and context7 now loads from global `mcpServers`). Safe to leave; the dead key can be deleted at the end of any Claude session that doesn't trigger another permission write.

## Post-implementation notes

- Schedule a monthly drift check: `cd ~/.claude/plugins/cache/mattpocock-skills/<sha>/ && git fetch origin && git log --oneline upstream/main..HEAD` (or similar; the exact command depends on how the plugin cache is laid out).
- If `pyright-lsp` global proves wasteful in non-Python sessions, revisit. Demoting it to `mcp-server-dev` + `agent-sdk-dev` is one `jq` edit away.
- Once `mattpocock/skills` PR #41 merges upstream, swap the `extraKnownMarketplaces` entry to point at `mattpocock/skills` directly.
- The four workspace-defaults repos are local-only by design. Publication (push to GitHub, install scripts that pull from there) is a follow-up if any of them prove broadly useful.
