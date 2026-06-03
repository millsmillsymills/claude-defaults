# claude-defaults

Project-level instructions for this repo. The global `~/.claude/CLAUDE.md` sets defaults; this file layers on what's unique to claude-defaults.

This repo is Claude Code configuration: shell/Python hooks, an installer (`scripts/install.sh` and friends), settings templates, and docs. Hooks live at `hooks/*.sh` and `hooks/*.py`, symlinked into `~/.claude/` by the installer. Tests under `tests/` are shell scripts run via `tests/run-all.sh`. Lint shell with `shellcheck` + `shfmt`; lint/format Python with `ruff`.

## Agent skills

### Issue tracker

Issues live as GitHub issues on `millsmillsymills/claude-defaults` (via the `gh` CLI). See `docs/agents/issue-tracker.md`.

### Triage labels

Five canonical state roles map 1:1 to GitHub labels (`needs-triage`, `needs-info`, `ready-for-agent`, `ready-for-human`, `wontfix`); categories are `bug`/`enhancement`. See `docs/agents/triage-labels.md`.

### Domain docs

Single-context: one `CONTEXT.md` + `docs/adr/` at the root (created lazily by `/grill-with-docs`). See `docs/agents/domain.md`.
