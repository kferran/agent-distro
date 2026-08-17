---
name: deploy-verify
description: Read-only check of which environments a ticket's fix has deployed to (dev → test → demo → playground → preprod → UAT), with by-proxy + window-aware verdicts. Triggers — "/deploy-verify", "is EJA-/ASD-X deployed", "did this reach UAT", "where is this fix deployed".
---

# /deploy-verify

Answers "which environments is this ticket's fix in?" for an EJA/ASD key or batch, against the EDJ deployment tracker. Read-only. Engine: the bundled `deploy_tracker_web.py` (sibling to this file).

## Prerequisites (internal-at-Porch tool)
- **On the Porch internal network** — the tracker (`deployment-tracker.np.porch.internal`) is internal-only; off-network the skill cannot reach it.
- **Python 3** (3.6+), stdlib only — nothing to `pip install`.
- **Atlassian MCP authorized** — for mirror/sibling (by-proxy) resolution. Without it the skill still runs but degrades to direct-key-only and says so (verdicts less reliable that run).

## Modes
- `/deploy-verify EJA-3128` — single ticket: headline verdict + the full environment ladder (which envs it's in, carrying key, dates).
- **`when <KEY> [--at <ISO>]` — "was it deployed WHEN?"** Per env, the first build that carried KEY, and with `--at`, whether that predates a given instant plus the margin. **Use this, not the headline verdict, whenever you are reconciling a Failed QE against a retest** — see below.
- `/deploy-verify --batch <ASD/EJA list>` — table, one row per ticket with env-ladder columns (dev/test/demo/playground/preprod/uat) + headline.
- `/deploy-verify --uat-mirror-scan` — full open-ASD-with-Done-EJA report, bucketed against the UAT gate.

## Procedure
1. **Resolve candidates (Jira MCP).** For each input key, `getJiraIssue` with fields `issuelinks`, `comment`, `resolutiondate`, `status`. ("Mirror EJA" below = whatever EJA(s) the input ticket links to — a "Caused by" / "Relates" / clone link, not necessarily a structural clone.) The candidate set = the ticket itself + every related EJA that could carry the fix, found TWO ways:
   - **Issue-links:** EJAs linked via Cloners / Duplicate / Relates / "Complete".
   - **Closure comments (the dominant by-proxy path):** EJAs named in the mirror EJA's comments as the actual carrier — phrases like "took care of in EJA-XXXX", "fixed by/in EJA-XXXX", "duplicate of EJA-XXXX", "closing … see EJA-XXXX". Extract those `EJA-\d+` keys and include them as candidates. (Example: EJA-1869 has no issue-link to EJA-1870, but its closing comment says "Winona took care of this with her changes in EJA-1870" — EJA-1870 is the carrier the tracker actually sees.)
   One hop is enough — the carrier is named directly in the mirror EJA's links or closing comment; don't chase the carrier's own siblings.
   Build the candidates JSON, e.g.:
   `{"ASD-690": [{"key": "EJA-1869", "resolutiondate": "2026-06-04"}, {"key": "EJA-1870", "resolutiondate": "2026-06-04"}]}`
   - If the Atlassian MCP is unavailable, fall back to the bare input keys and warn that by-proxy resolution was skipped (verdicts less reliable this run).
2. **Crawl (cached).** From the vault root, run `python3 .claude/skills/deploy-verify/deploy_tracker_web.py crawl` (add `--integration` for DTCC/Cannex/etc. tickets). The cache persists for the session; re-run with `--refresh` only when staleness matters.
3. **Verdict.** From the vault root, pipe the candidates JSON to `python3 .claude/skills/deploy-verify/deploy_tracker_web.py verdict --candidates -`.
4. **Format.** Render per ticket: headline (✅ in UAT / 🟡 promoted-not-UAT / ⚠️ genuine gap / ◻️ pre-window / 🆕 too-new / ❔ unknown (no resolution date or window — can't classify)) + the env ladder (which envs, carrying key, build dates). Always print the commit-attribution caveat on a ⚠️.
5. **Multi-PR keys — timestamps discriminate, key-presence doesn't.** When a ticket shipped MORE than one PR (original + correction — e.g. EJA-3525's #2413 wrong-copy then #2460 correction), the tracker's key-presence answers "some build with this key" — NOT "the build with the fix you care about." Resolve each PR's merge time (git), then compare **build timestamps** per env against the later merge: an env is only "carrying the correction" if a build in that env postdates the correcting PR's merge. (2026-07-15 lesson: a key-presence read supported a wrong deploy-gap verdict on EJA-3525; the timestamp trace overturned it — the corrected build had been live ~24h.)

### `--uat-mirror-scan` (full population)
The single/batch flow above needs input keys; the scan discovers its own population:
1. **Enumerate open ASD tickets** (Jira MCP, paginate): `project = ASD AND statusCategory != Done ORDER BY created DESC`, fetching `summary, status, assignee, priority, issuelinks`.
2. **Resolve + filter:** for each open ASD, resolve its mirror/sibling EJAs (Procedure step 1 — issue-links + closure comments). **Keep only ASDs that have at least one linked EJA in a Done status** (`statusCategory = Done`) — confirm the EJA statuses with one batched JQL `key in (…) AND statusCategory = Done`. These are the "open ASD with a Done EJA mirror" population.
3. **Crawl + verdict** that population (Procedure steps 2–3), then **bucket by headline against the UAT gate** (✅ in UAT / 🟡 promoted-not-UAT / ⚠️ genuine gap / ◻️ pre-window / 🆕 too-new), Blocker/High first.
4. Deliver the bucketed report to a review surface (e.g. an Inbox doc) — read-only, don't auto-post. This reproduces the 2026-06-22 closeout report.

## ⚠️ Reconciling a Failed QE against a retest — use `when`, and measure DEPLOY not MERGE

The headline verdict answers *"is it deployed?"*. A Failed-QE reconciliation asks *"was it deployed
**when** the validator tested?"* — a different question, and the one that decides whether a re-fail is a
real defect or a stale-build artifact.

**The trap, from EJA-3881 (2026-07-31).** PR #2572 merged to `main` on 07-27 19:20 UTC and the retest
was 07-28 19:52 UTC, so a merge-time reading said "deployed 24½ hours earlier — the retest is valid,
the defect is real." `when` shows Playground actually received it at **07-28 19:46:50** — a margin of
**5 minutes**. The validator's comment describes running the flow and attaching three screenshots, so
her run almost certainly *began before the fix landed*. The conclusion flips.

Rules that follow:
- **Merge time is not deploy time.** Never reason from a git merge timestamp; the ladder that day ran
  dev → test 17:30 → playground 19:46 → uat 20:05 → preprod 20:43, i.e. hours apart.
- **Compare against the env the validator actually used**, taken from the ticket's repro. UAT and
  preprod had not received EJA-3881 at 19:52 even though Playground had.
- **A margin under ~1h is not confirmation.** Testing takes time; a fix landing minutes before a
  comment says nothing about what the tester was running.
- **`first_carried: null` is not "never deployed"** — an incremental crawl may not have fetched the
  introducing build. Run `crawl --refresh` before concluding absence.
- **The durable fix is upstream:** require the build SHA at test time. Deploy timing can bound the
  question but never fully close it, because it dates the deploy, not the test.

## Notes
- Read-only: never transition tickets or post comments.
- A ⚠️ "genuine gap" means "verify," not "proven undeployed" — surface the caveat.
- In core-edj, the `demo` and `preprod` stages are infra-only (carry no ticket keys), so the ladder will legitimately show those columns empty.
- `--uat-mirror-scan` produces the full open-ASD-with-Done-EJA report; deliver it to a review surface, don't auto-post.
- Its **✅-in-UAT bucket** (fix deployed, ASD still open) feeds `asd-triage` Step 5c (residual-refile → fresh-EJA drafts for the closed-but-not-resolved case). deploy-verify stays read-only detection; the drafting/create lives in asd-triage.
