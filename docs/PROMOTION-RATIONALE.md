# Why nothing was promoted from `resurgent/.claude/`

The `resurgent` project (`~/Desktop/Projects/resurgent/`) has the most mature `.claude/` setup of any project: 8 agents, 11 skills, 10 commands, custom hooks, templates, docs, workflows. During design we audited each item for "should this go global?" and answered no for everything. This doc records why, and which items might become future-work generalization candidates.

## Audit table

### Agents (8)

| Agent | Why not promoted |
|---|---|
| `homelab-health-checker` | References Prometheus/Loki/toolkit-specific paths |
| `media-stack-diagnostician` | 7-service media pipeline; 16 modules tied to homelab |
| `security-auditor` | Calls bandit/dependency-audit on `toolkit/` paths; pr-review-toolkit covers generic |
| `config-drift-detector` | Compares against SCD snapshots in homelab format |
| `test-failure-investigator` | Hooks into homelab solutions KB |
| `ci-failure-analyzer` | GH Actions specific to resurgent's workflow files |
| `performance-regression-detector` | Benchmarks tied to toolkit modules |
| `homelab-operator` | Operational runbooks for /mnt/user, docker compose unified |

The compound-engineering and pr-review-toolkit plugins already provide generic agent equivalents (security-reviewer, performance-reviewer, code-reviewer, etc.).

### Skills (11)

| Skill | Why not promoted |
|---|---|
| `deploy-stack` | Docker Compose profile-specific |
| `media-health` | Media stack only |
| `run-ci-local` | Toolkit-specific lint/format/types/tests pipeline |
| `scd-snapshot` | SCD format is homelab-specific |
| `compound-knowledge` | KB schema homelab-specific (compound-engineering plugin covers generic) |
| `dependency-audit` | pip-audit on toolkit's pyproject; codex/compound plugins cover generic |
| `media-reconcile` | Cross-service media-only |
| `gen-test` | Tests follow toolkit conventions |
| `review-pr` | pr-review-toolkit plugin is the generic version |
| `security-scan` | bandit+safety+semgrep wrapper on toolkit; security-guidance plugin covers generic |
| `release` | Release workflow uses homelab-specific tagging |

### Commands (10)

| Command | Why not promoted |
|---|---|
| `/health` | System health check for homelab containers |
| `/stats` | Homelab metrics summary |
| `/benchmark` | Performance benchmarking against toolkit |
| `/container-logs` | Docker compose specific |
| `/find-files` | Thin wrapper around `fd` -- Claude does this natively |
| `/quick-fix` | Generic but minimal value over native Edit |
| `/search-code` | Thin wrapper around `rg` -- Claude does this natively |
| `/settings-health` | Validates resurgent's specific settings hierarchy |
| `/changelog` | Useful but lightweight; better as a per-project command |
| `/review-homelab` | Multi-agent review tied to homelab agents |

## Future generalization candidates

If a pattern recurs across other projects, consider extracting the generic core into a global agent/skill/command and parameterizing the project-specific bits:

- **`gen-test`** -- could become a generic "infer test from production code" skill if conventions are project-detected
- **`security-scan`** -- bandit + safety pattern is generic; promote if the security-guidance plugin proves insufficient
- **`dependency-audit`** -- pip-audit / cargo deny / pnpm audit per detected language; could be a unified skill
- **`compound-knowledge`** -- compound-engineering plugin's `ce-compound` already covers this; nothing to promote

When promoting, follow `docs/HOOKS.md`'s "Adding your own hook" pattern but for the appropriate component type.
