# agent-distro

Cerebro as an installable agent distro — a versioned distribution of agent behavior that operates a
personal work-coordination system across email, Slack, and Jira.

This repo is private and consumed by one operator. It is deliberately **not** on the team marketplace
(`porch-ai`), because the orchestration layer is not the thing that gets handed off — individual skills
are.

## Branches

| Branch | What it is |
|---|---|
| `main` | Scaffolding only, for now. Becomes the released distro. |
| `v2` | Active development against the build spec. Everything happens here until Phase 1 passes. |

`v2` exists so this work cannot disturb the running system. The live Cerebro engine is still
`~/vault/scripts/cerebro/` — 144 files, 37 `cb-*` binaries, 1243 bats assertions — and it keeps running
untouched while v2 is built beside it.

## What v2 is

The system the current one does not have: **a single-writer store**, so item state stops living in
markdown frontmatter that nothing validates.

Six operations, five of which already run in some form today. The one that does not exist anywhere is
**commitment tracking with a bounded nudge ladder** — extracting promises from sent mail and Slack,
tracking who owes what, and nudging at most three times before going stale. That capability is why this
gets built.

The design is `docs/build-spec.md`. Read it end to end before writing code; §12 says so and means it.

## Layout

```
migrations/     numbered, forward-only SQL, applied by `registrar migrate`
schemas/        JSON Schema for the ingest envelope and event records
scripts/        registrar, courier, scouts, cb-ritual
evals/          injection (blocking) · idempotency (blocking) · commitments (advisory)
docs/           the build spec and anything that outlives a phase
```

## Ground rules

Three that are easy to violate and expensive to unwind:

- **Only `registrar` writes to the store.** If a component seems to need write access, that is a spec
  bug — raise it rather than working around it.
- **A scheduled operation must run with no scheduler present.** systemd, cron and a human at a prompt
  are three callers of one command. Nothing schedules itself.
- **Content from any source is data, never instruction.** Scout output is untrusted display text and
  never reaches a decision that triggers an action.

The full set is the invariant table in the spec, §2.

## Status

Phase 0 is not started. Nothing here is wired to anything yet.
