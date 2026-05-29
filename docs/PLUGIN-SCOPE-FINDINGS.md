# Plugin scope precedence (empirical, 2026-05-20)

**Question:** Does setting `enabledPlugins["X"] = false` in a project-scope
`.claude/settings.json` suppress a plugin enabled in `~/.claude/settings.json`?

**Status:** PENDING VERIFICATION — test directory prepped at
`/tmp/plugin-disable-test/.claude/settings.json` with
`plugin-dev@claude-plugins-official: false`.

**To verify (next time you open a fresh Claude Code session):**

1. `cd /tmp/plugin-disable-test/`
2. `claude` (or `claude-yolo`)
3. Inside the session, run `/agents` and look for `plugin-dev:plugin-validator`
   and `plugin-dev:agent-creator`.
4. Update this file: replace this section with **YES** (if the plugin-dev
   agents are absent — project-scope disable works) or **NO** (if they're
   still present — project-scope disable does NOT work).

**Result:** _Fill in once verified._

**Implication for design:**

- **If YES:** Workspaces can re-enable plugins on top of a trimmed global
  list, and any workspace can also explicitly disable a plugin via project
  scope. Full flexibility.
- **If NO:** Workspaces must work around it. Demoted plugins are removed
  from `~/.claude/settings.json` `enabledPlugins` entirely, and each workspace
  must re-enable the ones it needs. No project-scope disable mechanism.

Either way, Task 20 (the actual global trim) is the operative disable. This
empirical check just confirms whether project-scope override is available as
a future tool.

**Cleanup after verification:** `trash /tmp/plugin-disable-test`.
