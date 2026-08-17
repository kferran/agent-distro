---
name: ticket-handle
description: Umbrella dispatcher for handling any Jira ticket — classifies to its true type and routes to a per-type treatment that produces a vault-draft terminal artifact. Epic/change-order/story path implemented (an epic like EJA-3599 comes out decomposed + split: code children conductor-ready, non-code children a PO-ready plan); bug-code path implemented (RCA-lift → mirror-resolve → conductor spawn). Triggers — "/ticket-handle EJA-XXXX", "handle <ticket/epic>". Part of the ticket: family (design 99 Meta/specs/2026-07-10-ticket-handler-design).
allowed-tools: Read, Write, Edit, Glob, Grep, Bash
---

# ticket-handle

Vault-side front-end for handling **any** Jira ticket: classify it to its true type, route it to a treatment, and produce a **terminal artifact** (a vault draft). Code-bound work hands off to the autofix → `ultron:work-conductor` spine; non-code types (change-orders, product asks, data gaps) get their own drafts — so nothing just "gets logged."

Design: [[99 Meta/specs/2026-07-10-ticket-handler-design]]. Part of the `ticket:` family (`ticket:rca` / `ticket:autofix` / `ticket:triage` / `ticket:deploy-verify` — namespaced in a later phase; referenced by current names for now).

## Invocation
`/ticket-handle <KEY>` — a single ticket, or an **Epic** (recurses into children). Read-only on code; writes only a vault draft; no Jira writes (except the `/autofix` flow's existing claim/PR on the bug path); honors `Confidential/`.

## Step 1 — Classify
Resolve `LOCAL` (`TZ=America/Denver date +%Y-%m-%d`). Classify the ticket per [`classification.md`](classification.md) — **cache-first** (reuse a `00 Inbox/<LOCAL>-ns/clusterB.md` disposition if present), else a read-only Jira fetch. Emit the classified type + a one-line rationale. If `needs-classification`, stop and surface — never guess.

## Step 2 — Route
| Classified type | Treatment ([`treatments.md`](treatments.md)) | Phase 1 |
|---|---|---|
| **epic** | recurse into children + split (code vs non-code) | ✅ |
| **change-order** | PO-ready batch plan | ✅ |
| **story** | scope-to-dev-item draft | ✅ |
| **bug-code** | RCA-lift → mirror-resolve → conductor spawn | ✅ |
| **bug-gapped** | owner-handoff draft | stub |
| **product-AC** | product-decision brief | stub |
| **non-actionable** | close/verify recommendation | ✅ |

## Step 3 — Treat
Run the treatment for the classified type per [`treatments.md`](treatments.md).
- **epic** — recurse: fetch children via `ultron:jira-context`, classify each, split code-bound from non-code, roll up.
- **bug-code** — run the bug-code treatment: RCA-lift (reuse a SPAWN-READY `*-rca-<KEY>.md`, re-baselined against live `main`, else `/rca`) → mirror-resolve (`self` / `mirror-exists` / `no-mirror: draft-required`) → spawn (claim existing mirror, or draft a fresh EJA mirror gated on Kyle's create, then spawn the conductor).
- **story / change-order / non-actionable** — per their `treatments.md` modules.

Never build code. Never create Jira issues except autofix's claim on an existing ticket + a per-item-approved `createJiraIssue` for a drafted mirror.

## Step 4 — Output
Write the terminal artifact to `00 Inbox/<LOCAL>-ticket-handle-<KEY>.md` per the output contract in [`treatments.md`](treatments.md). `outcome` ∈ `handled | decomposed | spawned | mirror-draft-pending | already-fixed | stub-pending | needs-classification`. On-demand, also return the headline inline. Nothing committed/pushed (rides Kyle's `/push`); nothing routed outward (Kyle routes).

## Boundaries
Vault-Claude, read-only on code. All code *writing* delegates to `ultron:work-conductor` via the scoped dev-item + spawn hand-off (the autofix→conductor flow). Never merges, never posts to Jira beyond `/autofix`'s existing claim, honors `Confidential/`.
