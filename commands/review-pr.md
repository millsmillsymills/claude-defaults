# Review PR

Review a GitHub pull request with parallel agents, fix findings, and push.

## Usage

```
/review-pr <pr-number>
```

## Steps

1. **Fetch PR details**
   ```bash
   gh pr view $ARGUMENTS --json number,title,body,baseRefName,headRefName,files
   gh pr diff $ARGUMENTS
   ```

2. **Check out the PR branch**
   ```bash
   gh pr checkout $ARGUMENTS
   ```

3. **Run parallel review agents**

   Launch these review agents in parallel using the Task tool:

   - **pr-review-toolkit** (`/pr-review-toolkit:review-pr $ARGUMENTS`): Runs 6 specialized
     agents -- comments, tests, error handling, type design, code quality, simplification
   - **Architecture review**: Evaluate system design, module boundaries, dependency direction
   - **Security review**: Check for injection, auth bypass, secret leaks, OWASP top 10

4. **Collect and deduplicate findings**

   Merge results from all agents. Remove duplicates. Group by severity:
   - **Must fix**: Security issues, correctness bugs, data loss risks
   - **Should fix**: Code quality, missing tests, poor error handling
   - **Consider**: Style, naming, minor simplifications

5. **Fix must-fix and should-fix issues**

   For each finding:
   - Read the relevant file
   - Apply the fix
   - Run the project's test suite to verify

6. **Run quality gates**
   ```bash
   # Detect and run project-specific checks
   # Python: ruff check --fix && ruff format && ty check && pytest -q
   # Node: pnpm lint && pnpm typecheck && pnpm test
   # Rust: cargo clippy && cargo test
   ```

7. **Commit and push fixes**
   ```bash
   git add -u  # Stage only modified tracked files, never use git add -A
   git commit -m "fix: address PR review findings"
   git push
   ```

8. **Post summary as PR comment**
   ```bash
   gh pr comment $ARGUMENTS --body "## Review Summary
   - X must-fix issues found and resolved
   - Y should-fix issues found and resolved
   - Z suggestions for consideration"
   ```
