# README Connective Prose Between Bullet Lists

This project does not add connective prose to break up the inline-header
bullet lists (`- **Header** -- description`) used throughout `README.md`.

## Why this is out of scope

The writing-voice standard flags long runs of inline-header bullets as a
potential AI-smell, and a triage pass raised whether the README's Settings,
Sandboxing, Hooks, and Logging sections should get lead-in sentences so the
bullets read as elaboration rather than a bare dump.

On inspection the concern doesn't hold for this repo:

- Three of the four flagged sections already carry a lead sentence —
  `The template includes:`, `...block access to credentials and secrets:`,
  and `In practice, use them to:`. The bullets are already framed.
- The bullets map 1:1 to config keys, deny-rule groups, and hook events.
  This is reference material, and an inline-header list is the right shape
  for it — the same role the existing Hook-events and MCP-server tables play.
- The repo's own philosophy is terse, no-fluff prose. Inserting connective
  sentences purely to avoid a list pattern would add the kind of padding the
  standard elsewhere tells us to cut.

The writing-voice review verdict for the repo was Clean (zero hard-rule
violations); this was the only recurring stylistic note, and it's a
defensible format choice rather than a violation.

If a future section genuinely lacks framing (as the Logging section briefly
did), add a single lead sentence there — but don't convert the reference
lists into prose wholesale.

## Prior requests

- #104 — "docs: consider connective prose between inline-header bullet lists in README"
