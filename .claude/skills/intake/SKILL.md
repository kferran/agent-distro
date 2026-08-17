---
name: intake
description: Cerebro's Jira spawn-ready intake — the autofix selection/claim gate relocated (M7, T33). Reads the night-shift diagnosis cache + P11 spawn-ready residue, admits eligible unassigned Blocker/High/Medium EJA items (autonomy ≥4, code-fixable, correctness-gated), claims them in Jira, and hands each admitted key to dispatch --code (the conductor spawn). Never merges, never touches assigned tickets, never picks up the PO-owned ASD queue. Triggers — "/intake", "run intake", an hourly intake-tick nudge (once armed at T35), "--dry-run" for the mandatory pre-arm check.
intake_identity: "5cc081d23f65fd0e7ecefb82"   # Kyle's accountId (interim, inherited from autofix 2026-07-02). TODO: swap to a service-account accountId once provisioned. Parked to ~2026-07-22.
---

# /intake — Jira spawn-ready → Cerebro dispatch

The autofix pipeline's **Steps 1, 1b, and 2, relocated** (plan 2 T33): same selection gates, same claim lifecycle — but the old Step 3 spawn block is replaced by Cerebro's code path (`dispatch --code` → per-slug conductor session), and the old Step 4 PR-queue digest is replaced by the **board**: ready PRs surface as `ready-for-review`, parks as `blocked`/`failed`, every pickup a board FYI event. Diagnosis supply is unchanged: the night-shift cluster-B cache, with the on-demand shallow pull when stale.

**Not armed until T35** — run `/intake --dry-run` supervised before any live run, and run live supervised alongside armed autofix ≥1 overnight before the autofix retirement checklist executes.

## Scope guards (carried verbatim from autofix)

- **Never merges.** The gate is Kyle's PR review (Cerebro's `cb-merge` is poll-only detection).
- **Unassigned only.** Never touch a ticket with a live assignee.
- **Not ASD.** POs own the inbound ASD queue — standalone ASD keys are never picked up. An EJA↔ASD **mirror pair** rides along via the EJA key (both keys claimed, one dispatch).
- **`focus` suspends** — `~/.cerebro/mode` = `focus` → exit silently, same as `cb-intake`.
- **Cap respected** — before each dispatch, check `memcap_ok` (source `scripts/cerebro/lib/memcap.sh`) — RAM headroom + live-X-Man cap; admit-and-queue the rest, no silent truncation.
- Honor `Confidential/` strict mode. No vault auto-commit.

## Step 0 — Release sweep (every invocation, before selecting)

Release has a deterministic owner: **this skill, at its next run** — intake is fire-and-forget, so nothing else is alive when a dispatched task later dies. For every claim record (`~/.cerebro/tasks/<slug>/claim`, written in Step 2) whose task is now `failed` or `blocked`-exhausted **without an open PR** (`pr` file absent or `pr.state` not OPEN/MERGED):

1. Write the parked-investigation doc `00 Inbox/<LOCAL>-intake-parked-<KEY>.md` (what was tried, where it stuck, the seeding diagnosis — pull from `~/.cerebro/tasks/<slug>/` + the run dir).
2. **Release in Jira**: clear assignee, transition back toward the captured prior status (from the claim record).
3. Land a Needs-Kyle item `00 Inbox/<LOCAL>-needs-kyle-<key>.md` (`type: decision`, `status: needs-kyle`, `id: <key>` lowercased, `source: intake`, 30d `decide-by:`) whose body names where it stuck and links `[[00 Inbox/<LOCAL>-intake-parked-<KEY>]]`. Upsert on `id:` — see `.claude/skills/morning/needs-kyle-items.md`.
4. Mark the claim record released (append `released: <date>`) so the sweep doesn't repeat it.

## Step 1 — Select eligible set

Autofix Step 1 relocated — same gates, with **one deliberate narrowing**: only **EJA/ARCH dev keys** are admitted (autofix's worked example admitted standalone ASD keys; the PO-ownership guard now excludes them, so expect intake to no-op more often than autofix did on ASD-heavy residues). ARCH rides because it mirrors EDJ annuity defects (scan sets are EJA+ARCH, never EJA alone). The full gate set:

- **Authoritative candidates = the P11 spawn-ready residue** (`00 Inbox/<LOCAL>-night-shift.md` `## Blocker/High — autonomous-fix confidence`); the `## Diagnosis cache` table is seeding material only, and the residue's autonomy score wins on conflict. Prose "spawn-able" without a P11 score ≠ admitted (route to "diagnosed but unscored — manual decide"). If today's cache is absent or >12h stale, do the lightweight on-demand pull: cluster-B unassigned-B/H/M JQL diagnosed at `shallow×many` per `03 Resources/reference/diagnosis-procedure.md`. **Medium caveat:** night-shift P11 currently caps/omits Mediums — daytime Medium coverage usually needs that on-demand pull.
- **Re-stamp every candidate LIVE from Jira** (assignee/status/priority via the Atlassian MCP) — never trust the cache for the claim decision.
- Admit only items passing **ALL** gates: **unassigned** · **code-fixable** (exclude config/data — PPFA product records, form-def JSON, vendored DTCC builders — plus needs-Kusto and needs-decision) · **autonomy ≥ 4** · **not in flight** (no live tmux session matching `eja-<nnnn>-*`/the key, no local or remote branch for the key — `git branch --list` + `ls-remote`, cheap reads that prevent a claim `cb-start` would refuse — no open PR referencing the key, not in the parked-set marker) · **priority ∈ {Blocker, High, Medium}** · **EJA or ARCH key** (an EJA↔ASD mirror pair collapses to the EJA key).
- **RCA lift:** same-day `00 Inbox/<LOCAL>-rca-*.md` docs that lift a residue item's fix-confidence to ≥4 admit it — the lift substitutes the autonomy score ONLY; every other Step-1 gate (live re-stamp, unassigned, code-fixable, not-in-flight) still applies. Seed the dev item from the RCA's `file:line` + resolved decisions.
- **Re-test-first** items ("not-repro (re-test)" / "fixed at HEAD") are never dispatched — surface as "verify, don't fix."
- Order the admitted list **Blocker → High → Medium**; autonomy is a within-tier tiebreaker only.

## Step 1b — Correctness gate

Unchanged from autofix: run the consumption contract (`03 Resources/technical/annuity-business-rules/consumption.md`) per admitted item. A clear, cited **`contradicts`** drops the item and surfaces it as "flagged — requested fix may be wrong (PO review)" with the rule + Confluence link. `consistent`/`no-coverage`/`ambiguous` proceed; `[!conflict]`-carrying rules can't block.

## Step 2 — Claim in Jira

Unchanged from autofix: immediately before dispatching each admitted item, **re-check idempotency LIVE** (still unassigned, no open PR, no live session, not parked). If clear:

- Resolve `intake_identity` (frontmatter). A placeholder **halts a live run**; dry-run prints it unresolved and continues.
- **Assign + transition to In Progress via the two-step EJA path** (verified 2026-07-02): Tech Refinement/Scoping Backlog → **To Do** (id 4) → re-fetch transitions → **In Progress** (id 11). Never In Validation/Sign-off. **Capture the prior status from the live re-stamp** (needed for release).
- Mirror pair → claim **both** keys. No comment — the PR auto-links.
- **Write the claim record** `~/.cerebro/tasks/<slug>/claim` (key(s), prior status per key, claimed date) — Step 0's release sweep runs off this; without it a dead task leaks a claimed ticket forever.
- Re-check failed → skip, note as "skipped — claimed/PR'd since selection."

## Step 3 — Hand off to dispatch (replaces the autofix spawn block)

For each admitted key, up to free capacity (`memcap_ok` between dispatches):

1. Derive the slug: `eja-<nnnn>-<short-descriptor>` (dev-item slug = branch identity, `99 Meta/Cerebro-spec.md` §2.2 — branch becomes `fe/<slug>`, not `fe/autofix-<KEY>`).
2. Invoke the **dispatch skill's code branch** for the slug — it creates/activates the dev item (seed Objective/Context from the diagnosis cache row / RCA: root cause, `file:line`, repro), runs `cb-start --code` / `cb-brief --code`, fills context.md, sends the launch line, returns.
3. **Dispatch refusal unwinds the claim immediately**: if dispatch/cb-start refuses (collision, checkout error) or errors, run the Step-0 release actions for that key NOW — intake is still alive at this point — and report it as "released — dispatch refused (<reason>)". A claimed-but-undispatched ticket never dangles past the run.
4. **Failure isolation**: one refused/errored dispatch never stalls the wave — release it, continue with the next admitted item.
5. **Never claim beyond capacity**: Step 2's claim runs per-item immediately before that item's dispatch, so anything over the cap stays unclaimed and unassigned — listed as "deferred — over cap" and re-considered next tick.

Board is the ledger from here: `needs-input` gates page via cb-notify, self-QA'd PRs surface as `ready-for-review` after `cb-pr-check`, merges are poll-detected, parks surface as `blocked`/`failed` (Step 0 releases them next run).

## Reporting

No PR-queue digest. Return inline (on-demand) or as a short daily-note `## Overnight` line (armed runs): admitted (dispatched) / deferred-over-cap / excluded-with-why / flagged / verify-don't-fix. Every dispatch is already a board FYI event (`intake-claimed`/`dispatch-request` lines from `cb-intake`, or this skill's own event note).

## Dry-run mode (mandatory before arming)

`/intake --dry-run`: Steps 1 + 1b + the Step-2 idempotency re-check + claim-plan + the dispatch plan (slugs, branches, sessions). Read-only Jira/tmux/PR checks allowed; **all writes suppressed** — no Jira claim, no dev items, no worktrees, no sessions, no vault writes. Verify the admitted set + zero side-effects before T35 arms anything.
