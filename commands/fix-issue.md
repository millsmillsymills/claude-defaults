# Fix Issue

Takes a GitHub issue and autonomously completes it -- researches, plans,
implements, tests, creates a PR, self-reviews, and comments when done.

## Usage

```
/fix-issue <issue-number>
```

## Steps

1. **Read the issue**
   ```bash
   gh issue view $ARGUMENTS --json title,body,labels,comments
   ```

2. **Research the codebase**

   Use Glob, Grep, and Read to understand:
   - Which files are relevant to the issue
   - Existing patterns and conventions
   - Test structure and coverage
   - Related code that might be affected

3. **Plan the implementation**

   Write a short plan:
   - Root cause (for bugs) or design approach (for features)
   - Files to modify
   - Tests to add
   - Risks or edge cases

4. **Create a feature branch**
   ```bash
   git checkout -b fix/$ARGUMENTS
   ```

5. **Implement the fix/feature**

   - Make the code changes
   - Add or update tests
   - Run quality gates after each significant change

6. **Run full quality gates**
   ```bash
   # Project-specific linting, type checking, and tests
   ```

7. **Self-review**

   Launch parallel review agents on your own changes:
   - Code quality review
   - Security review
   - Test coverage review

   Fix any findings from the self-review.

8. **Create the PR**
   ```bash
   git push -u origin fix/$ARGUMENTS
   gh pr create --title "Fix #$ARGUMENTS: <title>" --body "## Summary
   <what was done>

   ## Test plan
   - [ ] <verification steps>

   Closes #$ARGUMENTS"
   ```

9. **Comment on the issue**
   ```bash
   gh issue comment $ARGUMENTS --body "Fixed in <PR-URL>. Changes: <brief summary>"
   ```
