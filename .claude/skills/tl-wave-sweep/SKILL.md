---
name: tl-wave-sweep
description: Sweep the T&L Wave 1/2 backlog for EJA mirrors nobody is working, and land them as queued dev items so cb-intake claims and dispatches them through to a PR
---

# tl-wave-sweep — drive the T&L Wave 1/2 backlog

Finds Phase-1 Test & Learn **Wave 1 and Wave 2** tickets that are unassigned and unworked, and lands
each as a `queued` dev item. `cb-intake` claims them (3/hour) and `dispatch` carries them the rest of
the way — arch-check → assign to Kyle → In Progress → conductor → PR.

**This skill emits dev items. It does not dispatch, assign, or transition anything.** Everything past
the emit already exists and is already rate-limited; adding a second dispatcher here would be the
duplicate-scheduler pattern that owns the top of `02 Areas/Engineering-Work/scheduled-tasks-log.md`.

Commissioned by Kyle 2026-08-07: *"Let's work the unassigned EJA tickets in the wave 1/2 T&L category
of tickets. I'd like the hourly tick to include monitoring of this category of tickets and to drive
work forward."*

## Invocation

- **Hourly fleet tick, Part 4** — the primary caller. Most ticks emit nothing and report `tl-wave: clean`.
- **`/tl-wave-sweep`** — on demand.

## Relationship to the two intake paths

| | Watches | Window |
|---|---|---|
| `cb-reactive-intake` (cron, **not armed**) | new/reopened EJA bug mirrors | forward-only 15-min window |
| **this skill** | the **standing W1/W2 backlog** | whole population, every run |
| `cb-intake` (systemd, hourly) | `status: queued` dev items | claims ≤ `~/.cerebro/max-claim` |

The forward watcher never looks back, so a ticket that was already sitting there when it was armed is
invisible to it forever. This skill is that gap. **Both emit through the same
`cb-reactive-intake offer` path**, so the dedup, live-assignee and spec gates are identical and cannot
drift apart.

## Procedure

### 1. Find the population — on the ASD `Launch` FIELD, never an EJA label

```
project = ASD AND Launch in ("Ph1-TL-W1","Ph1-TL-W2") AND statusCategory != Done
```

🔴 **Do not query `project = EJA AND labels in ("Ph1-TL-W1","Ph1-TL-W2")`.** It returns ~10 issues
against a real population of ~131 ASD rows / ~90 distinct mirrors, and exactly **one** unassigned — a
clean-looking answer that under-reports by roughly ninefold. Membership lives on the ASD **Launch
field**; the EJA side carries the engineering work, not the wave tag. (Measured 2026-08-07; the trap is
the reason this warning is the first thing in the procedure.)

**Positive control before you trust any count** — per
[[.claude/memory/feedback_a_zero_result_is_not_evidence]]: print the population total and the
with-mirror / without-mirror split. `0 candidates` is only meaningful next to a non-zero population.
Page the query; `maxResults` caps at 100 and W1 alone exceeds it.

🔴 **ALSO UNION IN THE EJA-LABEL SET — the ASD Launch field has the inverse blind spot, measured
2026-08-13.** The warning above is about the label *under*-reporting the backlog ninefold, and it
stands. But the failure runs both ways: **an ASD row can lack the Launch value while its EJA mirror
carries the label**, and such a ticket is invisible to this query no matter how carefully it is
paged.

Confirmed instance: **[ASD-1332](https://porchsoftware.atlassian.net/browse/ASD-1332) carries no
`Ph1-TL-W1` Launch value, while its mirror
[EJA-4171](https://porchsoftware.atlassian.net/browse/EJA-4171) is a `Ph1-TL-W1` **Blocker** on the
XML 103 address path** — an EDJ-reported integration breakage. This sweep would never have surfaced
it; it reached the fleet only because Kyle handed over the ticket by hand. Measured the same day:
**19 open EJA tickets carry the `Ph1-TL-W1` label**, and two of them are unassigned.

🔴 **RUN THE UNION FOR BOTH WAVES — `labels in ("Ph1-TL-W1","Ph1-TL-W2")`. It said `= "Ph1-TL-W1"`
until 2026-08-14 and that single-wave hardcode hid ten workable tickets.** The rule was written from a
W1 instance (ASD-1332/EJA-4171), and the wave got baked into the query even though the *reasoning* — an
ASD row lacking the Launch value while its EJA mirror carries the label — has nothing to do with which
wave it is. Measured 2026-08-14 07:2x MT:

| Label | open EJA | unassigned | unreachable from the ASD population | **unassigned AND unreachable** |
|---|--:|--:|--:|--:|
| `Ph1-TL-W1` | 19 | 2 | 15 | **1** (EJA-4171, already worked) |
| `Ph1-TL-W2` | 24 | 10 | 17 | **10 — six of them High** |

So the W1-only union was contributing one candidate that was already excluded anyway, while ten
genuinely unassigned W2 tickets — EJA-4155, 4151, 4135, 4134, 4133, 4115, 4114, 4100, 4099, 2606, all
sitting in Tech Refinement — were invisible to every run. The sweep reported `tl-wave: 0 emitted` truthfully
and incompletely for as long as the hardcode stood.

⚠️ **Do not blanket-emit the backlog the first time this fires.** Ten items against an intake capped at
3/hour floods the queue, and W2 is post-GA work during a W1 go-live push. Rank by the ASD priority where
a mirror exists, emit a few, and say in the report what was held back and why.

So run the EJA label query as a **union**, not a replacement, and reconcile: any EJA in that set whose ASD is absent from the Launch population is
either a mis-tagged ASD or a genuinely missed wave ticket. **Report both counts.** §5c already unions
for exactly this reason — *"for a bounce a false negative costs more than the duplicate does"* — and
the emit path had never been given the same treatment.

⚠️ **Do not fix the ASD's Launch field.** POs own it ([[.claude/memory/feedback_asd_po_ownership]]);
report the mismatch and let them set it.

### 2. Follow to the EJA mirror

Take `issuelinks` and keep any `EJA-*` (inward or outward, **any link type** — `Complete`, `Relates`,
`Cloners` all occur; do not filter on type). One ASD may map to several EJAs, and one EJA may cover
several ASD rows — EJA-3599 covers four.

**ASD rows with no EJA mirror are out of scope.** POs own the inbound ASD queue
([[.claude/memory/feedback_asd_po_ownership]]); eng does not self-serve a mirror. Count them and report
the count, nothing more.

### 3. Filter to genuinely workable

Keep a mirror only if **all** hold:

- **Unassigned**, or assigned to Kyle. (A named engineer holds — `offer` enforces this itself at Gate 2,
  but filter early so the log is readable.)
- **`statusCategory != Done`.**
- **Unworked** — no PR, no branch, no commit on the key. Check all three, not just PRs:
  `git branch -r --list "origin/*<lowercased-key>*"` in `~/code/worktrees/main`, plus the Bitbucket PR
  list. `ahead=0` is not an empty signal.
- **No dev item already** — `offer`'s Gate 1 dedups over every key, live and archived, so you may let it
  decide; a `HOLD dedup` (exit 3) is a normal outcome, not a failure.

Status is *mostly* **not** filtered. `In Progress` with nobody assigned is a real state here (three of
the first ten) and it means nobody is on it, not that someone is. Scoping Backlog, To Do and Tech
Refinement all emit normally.

⚠️ **`Blocked` is the one exception, and it must NOT emit as `queued`** (learned the hard way on the
skill's second run, 2026-08-07). `Blocked` means the ticket is waiting on something that is not
engineering capacity — EJA-3211 is Blocked on *"QE, can you please try and reproduce this bug?"*
(Lori Sadler, 07-30). Emitting it `queued` hands `cb-intake` a ticket with no reproduction, and a
conductor would spawn against evidence that does not exist yet. Emit it with `--needs-scoping --note
"<why it is Blocked, quoted>"` so it lands `drafting`, and it gets promoted when the block clears.

The general form: **`queued` means "a conductor could start on this right now."** Anything waiting on a
human, a repro, or a product answer is `drafting`, whatever its Jira status says.

### 4. Emit, ranked by the ASD's priority

```bash
scripts/cerebro/cb-reactive-intake offer \
  --eja <EJA-KEY> --asd <ASD-KEY> \
  --priority "<the ASD's Jira priority, NOT the EJA's>" \
  --summary "<EJA summary>" --assignee "" \
  --trigger new [--domain <...>] [--needs-scoping --note "<the unanswered question>"]
```

⭐ **`--priority` takes the ASD's priority, deliberately.** The mirrors are under-ranked: EJA-3947 reads
**Medium** while its ASD-1126 is a **reopened Blocker**. `offer` maps `--priority` → the dev item's
`severity:`, and `cb-intake` claims in severity order, so passing the ASD priority is the whole of
"rank by the real severity" — no separate ranking code exists or should.

**Jira is not edited.** Kyle's call, 2026-08-07: rank internally, leave the EJA priority field alone.
If you think a mirror's priority is wrong in Jira, say so in the tick report; do not fix it.

Exit codes: `0` emitted · `3` dedup hold · `4` live-assignee hold · `2` usage error. A
`⚠️ SIBLING MIRROR` on a code-3 means only the ASD matched and this EJA is untracked — surface it, never
hand-create the item.

### 5. RCA — who does it depends on whether the ticket has bounced

- **Fresh ticket** (never worked, no QE bounce) → **the conductor's own investigate phase is the RCA.**
  Emit `queued` and stop. This is how EJA-3920 and EJA-3905 were scoped on 2026-08-06; a separate RCA
  pass ahead of it duplicates work the conductor does anyway.
- **Bounced ticket** (`Failed QE`, or it has moved out of Done/Closed) → the bounce needs diagnosis
  before scoping. Dispatch a **research** X-Man (`cb-start --research`) for the RCA and emit the dev
  item as **`drafting`** (`--needs-scoping --note "RCA in flight: <slug>"`) so intake does not claim a
  half-scoped item. It flips to `queued` when the RCA lands via `/ingest`.

### 5b. Re-verify what is ALREADY queued — the monitoring half

Emitting is only half of what this skill was asked for. Kyle's words were *"include monitoring of this
category of tickets"*, and a `queued` item goes stale the moment a human picks the ticket up.

**Every run, re-check the mirror of every `status: queued` dev item this skill owns.** If the mirror is
now assigned to someone who is not Kyle, flip the item to `drafting` with a `hold:` naming the assignee,
the mirror's status, and the date.

Measured 2026-08-07 10:3x MT, one hour after they were emitted: **EJA-3934 went to Winona Kyle-Clark and
EJA-4017 to Don Rodriguez** — both still sitting `queued` on our side. `dispatch`'s C1c live-assignee
gate would have refused them, so nothing unsafe would have happened, but each would first have burned
one of `cb-intake`'s three hourly claim slots and appeared on the board as fleet work. Holding them here
is cheaper and keeps the board honest about who is actually working what.

This is also the healthy case, not a failure: the sweep surfaces W1/W2 work, and if a human takes it
first, that is the backlog draining. Report it as pickup, not as a hold you had to impose.

### 5c. FAILED-QE WATCH — runs first, reports first

Commissioned by Kyle 2026-08-07: *"I would like to include monitoring on failed tickets related to the T&L Wave 1 push we're under. If a ticket fails QE it needs to be surfaced quickly so it can be addressed."*

A bounce is the one event in this backlog that is both urgent and silent. Nothing else notices it: `cb-intake` reads dev-item `status:` only, the emit path in §4 skips anything already assigned, and a ticket that fails QE is by definition already assigned to whoever built it. **Run this step before §1** and put its output at the top of the report, above the emit tally.

**Query.** Both halves, because they answer different questions:

```
project = EJA AND status = "Failed QE"
project = EJA AND status CHANGED TO "Failed QE" AFTER -24h
```

`status = "Failed QE"` is verified live (2026-08-07) — it is a real status name, not a guess. The second query catches a ticket that bounced and has already been moved on again, which the first misses entirely.

Scope to the wave the same way §1 and §2 do — ASD `Launch` field → EJA mirror. **Also keep any EJA carrying a `Ph1-TL-W1`/`Ph1-TL-W2` label directly**, as a union, not a replacement: the label under-reports the *backlog* population ninefold (§1), but for a bounce a false negative costs more than the duplicate does. Report an unlabelled, unmirrored Failed-QE Blocker too, marked `outside wave` — EJA-3844 was sitting in exactly that state when this was written.

**Diff against last-seen.** Persist the key set to `~/.cerebro/watchlist/tl-failed-qe.state`, one key per line, mirroring the existing watch-list convention. Then:

🔴 **READ `customfield_10078` ("Reason For Failure"). QE does NOT bounce in comments.**

This is the single most important line in the step, and getting it wrong makes the watch worse than useless — it reports "no reason given" across a queue where every failure is fully documented. Measured 2026-08-07: of four bounced tickets, **three had a detailed, actionable reason in `customfield_10078` and none of them had a bounce comment.** EJA-3666 was dispatched to a conductor on the premise that two rounds had bounced silently; the field carried a precise reason for both, and it refuted the hypothesis the brief was built on.

The field is ADF and it accumulates across bounces. It typically carries environment, user, carrier, product and case number alongside the prose, which is the repro a conductor needs.

🔴 **BLOCK ORDER IS NOT CHRONOLOGICAL. Never infer a block's round from its position.** This line used to say "each bounce prepends a block, so the newest entry is first." That is false, and acting on it produced a wrong dispatch on 2026-08-07: EJA-3488's three blocks sit in the order `[08-06] [07-15] [07-30]`, because the 07-30 bounce was **appended at the bottom** while the 08-06 one was **prepended at the top**. A brief built on position-equals-recency read the *oldest* block as new evidence and manufactured two contradictions that did not exist.

**Read the date out of the ADF, every time.** Each block carries its round in two places a plain text dump destroys:
- the wrapping `expand` node's `attrs.title` (`"8/6/26 Fail"`, `"7/15/26 Fail"`, `"7/30/26 Fail"`), and
- a `date` node holding an epoch-millis value (`1785974400000` = 2026-08-06).

⚠️ **A naive ADF-to-text walk drops both.** Recursing for `type == "text"` skips `date` nodes and never looks at `attrs`, so every block renders as a bare `GM` with no date, and the blocks become indistinguishable. That is exactly how the dates were lost. Extract `attrs.title` and `date` nodes explicitly, and if you cannot, cross-check against the changelog (`GET /rest/api/3/issue/<KEY>?expand=changelog`, count the writes to the field) and the inline attachment filenames inside each block, which are date-stamped.

```
GET /rest/api/3/issue/<KEY>?fields=customfield_10078
```

Resolve the id by name rather than trusting this literal (`GET /rest/api/3/field`, match `Reason For Failure`) — a hardcoded id that silently returns nothing is exactly the zero-result-is-not-evidence failure. Check comments too, but treat the field as the primary source and **never report a bounce as unexplained without having read it.**

- **New since last run → this is the notification.** Lead the report with it: key, priority, assignee, the wave label, and the newest `Reason For Failure` block **verbatim, attributed, with its timestamp**. Never paraphrase what QE wrote; Kyle acts on these directly, and *"it still doesn't work"* and *"the tab renders but the field stamps blank"* are different facts.
- **Already seen → one tally line.** `failed-qe: N standing (unchanged)`. A bounce that has been sitting for three ticks is not news, and re-announcing it every hour is how a signal stops being read.
  - 🔴 **BUT RECONCILE THE STANDING SET EVERY RUN — a tally is not a substitute for checking whether anyone is on it.** Run `scripts/cerebro/cb-pipeline --report --keys "<every standing key>"` and act on its `NEXT ACTION` column. Collapsing to a tally is about *reporting volume*, not about doing nothing.

    **This step exists because its absence cost twenty ticks.** §5c dispatched an RCA only for a bounce that was NEW since last run. [EJA-4020](https://porchsoftware.atlassian.net/browse/EJA-4020) — High, unassigned, Failed QE — was reported as "standing" on twenty consecutive ticks on 2026-08-13 and **never got an RCA, a dev item, or an owner**, because it was never *new* during a tick that would have dispatched one. Kyle: *"What do we need to fix so that tickets like these two get picked and someone is dispatched to work on them?"*

    The stages `cb-pipeline` returns, and what each one owes:
    | Stage | What it means | Action |
    |---|---|---|
    | `NOTHING` | no dev item, no RCA | **dispatch the RCA** (the §5 bounced-ticket rule) |
    | `RCA-LANDED-NO-ITEM` | the diagnosis exists and nothing consumed it | create the dev item from it and queue it |
    | `DRAFTING` | held on something | resolve the hold or say what it is waiting on |
    | `ACTIVE-STALLED` | `active`, no worktree, stale | it is not active — re-offer it, or say why not |
    | `QUEUED` / `ACTIVE-LIVE` | in the pipeline | nothing |
    | `UNKNOWN-STATUS(x)` | a status `cb-intake` does not claim | **this is the silent one — see below** |

    ⚠️ **`cb-intake` claims `status: queued` and nothing else.** Measured 2026-08-13 across 233 dev items: **125 `drafting`, 54 `active`, 24 `needs-triage`, 13 `paused`, 7 `done`, 6 `superseded` — and 4 `queued`.** The live intake surface is four items out of 233. Every other status is a parking space with no exit, and EJA-4020's item (`asd-605`, `status: needs-triage`, *"Below the auto-dispatch bar — needs scoping"*) had been sitting in one for **28 days**, parked by `cb-intake` itself. A status that nothing ever revisits is where work goes to be forgotten, and reporting it as "standing" every hour makes that look like monitoring.

    ⚠️ **Do not blanket-act on the stalled set.** The 48 `active`-with-no-worktree items are a real finding but not a batch job: demoting them all to `queued` would feed 48 items to an intake capped at 3/hour, and at least one of them (EJA-3916) has an RCA concluding the fix is already deployed, so dispatching a conductor would build nothing. The script diagnoses; the decision on each stays here.
  - 🔴 **SEVERITY OVERRIDES THE COLLAPSE. A standing bounce that is a `Blocker`, or that carries `Ph1-TL-W1`, is NAMED every tick — key, age, and owner — no matter how many times it has already been reported.** The tally exists to suppress *noise*; the loudest item in the wave is not noise, and collapsing it is how it goes unseen. Added 2026-08-07 after Kyle found [EJA-3488](https://porchsoftware.atlassian.net/browse/EJA-3488) himself: it was a **Blocker**, `Ph1-TL-W1`, assigned to him, in Failed QE — and the tick reported `0 new / 10 standing`, which was accurate against last-seen state and useless as a report. The rule had been applied mechanically without reading what was in the bucket.
  - **An unchanging standing count is not the same as nothing happening.** EJA-3488's count held steady at 10 for hours while its conductor was dead at a gate — so also report, for each named item, whether anything is actually moving on it (live conductor / open PR / branch commits). "Standing, and nothing has touched it in N hours" is the report; "standing" alone is not.
- **Cleared since last run** (moved out of Failed QE) → one line, so a fixed bounce visibly closes.

**A bounce on someone else's ticket still gets the RCA** (Kyle, 2026-08-07, on EJA-3462 — assigned to Alex Smith, dispatched anyway). The live-assignee gate exists to stop the fleet *claiming and building* work a named engineer holds; a read-only RCA does not claim anything, and handing the owner a diagnosis helps them rather than stepping on them. So: **dispatch the research X-Man regardless of assignee, and never dispatch a code conductor on a ticket someone else owns.** Say in the report that the ticket belongs to <name>, so routing the fix stays Kyle's call.

**Then address it, per §5's bounced-ticket rule** — a bounce needs diagnosis before anyone scopes a fix:

1. Dispatch a **research** X-Man for the RCA: `scripts/cerebro/cb-start --research rca-<lowercased-key>-failed-qe --target ultron`, then `cb-send` it a one-line pointer to a brief naming the ticket, the bounce comment verbatim, and the PR that was supposed to fix it.
2. Emit or flip the dev item to **`drafting`** with `--needs-scoping --note "RCA in flight: <slug>"`, so `cb-intake` cannot claim a half-scoped item.
3. It flips to `queued` when the RCA lands via `/ingest`.

⚠️ **A merged PR is the strongest bounce signal, not a reason to discount it.** EJA-3535 (Blocker, `Ph1-TL-W1`) was in Failed QE on 2026-08-07 with its fix PR **merged that same day** — `bugpush-eja-3535-pru-fixed-daily-3317ct-appsub`, reaped 13:52. A tick that reasons "the PR merged, so it is handled" reports the loudest failure in the wave as done.

**Do not transition, comment on, or reassign the ticket.** The watch surfaces and diagnoses; the outward reply to QE is Kyle's.

### 5d. ASD REOPEN WATCH — runs alongside §5c, reports second

Commissioned by Kyle 2026-08-11: *"I need to enhance the tick check to include checks for ASD tickets that are reopen. Also need this during the night shift because most of EDJs qe team is in India and they will test while I am asleep due to the time zone offset."*

A reopen is §5c's other half, and it is silent for the same reason. The ticket was already worked, so it is already assigned: `cb-intake` reads dev-item `status:` only, and the §4 emit path skips anything assigned. Nothing else in the machinery notices an EDJ tester pushing a ticket back. **Run this with §5c, before §1**, and report it directly under the failed-QE line.

**The overnight framing.** EDJ's QE team works from India (IST = MT + 12½h), so their testing day is Kyle's night. ASD-652 was reopened at **04:29 MT**. A reopen found on the first morning tick is reported as *reopened overnight*, with the local time it happened — that is the whole reason the night shift carries this too (`ns-ticket-intel`, Cluster B).

**Query.** Both halves, same reasoning as §5c:

```
project = ASD AND status = "Reopened"
project = ASD AND status CHANGED TO "Reopened" AFTER -<window>
```

`Reopened` is a real ASD status (id `4`, *"This work item was once resolved, but the resolution was deemed incorrect."*) — verified live 2026-08-11, not a guess. Use a **24h** window on the hourly tick, matching §5c. **The second half is not optional:** measured 2026-08-11, **24 ASD tickets moved to `Reopened` in the last 7 days and only 4 were still standing in it** — ASD-1144 had moved on to *Ready for Partner Testing*, ASD-1299 to *Done*. A status-only query reports 4 and misses 20.

🔴 **THE REOPEN REASON IS IN THE COMMENTS. ASD has NO `Reason For Failure` field.** `customfield_10078` — the field §5c depends on for EJA — does not exist on ASD issues, so the §5c recipe does not port. The reopen comment lands within a minute or two of the transition — but **it usually comes BEFORE it, not after**, because a tester writes what they found and *then* flips the status. **Take the newest comment in a window around the transition — ±30 minutes is generous and safe — not `>= transition_timestamp`.**

⚠️ **This rule said "at or after the transition timestamp" until 2026-08-12, and that off-by-a-few-seconds filter reported real bounces as unexplained.** Measured the day it was corrected: ASD-764 transitioned at `13:55:29` and Greg Phillips had commented at `13:55:0x` — *"I did a cash esign order and it had me initial the statement, but the question did not even show on the order.  need a fix for that."* An `>= created` comparison on full ISO timestamps dropped it, and the tick reported ASD-764 as *"no comment at or after the transition, reason unrecorded"* — which is the worst possible output for this watch, because it tells Kyle to go ask a tester who already answered. ASD-1277 and ASD-1292 failed the same way in the same window. **Never report a reopen as unexplained on the strength of an at-or-after filter.**

Quote it verbatim with sender and timestamp; never paraphrase what a tester wrote. If the window genuinely holds nothing, widen it and read the thread before saying so.

Worked example, ASD-652 (status changed `2026-08-11T04:29:36`; `Anusha.Kolloju@edwardjones.com` commented at `2026-08-11T04:29:36`):

> "I have given the case ID and it is reproducible as FA for the case in Pending brokerage funding. Hence reopening the bug"

preceded one minute earlier by the repro itself:

> "When I login as FA Tyler Wallace 453263 and open a case which is in Pending brokerage funding from the dashboard. I am able to edit and resubmit"

That answered Joseph Colson's 08-10 comment — *"Our team has re-tested that Pending Brokerage Funding status. We're unable to reproduce what you're seeing… Could you please create a new case and try again?"* — with a working repro. That is the shape of a real reopen, and it is what Kyle needs in front of him.

⚠️ **`?expand=changelog` is unreliable here.** Fetching ASD-652 that way returned exactly **one** status transition (`2026-06-01 Open → Request Received`) and omitted the 08-11 reopen entirely — the embedded changelog is truncated. Use the dedicated endpoint when you need who reopened it and when:

```
GET /rest/api/3/issue/<KEY>/changelog
```

⚠️ **Do not use `customfield_10407` ("QE Return Count") as a repeat-reopen counter.** It read `0.0` on ASD-652, a ticket that had just been reopened. It is not maintained; the changelog is the only trustworthy route to a repeat count.

**Follow to the EJA mirror** the same way §2 does, and report it — the mirror is where any fix rides. **Apply the live-assignee gate to the EJA mirror, never to the ASD.** Never reassign, transition, or comment on the ASD ticket: POs own the inbound ASD queue ([[.claude/memory/feedback_asd_po_ownership]]), and the outward reply to the tester is Kyle's. This step reads ASD and writes nothing to it.

**Wave scoping**, same as §5c — ASD `Launch` field (`customfield_11448`, e.g. `Ph1-TL-W1`) → EJA mirror, union'd with any EJA carrying the label directly. ⭐ The wave label does work on ASD: ASD-652 carries `Launch = Ph1-TL-W1`. Report an out-of-wave reopened **Blocker** anyway, marked `outside wave`.

🔴 **Report `priority` ONLY. Porch does not use severity — Kyle, 2026-08-14: *"Sev prioritization is not something we're currently supporting. Only blocker, high medium and low along with tags. This was communicated verbally with Bryan yesterday."*** The supported scale is **Blocker / High / Medium / Low, plus tags**. `customfield_10162` ("Severity", e.g. `Sev-1 (HIGH)`) and `customfield_11105` ("Priority - Service Desks") still hold values on old tickets and still disagree with `priority` — **ignore both.** Quoting a Sev number gives a retired scale the authority of a live one and invites work to be ranked against something nobody maintains. ⚠️ This reverses the rule that stood here until 2026-08-14, which said to lead with `priority` and *carry Severity alongside it*; that produced tick reports reading "High / Sev-1 (HIGH)" for a field Porch had stopped using. `customfield_11238` ("Environment - Annuity", e.g. `EDJ UAT`) and `customfield_10002` ("Organizations") are in the payload and **are** worth reporting.

**Diff against last-seen.** Persist the key set to `~/.cerebro/watchlist/asd-reopened.state`, one key per line, mirroring §5c's `tl-failed-qe.state`. Then:

- **New since last run → this is the notification.** Key, `priority` (not Severity — see above), assignee, the wave label, the EJA mirror and its owner/status, the local time of the reopen, and the reason comment **verbatim, attributed, with its timestamp**.
- **Already seen → one tally line.** `asd-reopened: N standing (unchanged)`.
  - 🔴 **SEVERITY OVERRIDES THE COLLAPSE. A standing reopen that is a `Blocker`, or that carries `Ph1-TL-W1`, is NAMED every tick** — key, age, owner, and **whether anything is actually moving on it** (live conductor / open PR / branch commits). An unchanging standing count is not the same as nothing happening; §5c carries the case that proved it.
- **Cleared since last run** (moved out of `Reopened`) → one line, so a resolved reopen visibly closes.

**Never gate on assignee for inclusion.** A reopen is already assigned — that is precisely what makes it invisible.

### 5e. WAVE 1 PR DESTINATION — runs after §2, reports third

Commissioned by Kyle 2026-08-11: *"Also need to make sure that tickets with the wave 1 label have pull requests targeting the release branch that Nick created until the release goes out."*

The branch is **`release/eja-1.0.0`**. Nick Farland announced it in `#annuities`, 2026-08-10 08:40:29 MDT:

> "<!here> Hear ye, hear ye! The release candidate branch has been created! If you are working on release candidate bugs or stories, please change your target branch to release/eja-1.0.0 (bitbucket.org/porchsoftware/ultron/…/eja-1.0.0). Work that is not critical or required for the release should go to main. I will have more specific instructions to share at SU today."

Don't confuse it with `release/edj-1.0.0` — that is Edward Jones **Life**, a different branch on a different cadence ([[.claude/memory/feedback_annuity_only_during_golive]]). Several other release-ish branches exist on the remote (`release/2026-05`, `cs-release-eja-4064`); none of them is this one.

**This step runs AFTER §1 and §2**, unlike §5c and §5d which run before them. It needs §1's wave population and §2's mirror map to decide whether a given PR belongs to a Wave 1 ticket. There is no `.state` file either: a destination read is current state, reported in full every tick, not a new-since-last-run watch.

**Read `destination.branch.name` off the open-PR enumerate call** ([[.claude/memory/reference_bitbucket_pr_read]]), adding two fields to the recipe there:

```
--data-urlencode "fields=size,next,values.id,values.title,values.source.branch.name,values.destination.branch.name,values.author.display_name"
```

`author.display_name == "Kyle PR Work"` is the fleet's own queue; everything else is a human's.

**Classify each open PR** by pulling its EJA key from the source branch or title, then following §2's mirror map to decide whether that key is Wave 1. Branch naming is a convention, not a guarantee — `fe/eja-3947-gender-required-uat` resolves,
`fe/trusttaxid-person-scope-fix` does not. A PR with no resolvable key is out of scope: **count it and
carry the count into the §6 line**, never guess at it and never drop it silently.

🔴 **A Wave 1 PR targeting `main` is NAMED every tick** — PR id, EJA key, author, source branch — because it will not reach the release. Same severity-overrides-the-collapse discipline as §5c and §5d: this one never collapses into a tally.

⚠️ **Kyle's test and Nick's are not the same test, so a flagged PR is a question, not a proven error.** Kyle's rule keys on the **Wave 1 label**; Nick's on whether the work is *"critical or required for the release."* A Wave 1 ticket that isn't release-critical belongs on `main` under Nick's wording, and a release-critical ticket outside Wave 1 belongs on the release branch under it. Report the PR and let Kyle confirm the routing — never characterise the author as having got it wrong.

**Surface only. Never retarget a PR, never edit one, never merge.** Changing a PR's destination is an outward write on work someone has already reviewed, and it is Kyle's call. **A PR the fleet did not author is read-only** — report it, never propose changing it. Dagan's PRs are his.

**Measured 2026-08-11 16:0x MT, which is why this check exists:** all **13** open PRs targeted `main`, including two Wave 1 fleet PRs — **#2784** (EJA-3947 ← ASD-1126) and **#2778** (EJA-3488 ← ASD-1086). Dagan Danevic was the only person routing to the release branch (#2804, merged 14:11 UTC). The gap was real, not hypothetical.

🔴 **THIS STEP EXPIRES WHEN THE RELEASE SHIPS.** Left in place afterwards it reports every correctly-targeted PR as a violation and pushes work at a dead branch. The checkable condition: `git merge-base --is-ancestor origin/release/eja-1.0.0 origin/main` returns true, or the branch is gone from origin. Once either holds, delete this step, its `§6` report line, and the matching block in `dispatch` C4.

### 6. Report one line

`failed-qe: N new (keys) / M standing / P cleared` — **first, always, even when zero.**

`asd-reopened: N new (keys) / M standing / P cleared` — **second, always, even when zero.**

`wave1-target: N correct / M targeting main (PR ids) · K unresolvable keys` — **third, always, even when zero.** Retires with §5e when the release ships.

**Name every Blocker and every `Ph1-TL-W1` item in either standing count on its own line**, with its age and whether anything is moving on it — the bare tally is only for the rest. See §5c and §5d.

`tl-wave: N emitted (queued X / drafting Y) · M held (dedup A / assignee B) · P mirror-less ASD rows · population Q`

## Bounds

- Never reads, assigns, or transitions an **ASD** ticket.
- Never edits any Jira field, including a priority it believes is wrong.
- Never dispatches a code conductor — `cb-intake` is the single claiming path.
- Never retargets, edits, comments on or merges a **pull request** — §5e reads `destination.branch.name`
  and reports; the retarget is Kyle's.
- Never assigns tickets up front. Assignment happens at dispatch, one at a time, when a conductor
  actually starts (Kyle 2026-08-07, so the EDJ board stays truthful about who is working what).
- Never commits or pushes.
