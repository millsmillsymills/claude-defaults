# Merge Renovate

Evaluates and merges open Renovate PRs for a repository. Audits config,
batches overlapping PRs, evaluates each, and merges passing PRs sequentially.

## Usage

```
/merge-renovate <owner/repo>
```

## Steps

1. **Audit Renovate configuration**
   ```bash
   for p in renovate.json .github/renovate.json .renovaterc.json; do
     gh api "repos/$ARGUMENTS/contents/$p" --jq '.content' 2>/dev/null | base64 -d && break
   done
   ```
   Renovate reads the first config it finds, so report which path answered.
   Check `minimumReleaseAge` (the supply-chain cooldown), the `packageRules`
   that express grouping and scheduling, whether `helpers:pinGitHubActionDigests`
   is extended, and whether `lockFileMaintenance` is enabled in a repo with a
   lockfile. No config at all means Renovate is running on its defaults, which is
   worth saying out loud before merging anything it opened.

2. **List open Renovate PRs**
   ```bash
   gh pr list --repo $ARGUMENTS --author "app/renovate" --json number,title,headRefName,labels
   ```
   Renovate also keeps a Dependency Dashboard issue. It is an issue, not a PR, so
   it does not appear here; read it when the dashboard says an update is pending
   and no PR exists for it.

3. **Build dependency map**

   For each PR, identify:
   - Which packages it updates. A grouped PR carries several, so read the table
     in the PR body rather than the title
   - Current version -> target version
   - Whether each is a direct or transitive dependency
   - Whether it is a lock-file maintenance PR, which refreshes every pin at once
   - Overlapping PRs (multiple updates to the same package)

4. **Batch overlapping PRs**

   Group PRs that update the same package or have transitive conflicts.
   Keep only the highest-version PR from each group. Order a lock-file
   maintenance PR last: merging it first makes every other branch stale.

5. **Evaluate each PR in parallel**

   For each PR, launch a parallel agent:
   ```bash
   gh pr checkout <number> --repo $ARGUMENTS
   ```
   - Run the project's build
   - Run the full test suite
   - Check for breaking API changes in the changelog
   - Flag major version bumps for manual review

6. **Merge passing PRs sequentially**

   For each PR that passed evaluation:
   ```bash
   gh pr merge <number> --repo $ARGUMENTS --squash --auto
   ```
   After each merge, re-run tests on main to catch integration conflicts.

7. **Report results**

   Summarize:
   - PRs merged
   - PRs skipped (test failures, major version bumps)
   - PRs requiring manual review
   - Anything the Dependency Dashboard lists as pending with no PR behind it
