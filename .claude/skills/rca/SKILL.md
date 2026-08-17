---
name: rca
description: Root-cause analysis on a single bug. Runs the shared diagnosis procedure at deep depth (Vault-side, read-only on code) and writes a durable RCA doc to 00 Inbox/ (root cause + file:line + confidence + repro); on a high-confidence mechanical fix, includes a ready-to-spawn dev-item fix brief. Triggers — "/rca", "root cause this bug", "what's actually wrong with EJA-XXXX".
allowed-tools: Read, Write, Glob, Grep, Bash, mcp__plugin_atlassian_atlassian__getJiraIssue
---

# RCA — root-cause analysis (single bug, deep)

Deep single-bug front-end on the shared diagnosis procedure (`03 Resources/reference/diagnosis-procedure.md`). Vault-side, **read-only** — reads the worktree, Kusto logs, and the ticket; never edits code or runs tests. Diagnose-and-hand-off.

## Invocation
`/rca <EJA-key | ASD-key | free-text symptom>`.

## Seed from the night-shift cache (if present)
Before diagnosing, check today's (and recent) `00 Inbox/<date>-night-shift.md` `## Diagnosis cache` for a row matching the ticket. If found, START from it ("the night shift got this far overnight — go deeper"): take its root-cause hypothesis + `file:line` + repro status as the starting point and deepen, rather than re-tracing from scratch. The cache row columns map: `Root-cause hypothesis`→starting hypothesis, `file:line`→trace start, `Repro status`→repro baseline, `RC-conf (1-5)`→starting root-cause confidence (deepen from there), `Kusto`→the K-code to re-run if deeper logs are needed.

## Run
Follow the shared procedure at **`deep` depth**, field-rubric per project (EJA→strict-EJA, ASD→opportunistic-ASD; free-text symptom → opportunistic). Trace exhaustively across the call path; cross-reference Kusto if a K-code exists. Read-only throughout.

## Output — ALWAYS write a durable RCA doc + summarize in chat
Write the finding to `00 Inbox/<LOCAL>-rca-<key-or-slug>.md` (`<LOCAL>` = `TZ=America/Denver date +%Y-%m-%d`; `<key>` for a ticket, a short kebab slug for free-text) **and** render a short summary in chat. Frontmatter: `date: <LOCAL>`, `type: rca`, `ticket: <key>` (omit if free-text), `rc_confidence: <1-5>`, `status: diagnosed`. The doc contains:
- **Root cause** — the real underlying issue, not the surface symptom.
- **`file:line`** anchors in `~/code/worktrees/main`.
- **Root-cause confidence (1-5)** + repro status.
- The **fix brief** (when fix-confidence is high — see below), or the **open design call** / **Remote-spawn recommendation** when those apply.
- A **doc-gap note** if the symptom isn't covered by any capability page → routed to the enrichment loop / `ultron:knowledge-manager` (the "train up" hand-off; `/rca` records the diagnosis, not the learning store).
- A **glossary-flag note** if the ticket or the code trace surfaces a load-bearing domain term/acronym (a class name, config key, or ticket phrase) that is **not** in `03 Resources/glossary.md`. Do **not** infer its meaning into the RCA doc from surface cues (the DPfA class of miss — CLAUDE.md § Analysis approach → verify-before-assert, check 1): flag it as a **proposed glossary addition** (term + best-effort scope tag + "meaning unconfirmed — needs Kyle/source") and, where the meaning is load-bearing for the diagnosis, resolve it against the source or say the diagnosis is contingent on it. Never auto-add to the glossary; Kyle owns canonical terms.

This RCA doc is the durable record. Over time `00 Inbox/*-rca-*.md` accrue into a corpus of root causes for pattern-spotting.

## When fix-confidence is high (~4-5): prep a fix brief
Derive autonomous-fix confidence (procedure's DERIVED rubric). If ~4-5, include a **ready-to-spawn dev-item fix brief** in the RCA doc, shaped to `99 Meta/templates/dev-item.md`: Goal, the change at `file:line`, Constraints, repro/AC. Vault-Claude scopes it; **Kyle spawns** (the RCA doc is ready to promote to a dev item). NEVER spawn a worktree or edit code.

Carry the brief's `file:line` paths into a **`files:`** frontmatter line (comma-separated, paths only, no line numbers). This is the cheapest place in the whole pipeline to populate it — a high-confidence RCA has already proven which files the fix touches, which is exactly what R5 dispatch serialization needs and cannot infer for itself. It makes `cb-start` refuse, and intake hold the item queued, when a live conductor is already in those files. Only the files the fix itself changes; supporting files you merely read while diagnosing do not belong there, since a wrong entry buys a false refusal.

## When the cause is clear but the fix is a design call (RC-conf high, fix-conf 3)
Root cause confirmed but the fix is an open design/scope choice (not mechanical) → report the cause + `file:line` + root-cause confidence, **name the open design call explicitly**, and stop. No fix brief (fix-conf <4), no spawn recommendation (the cause isn't the blocker — the decision is). Kyle makes the call.

## When live reproduction is needed
If static analysis can't confirm the cause (caps confidence at ≤3), say so explicitly and **recommend a Remote-Claude spawn** (the dev-item→worktree handoff) to reproduce/confirm live. Do not attempt it Vault-side.

## Outward-text check — run the detector before anything is drafted for posting

Any text this skill drafts for a human to read outside the vault — a Jira comment, a reporter ask, a
reply to QE — goes through `avoid-ai-writing`'s detector before it is handed to Kyle. Rules in context
are not self-enforcing: on 2026-08-09 a comment drafted for QE was hand-audited against
`personality.md`, declared clean, and the detector then scored it **4** on a surviving em dash and
uniform paragraph length. Neither came out of reading the rules carefully.

```bash
node -e 'const {analyzeText}=require("/home/kyle/vault/.claude/skills/avoid-ai-writing/detector/patterns.js");
const t=require("fs").readFileSync(process.argv[1],"utf8");
const r=analyzeText(t,{context:"casual"});
console.log(r.score); console.log(JSON.stringify(r.issues,null,1));' /tmp/draft.txt
```

⚠️ The result key is **`issues`**, not `findings` — reading the wrong key returns an empty array and
looks like a clean pass.

**Context profile:** `casual` for Jira comments and Slack. Not the default `blog` profile, which
converts bullets to prose and would fight the house style. **Iterate to score 0** before handing the
draft over, and keep `personality.md` canonical wherever the two disagree.

## Guardrails
Read-only on **code** (no edits to `~/code/worktrees/main`, no test runs); the one vault write is the RCA doc in `00 Inbox/` (+ the fix-brief→dev-item stub on promotion). No Jira writes beyond reading the issue; no auto-spawn; no commit/push. Honor Confidential/.
