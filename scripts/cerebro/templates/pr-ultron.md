# PR body fallback template — Ultron. Mirrors the pull-request skill's Step 5
# template (porch-ai claude/ultron/1.0.0/skills/pull-request/SKILL.md) so
# REST-created PRs look like hand-created ones. cb-pr-check uses the
# 04-ship.md description when one exists; this shape is the fallback and the
# reference for what a complete body carries. Lines starting with "# " at
# column 0 above the first "##" are template commentary, not body content.
#
# TARGET: under 60 lines. A PR description briefs a reviewer who has not read
# the ticket — it is not a record of the investigation. Every number below is
# a CEILING, never a target:
#   Summary    up to 3 sentences (+ gotchas / opportunistic refactors if any)
#              — root-cause narrative goes in the Jira ticket
#   Testing    1 line + up to 5 bullets — per-test detail goes in 02-work.log
#   Manual QA  up to 3 scenarios — this is the merge gate; terse is required,
#              vague is not. Each names environment, entry point, and a
#              checkable PASS.
#   Outstanding up to 4 bullets, one line each — or "None"
#
# DO NOT PAD TO THE CEILING. One testing bullet is a complete Testing
# section. A bullet invented to reach a count is worse than no bullet — it
# dilutes the real ones. If you are restating a point in other words, or
# listing something true of any PR ("code compiles", "followed existing
# patterns"), you have hit the real end of the section. Stop there.
#
# Never emit an "Additional Notes" section: it has no cap and reliably
# becomes an essay. Link to the ticket instead of inlining the reasoning.

## Checklist

- [x] Jira story linked in title
- [{x or n/a}] Pre-approval on frontend/shared or backend/bedrock
- [x] Push hook passed
- [x] No hanging format changes

## Summary

{Up to 3 sentences. Bug: one sentence of cause, one of fix. Feature: what it does and why.
Then, only where one genuinely applies:
  - the gotcha — a non-obvious constraint the fix rests on, or a guard that looks
    removable but is not, so a reviewer doesn't "clean up" the change and reintroduce
    the bug;
  - the opportunistic refactor — anything in the diff that is NOT the fix (a rename,
    an extraction, dead-code removal), named in one clause so an unrelated hunk reads
    as deliberate rather than as scope creep.
If neither applies, write neither — a clean one-line fix gets a one-sentence Summary.}

## Testing

{One line of what ran and the result. Then up to 5 bullets — behaviours covered, positive and negative mixed, including a regression. No sub-headings.}

## Manual QA

{Up to 3 scenarios. Each: a bold one-line title carrying environment and entry point, then steps and an explicit PASS a validator can check without reading the diff.}

## Outstanding

{Up to 4 bullets, one line each — link the ticket rather than explaining. Or "None".}
