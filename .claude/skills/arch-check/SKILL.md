---
name: arch-check
description: Architecture-readiness gate — before candidate code tickets go to the fleet, map each to the capability it needs and confirm that seam exists in code. Missing seam → route to Albert/Alex to scope, not the fleet. A cluster of tickets on one edge is an architectural signal. Two-tier: a fast coordinator-side capability-doc read, then a read-only code-verify X-Man when a gap is plausible. Read-only + propose; Kyle owns routing. Triggered by "/arch-check <tickets>", "capability-check these before we queue them", "any missing architecture for X before we work it".
allowed-tools: Read, Write, Edit, Glob, Grep, Bash
---

# Arch-Check — architecture-readiness gate

Coordinator-side **pre-dispatch gate**: given candidate code tickets about to be queued for the fleet, verify the platform already has the architectural capability/seam each fix needs. A missing seam means the fleet would hit a wall — that's a signal **Albert** (Chief Architect) + **Alex** (Frontend Architect) need to scope the work, not a ticket to dispatch.

Origin: 2026-07-19 (Kyle) — proposed and validated in the same session; on first run it caught a Trust/entity-owner cluster and correctly held three "clean-looking" bugs out of the queue until their seams were code-confirmed.

**Where it sits:** between triage / candidate-selection and queuing. Clean → hand to `dispatch`/`intake` for the fleet. Gap → an architect scoping packet. It **never** auto-queues, never files architect work, never transitions Jira — Kyle owns routing (deliver-don't-distribute).

## Invocation
- `/arch-check <EJA/ARCH keys>` — check a named set.
- `/arch-check` on the current candidate set (tickets just triaged / about to queue).
- "capability-check these before we queue them" / "any missing architecture for `<X>`".

## Activation (how it fires)
**Enforced inside dispatch — ON by default** (Kyle, 2026-07-19; design [[arch-check-queue-gate]]). The `dispatch` skill's code branch runs this gate at **C1b**, before spawning any conductor, on **every `code` item that is not `autonomy: build-direct`**. So every non-mechanical ticket bound for the fleet passes through it automatically — it can't be skipped. The bypass is the `build-direct` flag (pre-vetted mechanical fixes skip it, same flag that skips spec-approval). Dispatch handles the three outcomes: PRESENT → spawn; UNCERTAIN → hold the conductor + park the item pending the verify; GAP → divert to Albert/Alex, don't spawn.

Still directly invocable on-demand (`/arch-check <keys>`) to check a candidate set ahead of time or outside the dispatch path.

## Scope
Read-only assessment + propose. The only thing it spawns is a **read-only research X-Man** for code-verification (never a code/ops write). It maps tickets to capabilities; it does not fix, queue, or file architect work itself.

## Steps

### 1. Pull the candidate tickets + the epic guard
Fetch each ticket via the Atlassian MCP (summary, description, issuetype, priority, issuelinks/mirror, status).
- **Jira bulk-query overflow (standing friction):** `searchJiraIssuesUsingJql` overflows to a file for more than ~5 issues (ADF bodies). Run the query in-session with minimal `fields`; when it overflows, **extract a compact index from the saved file rather than reading it raw** (`jq` over `.issues.nodes[]`, or the helper `scripts/jira-index <file>` — flags `--open`/`--unassigned`/`--count`/`--tsv`/`--mirrors`). Never read the raw overflow file into context.
- **Check issuetype + mirror FIRST (the epic guard):** if a ticket's mirror is an **Epic** (a change-order / multi-story container) or a **product-owned decision** (unassigned, "the final word on X", PO-owned), it is **not a discrete code fix** — flag it for decompose / product-decision and drop it from the capability check. Grilling or queuing an epic as one code item is a category error (2026-07-19: `EJA-3602` Forms Change Order, `EJA-3552` Joint-Life labeling decision both looked like dev items but were epics).

### 2. First pass — map ticket → capability (coordinator-side, fast)
For each remaining ticket, per the **retrieval rule** (name the notes it rests on): *what capability/seam must exist to do this fix?* Resolve against:
- `03 Resources/ultron/capabilities/` (the capability docs + `index.md`) and `03 Resources/ultron/capabilities-brief.md` (the Hardened / Partial / Gap read).
- the matching domain wiki (`02 Areas/platform/<domain>/wiki.md`).
- `03 Resources/ultron/edj-baked-in-assumptions.md` (the missing-seam catalogue).

Classify each: **PRESENT** (the mechanism clearly exists — a rule/config/prop the fleet can reuse) · **GAP** (no seam — clearly needs a new capability) · **UNCERTAIN** (plausible either way; needs code to settle).

### 3. Cluster-detect
If ≥2 candidates touch the same architectural edge (same owner-type, same seam, same subsystem), treat the cluster as **one signal** — a recurring edge is stronger evidence of a missing canonical seam than any single ticket. Name the cluster.

### 4. Code-verify tier — dispatch when UNCERTAIN or a cluster is flagged
**Never assert a gap from the docs alone** (verify-before-assert). For any UNCERTAIN ticket or flagged cluster, dispatch ONE read-only research X-Man (`scripts/cerebro/cb-start --research <slug> --target ultron`) with a capability-verification brief that:
- confirms the "PRESENT" seams actually exist (`file:line` of the reusable mechanism), and
- determines whether the cluster is a **shared missing seam** vs **independent per-form bugs** — `file:line` evidence either way.
- consumes any related **live RCA** (don't duplicate its root-cause).

Fire-and-forget; `/ingest` the verdict when it lands. (Model brief: the 2026-07-19 `trust-owner-capability-gap` task — confirm-present checks + a Trust/entity-owner shared-gap-vs-independent-bugs verdict.)

### 5. Route the verdict (propose, never auto-act)
- **PRESENT (code-confirmed)** → clean to queue: hand back to `dispatch`/`intake` for the fleet.
- **SHARED GAP (code-confirmed)** → the X-Man's report **is** the architect scoping packet — the missing capability + the ad-hoc code paths it would replace (`file:line`). Deliver to a Kyle-controlled surface; **Kyle** routes it to Albert/Alex.
- **Epic / product-decision** (from step 1) → decompose or route to product.

State it as a short recommendation, not a menu. **Hold the "clean" tickets OUT of the queue until their seams are code-confirmed** — that gate is the entire point of the skill.

## Guardrail
- Read-only + propose. Never queue a ticket, never file architect work, never transition Jira — Kyle owns routing.
- Never assert a capability gap from the capability docs alone — a plausible gap is code-verified before it becomes an architect signal.
- The code-verify X-Man runs the research contract (read-only everywhere; writes only `report.md`).
