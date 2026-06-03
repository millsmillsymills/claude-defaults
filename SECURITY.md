# Security Policy

## Reporting a vulnerability

Please report security issues privately rather than opening a public issue.
Use GitHub's **Report a vulnerability** button under the repository's
**Security** tab to open a private advisory. Include a description, affected
files, and reproduction steps if you have them.

## Scope

This repository is configuration for Claude Code: shell/Python hooks, an
installer, settings templates, and docs. The hooks are defensive (they block
destructive commands, warn on sensitive file edits, and redact secrets from
logs) and run locally on the operator's machine. There is no network service.

## Expected secret-scanner findings

Some files contain **synthetic** secret-like strings on purpose. They are test
fixtures, not real credentials, so public secret scanners will flag them and
those alerts are expected:

- `tests/test-redaction.sh` and `tests/test-redact-existing.sh` carry fake
  API keys, tokens, JWTs, and `password=`/`token=` strings used to verify the
  redaction patterns in `hooks/lib/`. None correspond to a real account.

If you find a credential in the history that looks real (not one of the above),
report it via the private advisory process above.
