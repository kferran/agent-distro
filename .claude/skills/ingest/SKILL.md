---
name: ingest
description: Coordinator skill — fold the findings automation will not touch back into the vault's knowledge base. Reports file themselves (cb-land) and their prose is integrated by the nightly distill pass; what reaches this skill is the residue — a finding whose home is People/, a confidential-clearance report the lander refused to file, and anything the distiller declined as ambiguous. Code — consumes the cb-cleanup distill queue, proposes the domain-wiki enrichment + dev-item archive per the development README completion rule. Always waits for confirmation before writing. Triggered by a decline line in the distill summary, a surfaced-not-filed line in the vault-maintenance ratify worklist, a distill-queue line, or "ingest <slug>".
allowed-tools: Read, Write, Edit, Glob, Grep, Bash
---

# Ingest — the findings automation will not touch

Coordinator-side "propose and wait" step. Mirrors `/meeting-synthesis`'s routing discipline: read the source, propose a destination, never write without confirmation. Full model: `99 Meta/Cerebro-spec.md` §8.4.

**This skill no longer files reports, and it is no longer the step a finished X-Man waits on.** A terminal research/ops report files itself into `00 Inbox/` at a path computed before the agent ran (`cb-land`, triggered from `cb-watch`), and the nightly distill pass integrates its prose into the page that owns it (`/eod` Step 6.13 → `.claude/skills/distill/SKILL.md`). What is left for a human-in-the-loop turn is the residue those two deliberately will not touch:

- a finding whose home is **`People/`** — the distiller never writes there, so every one of them is a decline by construction;
- anything **`clearance: confidential`** — the lander refuses to file it and surfaces it instead;
- anything the distiller **declined as ambiguous** — an unclear destination is a legitimate outcome for it, and declining costs nothing precisely because this skill picks the decline up.

Do not re-file a report that has already landed, and do not redo an integration the distiller already made — its summary names every write it did.

## Invocation

Four triggers, and the first three all point at a residual finding rather than at a task:

1. **A line under `## Declined` in `00 Inbox/<LOCAL>-distill-summary.md`** — the distill pass read the landed report and routed this finding here with a reason.
2. **A finding whose home is `People/`**, whether the distiller named it or you spotted it in a landed report.
3. **A line under `## cb-land — surfaced, not filed` in `00 Inbox/<LOCAL>-vault-maintenance-ratify.md`** — a `confidential`-clearance report the lander would not write into the vault. ⚠️ This one is **not** in the Inbox: the report is still at `~/.cerebro/tasks/<slug>/report.md` and it stays there (`$CB_HOME/logs/land-surfaced` carries the same lines for the fleet).
4. A code task hitting `done` / a line in `~/.cerebro/logs/distill` (written by `cb-cleanup` after a merged PR's reap) — the **Code completion** branch at the end, unchanged.

Kyle saying "ingest `<slug>`" still works and overrides all of it.

## Scope

Two branches: the **residual findings** above (the flow below) and **code-completion distillation** (PR merged → wiki enrichment + dev-item archive — see "Code completion" at the end). Both are propose-then-confirm; neither ever auto-writes a wiki.

## Steps

### 1. Read the source — two shapes, and they are not in the same place

**A landed finding** (triggers 1 and 2) — read the `00 Inbox/` file:

```bash
cat "00 Inbox/<LOCAL>-<kind>-<slug>.md"
```

It is the report verbatim, with provenance inserted into its frontmatter: `landed_from` (the task-dir report it came from), `landed_slug`, `landed_kind`, `landed_at`. For a distiller decline, read the `## Declined` entry too — its reason is what you are resolving, and re-deriving it wastes the pass.

**A surfaced-not-filed report** (trigger 3) — nothing landed, so read the task dir:

```bash
cat ~/.cerebro/tasks/<slug>/report.md
```

If neither exists, the trigger is stale — say so and stop; don't infer a finding from `brief.md` alone.

Frontmatter carries `status` (complete/partial/failed), `confidence` (high/medium/low), and `promote_to` (none/code).

- `status: failed` — nothing to ingest. Report the failure and stop.
- `status: partial` — proceed, but flag the gaps section prominently in the proposal; don't let a partial finding read as settled.

### 2. Confidential gate — check before anything else

This gate bites on the surfaced-not-filed shape. For a finding that already landed, it is spent — `cb-land` reads the same field and would not have filed a confidential report — so check it once and move on rather than re-deriving it.

Read `clearance:` from the task's `~/.cerebro/tasks/<slug>/brief.md`. If it is **`confidential`**, **do not propose a vault landing.** Surface the report's Answer/Evidence to Kyle directly in the conversation and stop. A confidential-clearance report is never auto-filed, never distilled into a `03 Resources` page, never routed to Inbox by this skill — filing sensitive content is always Kyle's explicit call, same as any other `Confidential/` content. This is the whole reason trigger 3 exists.

**A missing or empty `clearance:` is not a confidential signal — treat it as `standard`.** This inverts the old fail-safe, deliberately (2026-08-14): the field is written by `cb-brief` now, so an absent one is a scaffold bug rather than a sensitivity signal, and `cb-land` has already filed the report into `00 Inbox/` on exactly that basis — refusing here would strand a finding the fleet has already published. A **declared** `confidential` still blocks absolutely, and an unrecognised value is treated like `confidential` (the lander does the same).

### 3. Propose a landing

Following the vault's retrieval rule and wiki conventions, work out where the finding belongs — don't guess silently, propose it. Two destinations are yours specifically because nothing automatic may take them:

- **A person's file** → `People/<Name>.md`, integrated into Context prose per [[People/CLAUDE]] — never an "Update:" line. Interpersonal content is Kyle's call every time.
- **Anything the distiller declined for ambiguity** → resolve the ambiguity and name the winner, or say plainly that it needs Kyle to choose.

The rest of the map, for a finding that reaches you some other way:

- **Existing `03 Resources` page covers this topic** → propose refining that page (integrate into existing sections; restructure only if the new material exposes a better structure). Name the page.
- **No existing page, but the finding is durable/cross-cutting** → propose a new `03 Resources/` (or `03 Resources/technical/`) page, with a working title.
- **Finding is scoped to a live project or dev item** → propose an update to that project's `overview.md`/`notes.md`, or the relevant dev item in `00 Inbox/` — link the task's `related_project`/`domain` if the brief carried one.
- **Finding is domain-specific technical knowledge (ownership, forms, products, case-flow, carriers, or a platform hub)** → propose refining the matching `02 Areas/platform/<domain>/wiki.md` or `03 Resources/technical/<platform>.md` hub, per the domain knowledge layer conventions — often the closest fit for engineering-research findings, ahead of a brand-new page.
- **Not sure it's dedicated-home-worthy yet** → say so and propose nothing. Do **not** write an Inbox stub: a landed finding is already sitting in `00 Inbox/` awaiting triage, so a stub duplicates it, and a surfaced-not-filed one is confidential and must not go there at all.

These aren't mutually exclusive — a finding can warrant both a dev-item/wiki update and a resource-page refinement (e.g. it both confirms a bug still open on a tracked dev item and belongs in a platform wiki's operational signals). Propose both when both apply, rather than forcing a single destination.

State the proposal as a short recommendation (destination(s) + one line why each), not an open-ended menu — same fork discipline as any other routing decision.

If `promote_to: code` is set in the report, say so as part of the proposal — the finding recommends a follow-on code task. Check the brief's Context for an existing related dev item first; if one exists, propose reactivating/updating it rather than spawning a fresh one. Either way, don't spawn or dispatch anything yourself — that's Kyle's call (route to `dispatch` for a new code brief only if he confirms).

### 4. Wait for confirmation

Do not write to the vault until Kyle confirms the destination. If he redirects to a different page/file, use that instead. If he says "skip it," stop — leave the report in place, don't fabricate a landing.

### 5. Write — refine, never raw-dump

Once confirmed:

- **Refining an existing page:** integrate the finding into existing prose/sections per wiki conventions — refined, not appended. No "Update `<date>`:" or "Recent findings" tacked-on section. If the finding contradicts what the page currently says, use the conflict callout convention (`> [!conflict]`) rather than silently overwriting.
- **New page:** distill the report's Answer + load-bearing Evidence into wiki prose — this is a synthesis, not a copy-paste of the report. Cite the source (the landed `00 Inbox/` file, or the task slug for a surfaced-not-filed one) so the origin is traceable, but the page itself reads as a normal wiki page, not a report transcript.
- **A person's file:** integrate into the existing Context prose; distil into the 1:1 log by prepending, per [[People/CLAUDE]]. Never paste report text into either.
- **Project/dev-item update:** same distillation discipline — fold the finding into Status/Notes, don't paste the raw report body.

Name the file(s) touched when reporting back.

### 6. Close the loop

After a successful write, note where things landed (in the conversation, and in the daily note per the session-ledger convention if this happened mid-session — that ledger line is a pointer, not the finding's landing, so it's exempt from the step 4 confirm gate).

Leave the plumbing alone:

- **The landed `00 Inbox/` file stays where it is.** It is the provenance the distill summary and the register point at, and its retirement belongs to the hourly `/vault-routing` pass and eod's aging-Inbox drain, not to this skill.
- Do not delete or move anything under `~/.cerebro/tasks/<slug>/` — that's Cerebro-side task lifecycle. In particular, never hand-write a `landed` or `distilled` marker there: `cb-land` and `cb-distill --commit` write those after their own work succeeds, and a marker written by hand tells them a step ran that did not.

## Code completion (M5)

Triggered by a distill-queue line (`~/.cerebro/logs/distill`: `<date> <slug> <jira>`) or a code task hitting `done` on the board. Apply the completion rule (CLAUDE.md "Development Area → Completion rules") — "would a future developer working in this domain want to know this?":

1. **Read the shipped work**: the dev item (`00 Inbox/<slug>.md`) and the task's `summary.md` (`~/.cerebro/tasks/<slug>/`). For more depth, the summary's `source:` 04-ship path points into the reaped worktree — post-cleanup it's gone from there, but the run dirs are committed, so read it in the target repo's main checkout (`<checkout>/.ai/specs/<run>/04-ship.md`) after the merge instead.
2. **Propose, don't write**:
   - the **1–2-sentence domain `wiki.md` enrichment** (`02 Areas/platform/<domain>/wiki.md`, integrated into existing prose — refined, not appended). Cross-domain findings → a `03 Resources/technical/` page instead.
   - **remove the In-flight entry** from that wiki,
   - **archive the item**: `status: done` + move to `02 Areas/development/archive/items/`.
3. **Wait for confirmation**, then execute exactly what was confirmed. Small items whose learning is genuinely nil can skip the wiki edit — say so rather than padding.
4. Processed distill lines stay in the log (it's an append-only queue; track your position by what's already archived — an archived item's line is done). A line whose slug has **no** dev item (adopted/out-of-band task) can't retire that way — surface it once, and after Kyle confirms there's nothing to distill, note it as skipped in the daily note so it isn't re-surfaced.

## Guardrail

- Never write to the vault without Kyle's confirmation of the destination — this includes `00 Inbox/`, which still needs a "yes, stub it" before a *new* file is created there. (A report that `cb-land` filed is already there and needs no confirmation; it was never this skill's write.)
- Never raw-dump report content into a wiki page. Wiki pages are refined-not-appended; distill.
- A `confidential`-clearance report never gets proposed a landing — surface only, always. A **missing** clearance is `standard`, not confidential (step 2).
- Don't expand scope to sibling tasks or other reports while ingesting one — one finding, one proposal, one confirmation.
- **Never auto-write the wiki on code completion** — the enrichment is proposed text, applied only after Kyle confirms (§8.4: wiki distillation is LLM-proposed, never bash-written, never unconfirmed).
