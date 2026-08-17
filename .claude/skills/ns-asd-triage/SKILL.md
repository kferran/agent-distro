---
name: ns-asd-triage
description: Night-shift ASD triage — invokes the asd-triage skill end-to-end (vault-only), reuses the diagnosis cache provided in-prompt, and writes the night-shift status stub. Runnable solo. Triggers — "/ns-asd-triage".
allowed-tools: Read, Write, Edit, Glob, Grep, Bash, Skill
---

# ns-asd-triage

Night-shift ASD-queue triage. Night-shift process **P5**; also runnable on demand. This is a WRAPPER — it invokes the `asd-triage` skill end-to-end; it does NOT re-implement triage.

## Invocation
Invoked by the `night-shift-fanout` workflow as `/ns-asd-triage for LOCAL=<date>`, with the diagnosis cache provided in the invocation prompt (a JSON array of Cluster B's rows). Runnable solo: `/ns-asd-triage` (defaults LOCAL to today via `TZ=America/Denver date +%Y-%m-%d`; no cache → asd-triage self-pulls; see "Solo run").

## Artifact contract (PRIMARY OUTPUT)
Resolve `LOCAL` (from the invocation, else `TZ=America/Denver date +%Y-%m-%d`). This skill keeps `asd-triage`'s OWN-doc contract AND additionally writes the night-shift status stub:

- **asd-triage's own deliverable (preserve):** `00 Inbox/<LOCAL>-asd-triage.md` (the triage doc) + its own ASD instance log entry. Vault-only — no Drive upload, no external write.
- **Night-shift status stub (additionally write):** `00 Inbox/<LOCAL>-ns/P5.md` with frontmatter `process: P5`, `status: complete|failed`, an optional `needs_kyle:` list, and a body = the ASD headline + open/new/closed counts + a pointer `[[00 Inbox/<LOCAL>-asd-triage]]`. This is what the orchestrator's artifact glob reads in FINALIZE.

Do NOT commit/push; honor Confidential/ strict mode. Work from the vault root `/home/kyle/vault` (all relative paths resolve there).

## Procedure

PROCESS 5 — ASD triage (Cluster B projection): invoke the `asd-triage` skill end-to-end through Step 9 (vault-finalize) for date `<LOCAL>`. **Vault-only delivery — the doc `00 Inbox/<LOCAL>-asd-triage.md` is the deliverable; no Drive upload, no external write** (revised 2026-06-20 — documenting in the vault is sufficient). Drafts stay drafts; no Jira posts. Fold its headline + open/new/closed counts into the night-shift status stub (it also writes its own doc + its own ASD instance log).
- REUSE THE CACHE: the diagnosis cache (Cluster B's rows) is PROVIDED IN-PROMPT in your invocation as a JSON array. For any ASD ticket already in that cache, consume its root-cause / `file:line` / repro finding instead of re-investigating; only diagnose ASD tickets NOT in the cache. The skill's doc + coverage-validation contract is unchanged — this only dedups the investigation work. **If the provided cache is empty `[]`** (Cluster B failed or was skipped, or none was provided), the skill diagnoses normally — its own self-pull fallback.

After `asd-triage` completes, write the `00 Inbox/<LOCAL>-ns/P5.md` status stub per the artifact contract above (create `00 Inbox/<LOCAL>-ns/` with `mkdir -p` if it does not already exist). On any error, write the stub with `status: failed` and a short failure note so FINALIZE marks it ⚠️ rather than silently missing.

## Solo run
Invoked on demand as `/ns-asd-triage` with no LOCAL/cache context: invoke `asd-triage` normally — no cache provided, so it self-pulls and diagnoses its own scope. LOCAL defaults to today. Do NOT write the `00 Inbox/<LOCAL>-ns/P5.md` stub when run solo without a LOCAL/cache context — the stub is a night-shift-workflow artifact only. asd-triage's own doc + ASD instance log are still written (its standard behavior).
