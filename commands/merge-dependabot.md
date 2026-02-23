# Merge Dependabot

Evaluates and merges open Dependabot PRs for a repository. Audits config,
batches overlapping PRs, evaluates each, and merges passing PRs sequentially.

## Usage

```
/merge-dependabot <owner/repo>
```

## Steps

1. **Audit Dependabot configuration**
   ```bash
   gh api repos/$ARGUMENTS/contents/.github/dependabot.yml | jq -r '.content' | base64 -d
   ```
   Review update frequency, ignored deps, and grouping rules.

2. **List open Dependabot PRs**
   ```bash
   gh pr list --repo $ARGUMENTS --author "app/dependabot" --json number,title,headRefName,labels
   ```

3. **Build dependency map**

   For each PR, identify:
   - Which package is being updated
   - Current version -> target version
   - Whether it's a direct or transitive dependency
   - Overlapping PRs (multiple updates to the same package)

4. **Batch overlapping PRs**

   Group PRs that update the same package or have transitive conflicts.
   Keep only the highest-version PR from each group.

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
