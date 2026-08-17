---
name: autofix
description: Auto-fix the unassigned spawn-ready backlog. Reads the night-shift diagnosis cache + P11 spawn-ready residue, selects eligible unassigned Blocker/High/Medium items (autonomy ≥4, code-fixable), claims each in Jira, spawns parallel self-verifying work-conductor sessions, and assembles a PR-queue digest for Kyle's review. Gate is the PR; never merges, never touches assigned tickets, never emits an unverified PR. Triggers — "/autofix", "auto-fix the spawn-ready backlog", chained cron after the night shift.
autofix_identity: "5cc081d23f65fd0e7ecefb82"   # Kyle's accountId (interim, set 2026-07-02 per Kyle). TODO: swap to an autofix-bot service-account accountId once provisioned so claims read as "pipeline," not Kyle. See Open items.
concurrency: 3
---

# /autofix — Auto-Fix Pipeline

Turns the night shift's **diagnosis** into **fixes-in-flight**, gated only at Kyle's PR review. Consumes the night-shift diagnosis cache + P11 spawn-ready residue; turns diagnosed **unassigned** Blocker/High/Medium items into **self-verified** PRs. The gate is the PR — `/autofix` **never merges**, **never touches assigned tickets**, and **never emits a PR that hasn't passed self-QA** (it parks instead).

Design: `99 Meta/specs/2026-06-20-autofix-pipeline-design.md`. Plan: `99 Meta/specs/2026-06-20-autofix-pipeline-plan.md`.

This is a vault orchestration skill (sibling to `/night-shift`). It dispatches Remote-Claude `ultron:work-conductor` sessions to do the actual fixes in worktrees; `/autofix` orchestrates selection, claim, spawn, and the PR-queue digest. Follow the same patterns as `.claude/skills/night-shift/SKILL.md` (orchestration, failure isolation) and `02 Areas/development/README.md` (worktree spawn + conductor launch).

## Triggers

- **Chained cron** — fires after the night shift completes; reads the fresh `00 Inbox/<LOCAL>-night-shift.md` diagnosis cache + P11 residue.
- **On-demand** — `/autofix` anytime (typical EDJ-E2E-day use: a Blocker lands at 2pm). If today's cache is absent or its fire-time is **>12h stale**, do a lightweight diagnosis pull first: the cluster-B unassigned-B/H/M JQL, diagnosed at `shallow×many` per `03 Resources/reference/diagnosis-procedure.md`, to produce an ad-hoc residue before selecting.
- **Dry-run** — `/autofix --dry-run` (or "dry run"): select + plan only, no side-effects. See "Dry-run mode" below. **Run this before arming the cron live.**

## Global rules

- **Never merges.** The gate is Kyle's PR review.
- **Unassigned only.** The pipeline never touches a ticket with a live assignee — it must never collide with the dev team's assigned work.
- **Self-verified or park.** A fix reaches the PR queue only after passing build + QA + conventions-check + reviewer self-review. If it can't, it parks (no PR).
- **No vault auto-commit.** Edits/reports stay uncommitted for Kyle's `/push`. The only external writes are the scoped per-ticket Jira claim (assign + In Progress, no comment) and the PR push itself.
- **Failure isolation.** A spawn that errors/dies parks as "errored" (release claim + kill session); the wave continues. One bad spawn never stalls the others.
- Honor `Confidential/` strict mode.

## Step 1 — Select eligible set

**Authoritative candidate list = the P11 `## Blocker/High — autonomous-fix confidence` spawn-ready residue** — it carries the autonomy score the gate needs. The `## Diagnosis cache` table is the **seeding source only** (root cause / `file:line` / repro for the conductor in Step 3); do **not** union the two as candidates, and where their autonomy/RC numbers differ, the **residue's autonomy score wins** for the gate. An item the night shift calls "spawn-able" in prose but with **no P11 autonomy score** is NOT auto-admitted (it can't clear the ≥4 floor) → list it under the digest's "diagnosed but unscored — manual decide" (e.g. ASD-852 on the 2026-06-20 cache). On an on-demand stale-cache pull, use the ad-hoc residue (it scores autonomy the same way). **Mediums are admitted when the residue contains them** — note night-shift P11 currently caps/omits Mediums, so daytime Medium coverage may require the on-demand diagnosis pull.

For each candidate, **re-stamp live from Jira** (assignee + status + priority via the Atlassian MCP) — the cache can be hours stale; never trust it for the claim decision. (This live read runs in dry-run too — it's read-only; only writes/worktrees/PRs are suppressed.) Admit only items passing **ALL** gates:

- **Unassigned** — live assignee empty.
- **Code-fixable** — exclude the config/data class (PPFA product records, form-def JSON, vendored DTCC flat-file builders), needs-Kusto, and needs-decision items. These are already tagged in the cache / the P11 "config/data" callout — exclude by that tag and route them to the digest's nothing-to-do note (PPFA/product/form-tool owners handle them).
- **Autonomy ≥ 4** — the P11 derived autonomous-fix confidence (root-cause confidence + fix scope + blast radius).
- **Not in flight** — no live `tmux` session `autofix-<KEY>` or other worktree for the key, no open Bitbucket PR referencing the key, and the key is **not in this run's parked-set marker** (don't reattempt a fix that already parked — it waits for a human).
- 🔴 **Not worked on — a SECOND gate, and unassigned does not satisfy it (Kyle, 2026-08-06: _"We should only be picking up tickets that are unassigned and have not been worked on."_).** Exclude the ticket if there is **any** evidence someone has already worked it: a PR referencing the key in **any state including DRAFT**, or a branch carrying commits under the key (`git cherry origin/main origin/<branch>`). Evidence of prior work excludes it **regardless of what the status field says** — a ticket reading Done/Closed with an open PR is not a free slot, it is a question about why it closed.
  **And a PR the fleet did not author is READ-ONLY.** Report it; never propose declining, closing, reassigning or amending it. Check `author.display_name` — Kyle appearing in `participants[]` means he is one of a dozen-plus reviewers, not the owner. Measured 2026-08-06: three PRs were carried for several turns as decline candidates on the strength of their tickets being resolved; all three were **drafts by Alex Smith / Juno Cragun / James Morris**, and #2332 alone held **46 commits / 69 files** that a decline would have discarded.
- **Priority ∈ {Blocker, High, Medium}.**

Emit the admitted list **ordered Blocker → High → Medium** (autonomy is a within-tier tiebreaker, never the primary sort).

**RCA lift (2026-07-06):** ALSO consult same-day RCA docs (`00 Inbox/<LOCAL>-rca-*.md`). If an RCA has lifted a residue item's fix-confidence to **≥4** (by resolving the root-cause/scope uncertainty that held it at 3/5) and the ticket is still **unassigned + code-fixable**, admit it — seed the conductor from the RCA's `file:line` + any resolved product decisions in the RCA. The night-shift chains `/rca` on the top 3/5 residue item just ahead of autofix precisely to produce these; this is how the pipeline stops no-op'ing on a real-but-one-step-short residue.

### Explicit exclusions
- **Re-test-first items** — cache repro reads "not-repro (re-test)" / "fixed at HEAD" (e.g. ASD-730/690): never spawn. List under the digest's "verify, don't fix."
- **Mirror pairs** — an EJA↔ASD pair on one cache row collapses to **one** spawn; both keys are claimed (Step 2).

### Worked example (vs the 2026-06-20 cache)
Against `00 Inbox/2026-06-20-night-shift.md` — illustrative, but buckets **every** residue/cache row so the accounting is complete (the digest must route them all):
- **Admitted (3):** EJA-3169 (Blocker, autonomy 4), ASD-1011 (High, 5), ASD-1013 (High, 4) — unassigned, code-fixable, autonomy ≥4.
- **Excluded — config/data:** EJA-3174, EJA-3255, ASD-1008, ASD-555, ASD-826, + the Nationwide Stable Income cluster (ASD-1006/1007/1010 +614).
- **Excluded — re-test-first:** ASD-730, ASD-690.
- **Excluded — in-flight:** ASD-792 (Work Scheduled), EJA-3214 (Kyle, In Progress), EJA-3158/EJA-3264 (taken), EJA-3240 (PR Submitted).
- **Excluded — autonomy <4:** EJA-3234 (3), ASD-876 (3), EJA-3173 (3), EJA-2621/ASD-898/ASD-375 (2); EJA-2877 (story, N/A).
- **Excluded — new/reopened pending human routing:** ASD-1021/1020/426 (confirm in-flight cluster first per the night-shift Needs-Kyle).
- **Diagnosed but unscored → manual decide:** ASD-852 (night-shift calls it "spawn-able" but P11 gave it no autonomy score).

## Step 1b — Correctness gate (hook)

**ACTIVE as of 2026-06-21** (Spec 2 business-rules layer shipped). After selection, for each admitted item, run the **consumption contract** `03 Resources/technical/annuity-business-rules/consumption.md`: cross-check the ticket's *requested expected outcome* against the layer's `index.md` / `carriers/<carrier>.md` (+ the capability docs for mechanism facts). Apply the contract's verdict:
- **`contradicts`** → **drop from the spawn set** and route to the digest's "flagged — requested fix may be wrong (PO review)" bucket with the cited rule + Confluence link.
- **`consistent` / `no-coverage` / `ambiguous`** → **proceed** (silence ≠ block; ambiguity ≠ block — only a clear, cited contradiction gates).

A rule carrying a `[!conflict]` callout (unresolved-source, e.g. the code-65 OwnerK case) does **not** produce a `contradicts` — conflicted rules can't block. (Digest's "flagged" bucket appears only when a contradiction is found.)

## Step 2 — Claim in Jira

Immediately before spawning each admitted item, **re-check idempotency LIVE** (assignee still empty, no open PR, no live worktree, not parked). If still clear:
- **Resolve the identity first.** If `autofix_identity` is still the placeholder `<KYLE_ACCOUNT_ID>`: a **live run HALTS** ("autofix_identity unresolved — set the autofix-bot accountId (or Kyle's) in frontmatter before a live run"); a **dry-run** prints `<identity: unresolved — would be Kyle's accountId>` and continues. **Never** assign the literal placeholder string.
- **Assign to the auto-fix identity** (`autofix_identity`) and **transition to In Progress** (`getTransitionsForJiraIssue` → `transitionJiraIssue`). **EJA workflow path (verified 2026-07-02): In Progress is NOT directly reachable** from the To-Do-category statuses tickets sit in (Tech Refinement, Scoping Backlog). It's **two-step**: transition **→ To Do** first (fire the transition whose target status is To Do), then re-fetch transitions and transition **→ In Progress** (the one named "to In Progress" → status 10085). **Read the transition ids live BY NAME — never hardcode: they are NOT stable** (from Tech Refinement, → To Do was id `4` on 7/02 but id `501` on 7/21). See [[reference_eja_status_transition_path]]. Never use "In Validation"/"Sign-off" as the claim target — those are QE/review states, and there's a standing rule against auto-moving to In Validation ([[feedback_no_auto_validation_transition]]). **Capture the prior status** first — from the **live Step 1 re-stamp**, not the cache (the cache omits status for most rows) — needed for release (the release path navigates back toward it; exact restore to Tech Refinement may itself be multi-step). **No comment** — the eventual PR auto-links via the key.
- For a **mirror pair**, claim **both** keys.
- Use accountId/ADF per the Jira-mentions discipline (markdown account refs get silently escaped).

If the live re-check fails (someone grabbed it, a PR appeared), **skip** the item and note it in the digest as "skipped — claimed/PR'd since selection."

### Claim lifecycle
- **Spawn** → assigned + In Progress.
- **PR opened** → **transition to `PR Submitted`** (transition **named** "to PR Submitted"; it was id `31` from In Progress on 2026-08-06 — read it live, ids are not stable). **Changed 2026-08-06 on Kyle's call: _"If a pr is open the status of the ticket should reflect where the work is."_** This retires the previous rule ("unchanged — PR links the ticket; Kyle's merge advances it"), which put autofix in conflict with the `dispatch` skill's PR→PR-Submitted transition and left two skills rendering the same state differently on the board. Merging still advances it past this, and merging is still only Kyle's.
  ⚠️ **The EJA validator blocks this transition until two fields are set** — `Change risk` (`customfield_10006`; options are **only** Critical `10007` / High `10008` / Low `10010` — there is no Medium) and `Story Points` (`customfield_10025`, must match `0.25|0.5|1.0|2.0|3.0|5.0|8.0|13.0`). Set them from `03 Resources/reference/porch-story-points.md` — *"most bugs should be ≤1 SP; 1 = half a day"* — and **state the reasoning in the digest**. Do **not** stamp `Low` + `1` reflexively to clear the gate: Kyle already has an open item to re-size three tickets that got exactly that treatment, because a validator-clearing default is indistinguishable from an estimate once it is on the board.
- **Parked** (self-QA failed / errored) → **release**: clear assignee, transition back to the captured prior status, attach the parked-investigation pointer. (Invoked by Step 3's park path.)

## Step 3 — Spawn + self-verify-or-park

For each admitted item, up to the concurrency cap (below), spawn a Remote-Claude `work-conductor` session — follow `02 Areas/development/README.md` steps 1–5 verbatim:
- Branch `fe/autofix-<KEY>` off `origin/main`; worktree `~/code/worktrees/autofix-<KEY>`; tmux session `autofix-<KEY>`. For a **mirror pair, use the EJA key** for `<KEY>` (the canonical dev key; the ASD key rides along). (`fe/` is the repo's standard work-branch prefix per `02 Areas/development/README.md` — full-stack, not FE-only; backend `.cs` fixes use it too.)
- The conductor's opening prompt is **seeded from the cache row** — root-cause hypothesis, `file:line`, repro status — handed in as the Spec input so it starts from the diagnosis instead of re-deriving it. Name the ticket key + the expected outcome from the ticket.

### Self-QA-or-park contract
PR emission is **gated** on self-verification. The conductor must pass:
1. **Build** clean,
2. **QA** — the fix's tests **and** the ticket's repro,
3. **conventions-check** clean,
4. **reviewer** self-review approves.

- **All pass** → push + **emit the Bitbucket create-PR URL** (never browser-create) + record in the digest's "ready" bucket. **Do not merge.**
- **Any fail** → **2 bounded retries**. Still failing → **park**: emit **no PR**; write an "attempted — needs human" record to `00 Inbox/<LOCAL>-autofix-parked-<KEY>.md` (what it tried, where it stuck, the seeding diagnosis); add `<KEY>` to the run's parked-set marker; invoke the Step 2 **release**; `tmux kill-session -t autofix-<KEY>`. **Also land the park as a Needs-Kyle item** — `00 Inbox/<LOCAL>-needs-kyle-<key>.md` with `type: decision`, `status: needs-kyle`, `id: <key>` (lowercased), `source: autofix`, 30d `decide-by:`, body linking `[[00 Inbox/<LOCAL>-autofix-parked-<KEY>]]` and naming where it stuck. Upsert on `id:` per `.claude/skills/morning/needs-kyle-items.md`. Without this the park lives only in a doc `/morning` never reads.

### Failure isolation + concurrency
- A worktree that errors/dies (API/infra) → park as "errored" (release + kill-session); the wave continues.
- Spawns run in parallel up to `concurrency` (frontmatter, default **3** — the night-shift host ceiling, since the box also runs the night shift + existing Remote-Claude sessions). Admit the top N by priority order; **queue the rest** and list them by name + priority in the digest's "Deferred" bucket. **No silent truncation** — the count and the keys must appear.
- 🔴 **STAGGER the spawns — at least 60s between each `cb-start`. Never fire the wave in the same second** (Kyle, 2026-08-05).
  On 2026-08-05 all three spawned at **10:29:xx UTC** and **two of the three were dead within seven minutes on `API Error: 529 Overloaded`** (`autofix-eja-3983` 10:35:33Z, `autofix-eja-3962` 10:36:03Z). Their transcripts are 60,029 and 60,031 bytes — within two bytes, stopping in the same minute — while the survivor ran 414 entries with zero API errors. Same-instant starts concentrate the load and lose the race together.
  ⚠️ **The stagger is mitigation, not the fix.** It lowers the odds of a simultaneous overload; it does not make a conductor survive a 529, because the conductor has no retry and dies where it stands. The real fix — detect the death from the session transcript, then re-adopt once or park with the claim released — is [[00 Inbox/cerebro-conductor-dies-on-529-without-parking]]. Until that ships, a staggered wave still loses a conductor now and then, and **the loss is silent**: the beacon reads `running` for a dead conductor exactly as it does for a live or a finished one.
  ⚠️ **Do not diagnose the next 2-of-3 death from the shape.** An earlier 2-of-3 loss on this box was resource contention (three concurrent `pnpm install` + `build:backend-types`); this one never reached a build. Read the transcripts (`~/.claude/projects/<encoded-worktree-path>/*.jsonl`, look for `isApiErrorMessage`) before naming a cause.

## Step 4 — Assemble the PR-queue digest

Four buckets, in order (omit a bucket if empty, except always show "ready" even if empty):

```
AUTO-FIX QUEUE — <LOCAL>
PRs ready for review (self-QA passed), ranked Blocker→High→Medium:
  • <KEY> (<priority>, autonomy <N>) — <one-line root cause> — PR <url> — QA: <result>
Parked — needs human (no PR):
  • <KEY> — attempted, stuck at <where> — diagnosis <file:line> — released to unassigned — [[00 Inbox/<LOCAL>-autofix-parked-<KEY>]]
Flagged — requested fix may be wrong (PO review):    [only once Spec 2 lands]
  • <KEY> — conflicts with business rule <cite>
Deferred — over concurrency cap:
  • <KEY> (<priority>) …
Verify, don't fix (re-test-first):
  • <KEY> — already fixed at HEAD / not-repro
```

**Destination:**
- **Chained run** → append as a `## Auto-fix queue` section in `00 Inbox/<LOCAL>-night-shift.md` if it's still being assembled, else write `00 Inbox/<LOCAL>-autofix.md`; **mirror the headline** into the daily note `## Overnight`.
- **On-demand run** → return the digest inline to Kyle.

## Dry-run mode

`/autofix --dry-run` executes **Step 1 + Step 1b + the Step 2 idempotency re-check + claim-plan + the Step 3 spawn-plan**. **Read-only Jira / tmux / PR checks are allowed** — the live re-stamp + idempotency are reads, not side-effects. Only **writes are suppressed: no Jira claim/transition, no worktrees, no PRs, no file writes.** It prints:
- the **admitted set** (ranked),
- the **claim plan** (assign/transition per key, with captured prior status),
- the **spawn plan** (branch / worktree / session names),
- what would **defer** (over cap) and what's **excluded** and **why** (config/data, re-test-first, in-flight, assigned-since).

This is the pre-arm safety check — verify the admitted set looks right and confirm zero side-effects (`tmux ls` unchanged, no Jira writes) before flipping the cron `enabled: true`.

## Open items
- **`autofix_identity`** — **PARKED (Kyle, 2026-07-08; revisit ~2026-07-22).** Provisioning an `autofix-bot` service account (so claims read as "pipeline, not a person") is deferred a couple of weeks. Until then it stays on Kyle's accountId (works fine; interim). Not a blocker — don't re-surface before the revisit date.
- **First real run** — recommend on-demand + supervised (watch one spawn end-to-end) before the cron is armed.
- **Spec 2** — the correctness gate (Step 1b) stays inert until `03 Resources/technical/annuity-business-rules/` exists.
