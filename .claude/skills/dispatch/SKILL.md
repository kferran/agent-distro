---
name: dispatch
description: Coordinator skill — spin up an X-Man for a code, research, OR ops request. ⭐ A dispatch that names a JIRA TICKET goes to the CODE lane by default and is expected to end in a PR — a read-only report is not the deliverable (Kyle 2026-08-10). Code — activates or creates the dev item, spawns a per-slug conductor session via cb-start --code, writes context.md into the run dir, sends the launch line. Research — the exception, for a question whose answer is not a code change; scaffolds the brief, fills its Context from the vault via the retrieval rule, spawns a read-only X-Man that must still emit a spawn-ready fix brief. Ops — a write/ops task (vault sweep, reporting run, approved batch): writes the brief with scope + approved outward writes, spawns a supervise-only board X-Man via cb-start --ops. Returns immediately (fire-and-forget). Triggered by "dispatch EJA-1234", "dispatch/activate/spawn <slug>", "fix X via cerebro", "review <ticket>", "research X", "investigate X", "audit X", "run the ops sweep X".
allowed-tools: Read, Edit, Write, Glob, Grep, Bash
---

# Dispatch — spawn an X-Man

Coordinator-side "fill and spawn" step for a Cerebro task. Assembles context from the vault, hands it to a fresh X-Man, and gets out of the way. Full model: `99 Meta/Cerebro-spec.md` §6.1 (research) / §6.3 (code).

## Board X-Men only — never an Agent-tool subagent

**Every Kyle-requested dispatch spawns a board X-Man via `cb-start`** (cb-meta + `--remote-control`, visible on `cb-board` / the remote view). **Never** fulfill a "dispatch an agent" request with a plain Agent-tool background subagent. Rationale (Kyle, 2026-07-17): the coordinator thread must stay **light and free to keep dispatching**, and every X-Man must be **visible and steerable**. An Agent-tool subagent is invisible on the board and notifies back into the coordinator context — both defeat the purpose.

- Code change → `cb-start --code`. Read-only research/analysis → `cb-start --research`. **Write / ops task that isn't code-conductor work** (a Jira-batch execution, a vault-maintenance sweep, a reporting run) → `cb-start --ops` (the ops branch below) — board-visible + supervise-only, never a fallback to Agent-tool.
- This rule governs Kyle-requested dispatches. Internal fan-out the coordinator runs itself (the night-shift workflow, task-rollup) is not a "dispatch an agent" request and is unaffected.

## ⭐ A dispatch naming a Jira ticket is a CODE dispatch — the deliverable is a PR

**Kyle, 2026-08-10:** *"The intention with dispatch an xman to review a jira ticket is to resolve the issue. Performing a read operation only is not useful when the results require a code fix. Update the dispatch behavior to always allow code changes."*

**Rule.** A bare ticket key or ticket URL — `dispatch EJA-4077`, `dispatch someone to review EJA-3589`, `look at ASD-1301` — routes to the **code lane** (C1→C5 below), regardless of the verb. "Review", "look at" and "investigate" attached to a *ticket* mean **resolve it**, not describe it. The X-Man may change code, commit, and push; the run ends at a PR. Merging stays Kyle's, and so does every outward write.

**Research is the exception, not the default**, and it needs a reason you can state: the deliverable genuinely is not a code change (a scope question, an architecture assessment, a "which of these should we do"), or the ticket is *someone else's* and C1c holds it. **Even then the research brief must require a spawn-ready fix brief** — files, the change, the tests that would pin it — so the next step is a spawn and not a second investigation.

**Why this exists.** On 2026-08-10 four ticket dispatches (EJA-3488, EJA-3589, EJA-3615, EJA-4077) all went to the read-only lane. Three returned a correct diagnosis and no fix; the fourth confirmed a prior verdict. Kyle's response was the quote above. A diagnosis nobody can act on without another dispatch is half a delivery, and the missing half is the expensive one.

**Two gates still win over this default** — they are about *ownership*, not about read-versus-write, so the new default does not touch them:
- **C1c live-assignee** — a ticket assigned to a real person who is not Kyle is still held, not claimed. Hand them the diagnosis instead; that is a legitimate research dispatch.
- **C1b arch-check** — a `GAP` still routes to the architects rather than spawning a conductor into a missing seam.

⚠️ **A code dispatch performs the C2b Jira write** — transition to In Progress and assign to Kyle. That is intended, and it is the visible difference from the old default: under the read-only lane these dispatches made no Jira writes at all.

### ⛔ No release-scope gate — asked and declined 2026-08-10, do not re-propose

**There is deliberately no check that stops `dispatch` spawning a ticket that is outside an open release's scope.** It was proposed and Kyle said no: *"No gate — keep filtering."*

The context, so the reasoning is legible rather than just the verdict. On 2026-08-10 he declined four fleet PRs in one sweep — #2787, #2788, #2651, #2797 — and explained: *"The declined PR's was entirely due to prioritization of work related to the upcoming release."* The diffs were not defective; they were competing for review attention with the `release/eja-1.0.0` cut. Two of the four turned out to be already solved by other means, one was `Post-GA`, one was open `Ph1-TL-W1`.

The obvious inference was to gate dispatch on release scope (`Ph1-TL-W1` / release-branch membership) while a release is open. **He chose to keep the backlog draining and filter at the PR instead** — a decline sweep costs him less than a frozen non-release queue. `eja-4093` (`Ph1-GA`, Low) was live at the time and he let it run to a PR rather than stopping it.

**What this leaves open, and it is the real gap:** a decline carries no comment, no `changes_requested`, and no reason field, so the fleet cannot tell a prioritization decline from a quality one. Ask for a line per decline rather than re-proposing the gate.

## Invocation

**A Jira ticket key or URL, on its own or with any verb** — `dispatch EJA-4077`, `dispatch someone to review EJA-3589` — is the **code** trigger (see the rule above). "activate `<slug>`" / "spawn a conductor for `<slug>`" / a clear code-change ask ("fix X", "implement Y") are code too. A request shaped like "research / investigate / audit / look into `<topic>`" where **no ticket is named** is research. Kyle names the topic; you derive a short kebab-case slug from it if he didn't give one.

A bare **`dispatch-request <slug>`** line (typed into the session by `cb-intake`'s hourly tick) is also this skill's code-branch trigger: the item arrives **already claimed** — intake flipped `status: queued → active` inside its lock — so run the **C1b arch-check gate** first, then in C2 skip the flip, do the remaining edits (active-only frontmatter, In-flight line, Inbox-stub delete), and continue C3→C5 as normal. (If C1b diverts on UNCERTAIN/GAP, it reverts that intake flip — see C1b.) The C1 already-active check doesn't apply to an intake claim (no `worktree_path` yet = claimed-not-dispatched).

## Scope

Three task types, three branches below. **Code is the default for anything naming a ticket** — it wraps the `ultron:work-conductor` in a per-slug tmux session and ends at a PR; supervise-only for *this* skill, which never writes conductor artifacts (`manifest.md`, `01-spec.md`–`04-ship.md`) and never answers a gate, but the conductor itself changes code, commits and pushes. **Research** produces a report and touches no code (read-only) — the exception, and it owes a spawn-ready fix brief. **Ops** performs a bounded write/ops task (vault sweep, reporting run, approved ops-batch) — supervise-only, writes confined to scope, no commit/push, no unapproved outward writes. A dev item's `task_type:` frontmatter (`code` default / `research` / `ops`) names the branch; **when a ticket is named and the frontmatter is silent, it is code.** Ask only when a stated reason points at research and you cannot settle it.

## Steps — research

### 1. Confirm the task type — and that research is genuinely right
Research (investigate/analyze/audit, produces a report, touches no code). **If a Jira ticket is named, the default is the code branch below** — take this branch only for a stated reason: the deliverable is not a code change, or C1c holds the ticket for a live assignee. Write that reason into the report you hand back, so the choice is auditable.

**Whichever the reason, a ticket-linked research brief must require a spawn-ready fix brief** in its Definition of Done — the files, the change, and the tests that would pin it — so the finding is one `cb-start --code` away from being built rather than one more investigation away.

### 2. Scaffold the brief
```bash
scripts/cerebro/cb-brief --research <slug> [--target <project>]
```
`<project>` is a row in `projects.md` (e.g. `ultron`, `cerebro`, `friday`) when the research needs to read a specific checkout; omit it for vault-only synthesis. This writes `~/.cerebro/tasks/<slug>/brief.md` with empty `# Objective` / `# Context` / `# Scope` / `# Definition of done` / `# Escalate if` / `# Deliverable` sections.

### 3. Fill the brief
Edit `~/.cerebro/tasks/<slug>/brief.md` in place:

- **`# Objective`** — one bounded sentence: what "done" looks like, not how to get there.
- **`# Context`** — fill by the vault **retrieval rule**, same discipline as any substantive vault question:
  - Pull only relevant notes — never dump a folder. Follow frontmatter tags, the matching platform hub / domain wiki (`03 Resources/technical/`), `[[links]]` out from what you land on, and — if it touches active work — `hot.md` and the relevant active dev item(s).
  - **Name every note the context rests on** (`[[link]]` or `file:line`) so the X-Man's starting point is auditable, and so the X-Man isn't re-deriving from scratch.
  - **Honor `Confidential/` strict mode** — never read, search, or pull from `Confidential/` into a brief unless Kyle explicitly pointed at a specific file. If he did, set `clearance: confidential` in the frontmatter (default is `standard`); a `standard`-clearance brief must never carry `Confidential/` content.
  - If the vault doesn't cover the topic, say so in Context plainly rather than leaving it thin and silent — the X-Man needs to know it's starting cold.
- **`# Scope`** — `In:` / `Out:`, explicit boundaries so the X-Man doesn't wander.
- **`# Definition of done`** — a checkable list.
- **`# Escalate if`** — conditions that should flip the task to needs-input rather than the X-Man guessing.
- **`# Deliverable`** — leave as `report.md` (the fixed contract; don't change it). ⚠️ **Do not write a
  `00 Inbox/…` path here** — the research lane is read-only on the vault, so a brief that names a vault
  deliverable asks for something the agent contract forbids. The vault write is `cb-land`'s, at the path
  already stamped into the brief's `deliverable:` frontmatter.
  (Broken four times on 2026-08-06 alone; the agents were right and the briefs were wrong.)

### 3b. ⭐ Diagnosis briefs: say that Jira attachments ARE pullable

**Any brief whose job is to diagnose — a Failed QE, an RCA, a triage, a "why is this broken" — must tell
the X-Man it can read the ticket's attachments, and how.** Read-only means read-only on *state*, not on
evidence: pulling an attachment is a read on a ticket we own with a credential we already hold. **Kyle
granted standing authorization 2026-08-06** — *"you don't need me to confirm pulling attachments when
diagnosing issues"* — so no brief should route this back to him for approval.

Paste the recipe into `# Context`; do not make the agent derive it:

```bash
set -a && . ~/.cerebro/env && set +a          # JIRA_EMAIL + JIRA_API_TOKEN
base=https://porchsoftware.atlassian.net
{ printf 'user = "%s:%s"\n' "$JIRA_EMAIL" "$JIRA_API_TOKEN"; } | curl -s --config - \
  "$base/rest/api/3/issue/<KEY>?fields=attachment" \
  | jq -r '.fields.attachment[]? | "\(.id)\t\(.filename)\t\(.size)"'
{ printf 'user = "%s:%s"\n' "$JIRA_EMAIL" "$JIRA_API_TOKEN"; } | curl -s --config - \
  -L -o "00 Inbox/attachments/<KEY>/<filename>" "$base/rest/api/3/attachment/content/<id>"
```

Basic auth, **not** Bearer (the opposite of Bitbucket). `-L` is required. Token on stdin, never argv.
`Read` renders PNGs directly, so a screenshot becomes evidence rather than a blocker.

**Why this is a brief-level rule and not just a memory.** The capability has now failed to reach the
agent twice: `rca-eja-3836` blocked **14 days** on a false 403, and `eja-3436-failed-qe-round2` returned
`status: partial` / `confidence: medium` on 2026-08-06 saying the video and screenshot *"could not be
read from this sandbox."* Both were right about their sandbox and wrong about the capability — and when
the coordinator pulled them, **the screenshot immediately answered the question the report had left
unresolved.** The rule lived in `.claude/memory/reference_jira_attachment_fetch.md`, which the
coordinator reads and the X-Man does not. Put it in the brief.

### 4. Spawn
```bash
scripts/cerebro/cb-start --research <slug> [--target <project>]
```
Same `--target` as step 2. This launches the X-Man in window `<slug>` in the `cb` tmux session (target `cb:<slug>`), working directory resolved per two tiers: `--target` given and the registry has a `checkout` for it → reuse that checkout (error if the project is unresolved or the checkout path doesn't exist — no silent fallback); no `--target` → a disposable `~/.cerebro/worktrees/<slug>` scratch dir. cb-start READS `brief.md` from the task dir and bakes it into the launch prompt itself (`cb-start:568`) — **nothing is piped in.** Do not pipe the brief (or anything else) into cb-start: it does not read stdin, and since 2026-07-31 it refuses outright rather than discarding the payload behind a success banner, which is how one conductor sat unbriefed for two minutes.

### 5. Return immediately
Report the slug and that the X-Man is running — nothing more. **Fire-and-forget: never do the research yourself, never wait on the X-Man, never read its output in this turn.** The board/watcher surfaces completion later.

## Steps — code (M5)

The dev item (`00 Inbox/<slug>.md`) is the single tracking home (spec §2.2) — no second ledger. All vault-side lifecycle edits below are YOUR work; scripts only write `context.md` + `~/.cerebro/tasks/<slug>/` runtime.

### C1. Confirm the dev item

Locate `00 Inbox/<slug>.md` (slug in frontmatter is authoritative; older files carry a date prefix). If none exists, create one from `99 Meta/templates/dev-item.md` per the development README, and get the spec to a dispatchable state (`/grill` if thin) before proceeding. Read its `repo:`/`domain:`/jira ref — `repo:` must match a deliverable row in `projects.md` (`delivery: bitbucket-pr` or `local-only`); refuse research-only rows. That registry row's `project:` key is the `<project>` every `--target` below takes.

**Dev-item collision check** (the fourth surface, complementing cb-start's three): if the item is already `status: active` with a live `worktree_path`, stop — it's already dispatched; point at the existing session instead. **Dedup on every key, not just the EJA key:** cross-check the whole `tickets:` set (the EJA mirror **and** its ASD key) against existing dev items — an ASD-mirror bug is often already tracked under an ASD-keyed `bugpush-*` item, so matching only the EJA key silently duplicates it (happened with ASD-1144 → `bugpush-asd-1144`, 2026-07-23). If a sibling item already covers any key, consolidate onto one (supersede the stale one, reuse its RCA) rather than spawning a duplicate.

### C1b. Arch-check gate — ON by default (skip only `build-direct`)

The architecture-readiness check is **part of dispatch**, not a separate manual step (Kyle, 2026-07-19). Before any lifecycle edit or spawn, gate a `code` item through it so a fix that needs a missing seam is diverted to the architects instead of sent into a wall:

- **Bypass:** if the item carries `autonomy: build-direct`, **skip this gate** — a pre-vetted mechanical fix (the same flag that skips spec-approval) is mechanical enough to skip arch-check. Proceed to C2. Also skip for non-`code` lanes (research/ops don't touch the capability surface).
- Otherwise run **`/arch-check <the item's ticket(s)>`**. Its first pass is cheap — an obviously-mechanical fix returns `PRESENT` in one step and dispatch continues normally. Three outcomes:
  - **PRESENT** (seam confirmed / obviously mechanical) → proceed to C2 → C5 (spawn as normal).
  - **UNCERTAIN** (arch-check dispatched a read-only code-verify X-Man) → **do NOT spawn.** Revert the claim to **`status: drafting`** (see the 🔴 note below — never `queued`); add a blocker note in the item — `blocked: arch-verify in flight (<verify-slug>)`. When the verify lands (`/ingest` its verdict), re-dispatch: `PRESENT` → flip to `queued` and spawn; `GAP` → route.
  - **GAP** (confirmed missing seam) → **do NOT spawn.** Revert the claim to **`status: drafting`** with a note — `blocked: needs-architecture — <missing capability>; routed to Albert/Alex`. The arch-check report is the scoping packet; **Kyle** routes it. Do NOT run C2b (the ticket must not read *In Progress* for work that can't proceed).

  > 🔴 **A held item goes to `drafting`. Never leave it at `queued`.** This step said *"set it back to
  > `queued`"* / *"`status: queued`, or `drafting` if it needs re-scoping"* until 2026-08-13, and that
  > instruction guarantees a loop: **`cb-intake` reads `status:` only and never sees `blocked:` or
  > `hold:`**, so a held item parked at `queued` is re-claimed on the next hourly tick, burns one of
  > the three claim slots, and emits a `dispatch-request` that has to be refused by hand — every hour,
  > forever. Measured on `eja-4164-asd-eja-dashboard-transaction-status-and-ticket-pro`: held UNCERTAIN
  > at `queued` at 14:2x, arch-check returned GAP, and intake claimed it anyway at 16:0x.
  > `drafting` is the only status intake ignores, which is what makes it the held state.

### C1c. Pre-dispatch holds — never dispatch someone else's ticket, or a spec-gated one

Two live re-checks before any lifecycle edit or spawn — **the triage/queue that surfaced this item is a candidate list, not ground truth** (a direct instance of the CLAUDE.md verify-before-assert protocol; validated 2026-07-23 when a fresh triage confirmed a 4-item assignee over-count from a prior "released/clean" verdict). These apply to **every** code dispatch, including `build-direct` (they're orthogonal to arch-readiness — C1b's bypass does not skip them):

- **Live-assignee gate.** `getJiraIssue` the item's `jira:` key (+ each `tickets:` key this fixes) for `assignee`. If it's a **real person other than Kyle** (not unassigned, not Kyle), **do NOT dispatch and do NOT run C2b** — reassigning a named engineer's ticket to Kyle is an outward-facing call that's Kyle's, not the loop's. Revert the intake claim to a held state (`status: drafting` + `hold: Jira-assigned to <name> — reassign is Kyle's call`) and surface it. A triage's "released/clean" verdict does **not** override a live assignee. (Unassigned or Kyle-assigned passes.)
- **Spec-gate.** If the dev item's own body gates dispatch on an unanswered question — a `## Open questions` / `## Status` line like "queue after Kyle confirms Q1/Q2", or a `blocked:` / `hold:` frontmatter field — **honor it over the triage verdict.** A ticket can be Jira-clean but code-blocked (build-direct can't guess un-derivable values, e.g. product-code strings). Don't promote past the item's own gate; leave it held and surface the questions rather than spawning a conductor into a predicted `blocked:`.

### C2. The three vault-side lifecycle edits

1. Flip `status: queued` → `active`; populate `branch:`, `worktree_path:`, `repo:`, `last_synced: <today>`. **Both paths come from the target's registry row — never hardcode them.** `branch` is `<branch_prefix><slug>` (`fe/` for Ultron, `cerebro/` for the vault); `worktree_path` is `<worktree_root>/<slug>`, where `worktree_root` defaults to `~/code/worktrees` and is overridable per row (the vault row resolves into the vault's own `.claude/worktrees`). `cb-start` and `cb-brief` resolve it the same way, so a hardcoded `~/code/worktrees/<slug>` here records a path that does not exist for a vault-row target. `scripts/cerebro/lib/registry.sh` exposes `registry_worktree_root <project>`.
2. Add the **In-flight** line to the domain wiki (`02 Areas/platform/<domain>/wiki.md`), linking the dev item. Skip when the domain has no platform wiki (e.g. `tooling`) and say so.
3. Delete the `00 Inbox/` stub if one remains.

### C2b. Reflect the claim in Jira — status → In Progress + assign to Kyle

A claimed ticket must read **In Progress** and be **assigned to Kyle** in Jira so the board mirrors fleet reality (Kyle, 2026-07-18; assignment added 2026-07-21). At claim/dispatch time — including an autonomous intake claim — do BOTH for the item's `jira:` ticket (and each key in `tickets:` that this work actually fixes). **This is a mandatory, self-verified step — not skippable.** It silently missed on EJA-3663 (2026-07-21, spawned but left in Tech Refinement/unassigned); the verify in step 5 is what catches that.

1. `getJiraIssue` the key (fields: `status`, `assignee`) → read current status.
2. **Status — skip the transition** if already **In Progress** or a later working/Done status (Paused In Progress, PR Submitted, Pending Deploy, In Validation, Done, Closed, …) — never drag a further-along ticket backwards. (Still do the assignment in step 4.)
3. **Otherwise transition to In Progress.** From a To-Do-category status (Tech Refinement, Scoping Backlog, To Do, PO Review) there is **no direct hop** — it's two steps, and **the transition ids vary by source status, so read them live BY NAME, never hardcode:**
   1. `getTransitionsForJiraIssue` → fire the transition whose target status is **To Do** (e.g. from Tech Refinement it is id `501`, **not** `4` — the old hardcoded `4` was wrong).
   2. `getTransitionsForJiraIssue` **again** → fire the one named **`to In Progress`** (target status "In Progress"; typically id `11` from To Do — but confirm, don't blind-fire).
4. **Assign → Kyle** on every code dispatch, regardless of prior status: `editJiraIssue` with `fields.assignee = {"accountId": "5cc081d23f65fd0e7ecefb82"}` (Kyle Ferran). _(2026-07-21 — replaces the prior "leave assignee untouched" rule.)_ Safe because **C1c already held any ticket assigned to a real person ≠ Kyle** — only unassigned or already-Kyle tickets reach here, so this never yanks a named engineer's ticket.
5. **Verify (mandatory).** Re-`getJiraIssue` (fields: `status`, `assignee`) and confirm **status = In Progress** AND **assignee = Kyle**. If either didn't take, retry once; if it still fails, surface it — do **not** report the dispatch as clean.

This is the **one** Jira transition dispatch performs; everything later (validation, ship) stays off-limits per the Guardrail.

### C3. Spawn the conductor session

```bash
scripts/cerebro/cb-start --code <slug> --target <project> --jira <KEY>
```

Three-surface collision pre-check (worktree dir / branch local+remote / live session), registry-driven `git worktree add`, and a detached per-slug session running an idle claude. **If it refuses, revert ALL of C2's edits (status flip back to queued, clear the active-only frontmatter, remove the In-flight line — and restore the Inbox stub if you deleted one) and surface the named collision — don't force.**

### C4. Write the context

```bash
scripts/cerebro/cb-brief --code <slug> --target <project> --jira <KEY>
```

Then fill `context.md` in the run dir: `<worktree_path>/.ai/specs/<slug>/context.md`, using the `worktree_path` C2 resolved from the row rather than a hardcoded `~/code/worktrees/<slug>`. Source it from the dev item body — Objective / Context (retrieval-rule discipline, name every note it rests on) / Scope / Jira / Links (related dev items, specs, RCA docs) / Definition of done. The dev item is usually already tight enough to carry over near-verbatim.

⭐ **Every code `context.md` MUST carry a `# Landing` line, and for the code lane it is always the same one:** *"Push and open the PR when the build and tests are green. That is part of finishing, not a separate approval step. Do not merge — the merge is Kyle's."*

Measured 2026-08-11: an autofix conductor briefed this way went diagnosis → PR unattended in ~50 minutes (#2805), while two dispatch-lane conductors briefed to ask first sat at a "Ship it?" prompt for 17+ hours across seven ticks. Same tooling, same box, same night — the brief was the only variable.

⚠️ **Until the EJA release ships, a Wave 1 ticket's `# Landing` line must name `release/eja-1.0.0` as the PR destination, not `main`.** Nick Farland announced the release-candidate branch in #annuities on 2026-08-10 08:40 MT: *"If you are working on release candidate bugs or stories, please change your target branch to release/eja-1.0.0 … Work that is not critical or required for the release should go to main."* Don't confuse it with `release/edj-1.0.0`, which is Edward Jones **Life** — annuity is `EJA` + `ASD` (`.claude/memory/feedback_annuity_only_during_golive.md`).

**Whether the ticket is Wave 1 is decided by `tl-wave-sweep` §1 — the ASD `Launch` field, followed to the EJA mirror. Do not invent a second test here**; an EJA label query under-reports the population ninefold, and §1 is the one home for that rule.

🔴 **But the Launch field decides WAVE MEMBERSHIP, not the PR base — and conflating the two got a Sev-1 sent to the wrong branch (2026-08-13).** CR-7's residuals (ASD-651 funds-lock, ASD-1242 copy) both read `Ph1-GA`, so the dispatch routed them to `main` on the §1 test. Kyle declined the PR and asked for one on `release/eja-1.0.0`: a defect stranding client funds is *release-critical* whatever its Launch value says. §5e already states the distinction — *"Kyle's test and Nick's are not the same test"* — and this is what ignoring it costs.

**So run both tests, in this order.** Is the work **critical or required for the release** (Nick's wording)? → `release/eja-1.0.0`, regardless of Launch value. Otherwise, is it **Wave 1** by §1? → `release/eja-1.0.0`. Neither → `main`. When the two disagree and the answer is not obvious, **ask Kyle before dispatching** rather than defaulting to the label — the base is cheap to decide up front and expensive to correct after a decline.

🔴 **This rule was violated AGAIN the same day it was written, the same way — so default to `release` and ask, rather than defaulting to `main`.** EJA-4082's heading removal was dispatched to `main` on 2026-08-13 16:5x purely because the ticket reads `Ph1-GA`; Kyle came back within the hour asking for the PR on `release/eja-1.0.0`. Test 1 was never run. Twice in one day, the failure was identical: reading the Launch field and stopping.

The asymmetry is what makes the default obvious, and it is the part that was missing. **A wrong `main` costs a decline plus a cherry-pick onto a fresh branch cut from release** (see the retarget note below — CR-7's carried eight unrelated commits). **A wrong `release` costs a decline.** So on anything touching the EDJ launch surface, `release/eja-1.0.0` is the cheaper wrong answer, and "the Launch field says GA" is not by itself a reason to pick `main`. If test 1 is not a confident no, ask.

⚠️ **Retargeting after the fact is a cherry-pick, not a re-point.** A branch cut from `main` carries every `main` commit since the release branch diverged — CR-7's carried **eight** — and re-pointing its PR drags all of them into the release. Cut a fresh branch from `origin/release/eja-1.0.0`, cherry-pick the fix commit, and PR that. Note that `git worktree add` by hand skips the dependency install `cb-start` does, so the pre-push hook will fail on missing `node_modules` until you run `pnpm install` in the new worktree.

**`cb-pr-check` now takes `--base <branch>`** (added 2026-08-13) so the release branch is reachable through the path that fetches the 16 default reviewers. Do **not** fall back to a browser create or raw REST for a non-default base — that is the exact route that shipped PRs with zero reviewers ([[.claude/memory/feedback_pr_creation_no_browser]]).

This is a **destination** change only. The branch is still cut where the conductor normally cuts it, the build and test gates are unchanged, and the merge is still Kyle's.

🔴 **The rule expires when the release lands, and a stale copy of it sends every Wave 1 PR to a dead branch.** The checkable condition: `git merge-base --is-ancestor origin/release/eja-1.0.0 origin/main` returns true, or the branch is gone from origin. Once either holds, delete this block and the matching `tl-wave-sweep` §5e.

### C5. Send the launch line, return immediately

```bash
scripts/cerebro/cb-send <slug> "$(cat ~/.cerebro/tasks/<slug>/launch-line)"
```

The launch line (written by cb-start) invokes `ultron:work-conductor` naming the ticket and `context.md` as the Spec input — sent only now, after context.md is filled, so the conductor never reads a half-written brief. Report the slug, session, and branch — nothing more.

**Fire-and-forget: never wait on the conductor, and never answer a gate that asks Kyle to DECIDE something** — scope, an outward write, a product call. **The one exception: a gate whose only question is "shall I open the PR?" may be answered by the coordinator or by a fleet tick**, because the answer is fixed by the guardrail below and was never Kyle's to give. Answer it, and say in the report that you did. Everything else still waits for him.

The board/watcher surfaces `needs-input` when it pauses; Kyle attaches (`tmux attach -t <slug>`) or answers via `cb-send`.

### C6. Resuming a task that already has a worktree — one command, not three

C2–C5 are the FRESH dispatch. A task whose session was reaped or that died already has its worktree, its branch and usually its `context.md`, so it takes a different path:

```bash
scripts/cerebro/cb-resume <slug>
```

`cb-resume` reads the target, worktree and jira key from the task meta, adopts, re-briefs **only** when `context.md` is missing or is cb-start's adopted-session marker (it will not clobber a good one), splices `brief.md` in, sends the launch line, and then waits for observed evidence that an agent actually started. **Do not resume by running `cb-start --code --adopt` on its own** — that spawns the harness and writes the launch line without sending it, which produces a live session, a `running` beacon and a green board entry over an agent that has never been told anything. That is what happened to four code tasks on 2026-08-02.

## Steps — ops

The ops lane is for a bounded write/ops task that isn't code-conductor work: a vault-maintenance sweep, a reporting run, an approved Jira/Slack batch. Board-visible + supervise-only. Unlike research it may write; unlike code it produces no PR. `cb-start --ops` reads `~/.cerebro/tasks/<slug>/brief.md` and bakes the ops contract (write within scope, no commit/push, no unapproved outward writes) around it, so the brief is where you set the task's boundaries.

A bare **`dispatch-request <slug>`** for an `ops`-typed item arrives **already claimed** (intake flipped `queued → active` in its lock) — skip the O2 status flip and do the remaining edits.

### O1. Confirm the dev item + type

Locate `00 Inbox/<slug>.md`; confirm `task_type: ops`. If Kyle asked for an ad-hoc ops task with no dev item, you can still dispatch — derive a slug and write the brief straight from his request (no dev item needed for a one-shot).

### O2. Vault-side lifecycle (if there's a dev item)

Flip `status: queued` → `active` and refresh `last_synced` (skip the flip on an intake claim). Ops items normally carry `domain: tooling` and have **no** `branch`/`worktree_path`/`repo` and **no** platform-wiki In-flight line — say so rather than forcing one. Delete the `00 Inbox/` stub if one remains.

### O3. Write the brief

```bash
mkdir -p ~/.cerebro/tasks/<slug>
```

Scaffold the brief, then fill it:

```bash
scripts/cerebro/cb-brief --ops <slug> [--target <project>]
```

This writes `~/.cerebro/tasks/<slug>/brief.md` with the full frontmatter block (`task`, `type: ops`, `clearance: standard`, `status`, `worktree`, `report`, `deliverable`, `beacon`, `started`) and the section skeleton, plus the task-dir `meta` carrying `kind=ops` and the **computed landing path**. **Use it — do not hand-write the brief.** A hand-written brief has neither: no `clearance:` for the lander to read, no beacon path, and no `deliverable=` in meta, so the report's destination gets recomputed whenever the lander happens to run instead of being fixed at scaffold time. `cerebro-charter-review`, `env-error-monitor-tick` and `failed-qe-triage-kyle-batch` are what that costs — all three begin at `# Objective` with no frontmatter at all, and all three sat unlandable for weeks.

Then fill the sections in place:

- **`# Objective`** — one bounded sentence.
- **`# Context`** — fill by the vault **retrieval rule**; name every note it rests on. Honor `Confidential/` strict mode.
- **`# Write scope`** — the exact files/areas the X-Man may create or edit (e.g. "the vault under `02 Areas/development/items/`"). The launch prompt's guardrail confines writes to this. **Do not grant `00 Inbox/`** as a place to file the report: the report lands there by itself (see `# Deliverable` below), and a brief that grants the write while the launch prompt forbids it hands the agent two contradictory contracts. Grant `00 Inbox/` only when the *task itself* is to write some other Inbox file — a worklist, a ratify list.
- **`# Approved outward writes`** — **`none`** by default. If Kyle approved a specific outward batch (e.g. "unassign these 42 Jira tickets: …"), record it verbatim and exhaustively — the X-Man executes **only** what's listed here; anything else it must stop and ask.
- **`# Definition of done`** — a checkable list.
- **`# Landing`** — how the work becomes real. **Required on any brief that changes code.** Two shapes, and picking the wrong one is the failure below:
  - **`commit and push to <branch>`** — when Kyle named the change he wants made. Say the branch, and that the pre-push hook is the test gate. Merging stays Kyle's; posting to Jira/Bitbucket/Slack stays Kyle's.
  - **`leave uncommitted for review`** — when the deliverable is a *proposal*: an assessment, an options analysis, a recommendation, or anything touching design, scope, or outward comms.

  ⚠️ **The default is NOT "leave it for Kyle."** When Kyle has asked for a specific change to a specific PR or file, a dirty worktree is not the work — it leaves him doing the last mile by hand, which is exactly the IC-level loop he is trying to hand off ([[feedback_finishing_and_delegation_edge]]). Landed 2026-07-31 after a cleanup X-Man made every requested change to PR #2640 and stopped, because the brief said "no commit, no push" on a request that had explicitly said *"we need to fix that in this pull request."* The X-Man was correct; the brief was wrong.
- **`# Deliverable`** — leave as `report.md` (the fixed contract). ⚠️ **Do not write a `00 Inbox/…` path here.** The landing path is computed at scaffold time and is already in the brief's `deliverable:` frontmatter; `cb-land` files the report there once its status is terminal. A path you write into this section produces **two Inbox files for one finding**, and if you happen to write the reserved one, the landing refuses rather than overwrite it — so the finding does not land at all.

### ⏰ Date-stamped filenames — put the LOCAL-date rule IN THE BRIEF

This no longer applies to the **report's own landing path** — `cb_local_date()` (`scripts/cerebro/lib/land.sh`) resolves that one, and `cb-brief` stamps it in before the agent runs. It still applies to every other date the brief hands the agent.

**Any brief whose deliverable carries a date prefix must tell the X-Man to resolve the date itself:**

> Resolve today's date with `TZ=America/Denver date +%F` and use that. **Do NOT use the system
> date** — the server clock is UTC and rolls to the next calendar day during Kyle's evening.

The X-Man cannot infer this. It sees a UTC clock, `date +%F` gives it tomorrow, and it writes a file
Kyle's vault will file under the wrong day. **Measured 2026-08-05 22:2x MT: two of the evening's
X-Men — `asd-mirror-diagnose-4` and `gemini-sync-eight` — both wrote `00 Inbox/2026-08-06-*.md` with
`date: 2026-08-06` in the frontmatter, while LOCAL was still 08-05.** Both briefs were hand-written
here and neither carried the rule; the fault is the brief's, not the agent's.

The `night-shift` skill has carried this instruction since its own LOCAL-date incident
(`SKILL.md:11`, *"you fire ~12:17 AM MT; the UTC/system date may already be tomorrow"*) — the ops and
research lanes never inherited it. This is that gap closed. It bites hardest **after ~18:00 MT**,
which is exactly when the fleet does its unattended work.

Same rule for any `<LOCAL>` token you write into a brief (worklists, reaped-sessions logs, per-day
report names) — spell out the `TZ=America/Denver` resolution rather than writing the date yourself,
so a brief written at 17:00 is still correct when the X-Man runs it at 23:00.

### O4. Spawn

```bash
scripts/cerebro/cb-start --ops <slug> [--target <project>] [--scratch]
```

Default workdir is the **vault** (vault edits + Inbox reporting). `--target <project>` for a repo-touching ops task (resolves the registry checkout); `--scratch` for a disposable pure-ops dir. Launches window `<slug>` in the `cb` session with `--remote-control` and your brief baked in.

### O5. Return immediately

Report the slug and that the ops X-Man is running — nothing more. **Fire-and-forget.** The board/watcher surfaces `ready-for-review` when `report.md` lands, or a `blocked` gate (e.g. awaiting your approval for an outward write). You do not have to fold the result back: `cb-land` files the report at its computed path and `/eod`'s distill pass integrates the prose. `/ingest` is for the residue those two will not take — a `People/` finding, a confidential report, a decline.

## Guardrail

⚠️ **Read this against the ticket-dispatch rule at the top, which it does not override.** The paragraph below binds the **research lane** and is correct for it. It is not a reason to route a ticket to research: the way to let an X-Man change code is to pick the **code** lane, not to loosen this. Nothing here was weakened on 2026-08-10 — the lane default moved, the research contract did not.

Research X-Men are **read-only everywhere** — the launch prompt instructs the X-Man that the ONLY file it may write is its own `report.md`: never modify code, never commit/push, and **never create or edit any vault file** (`03 Resources/`, a wiki, a project overview — anywhere), even when the brief's Definition of Done says a finding "lands" in the vault. That landing happens *after* the X-Man finishes and is not its work — `cb-land` files the report at its computed path, and the distill pass integrates the prose; the X-Man puts the full finished content in `report.md` and stops. This skill does not enforce that separately, but never write a brief that asks the X-Man to change anything or to write the destination file itself. _(2026-07-19: hardened after a research X-Man wrote a `03 Resources/technical/` page directly, reading "read-only" as code-scoped.)_

Code tasks are **supervise-only**: the conductor owns its run artifacts and its gates. **But PR CREATION IS NOT A GATE** — `.claude/memory/feedback_pr_creation_is_not_a_blocker.md`: *"agents open PRs; only the MERGE is Kyle's."* A conductor that pauses to ask whether to open the PR is asking a question the rules already answer, and the `# Landing` line in C4 exists to stop that question forming. This skill's writes stop at the dev item + wiki In-flight line (vault), context.md (worktree), and the **claim→In Progress transition + assign-to-Kyle** in C2b. Never merge, never push, and never make any other Jira transition (validation, ship, close) from here — those stay the conductor's / Kyle's call.

Ops tasks are **supervise-only** too: the launch prompt confines the X-Man's writes to the brief's declared scope and forbids any outward write (Jira/Slack/PR/email) beyond what `# Approved outward writes` records. Never write a brief that grants a broad or open-ended outward-write mandate — the approval must name a specific batch, or be `none`.

**`git commit`/`push` is governed by `# Landing`, not by a blanket ban** (2026-07-31). A push to a feature branch is not an outward write in the sense this guardrail protects — it updates work Kyle already asked for, behind a pre-push hook that runs the full suite. What stays categorically off-limits regardless of `# Landing`: **merging a PR**, and **posting to Jira, Bitbucket, Slack or email**. Those are Kyle's, always.

## Jira status lifecycle (Cerebro-owned transitions)

Two Jira status transitions ride the code lifecycle so the ticket board mirrors fleet reality (Kyle, 2026-07-18). Both are **coordinator-side model actions via the Atlassian MCP** — `cb-pr-check` and the conductor scripts are Bitbucket-only bash and can't touch Jira, so the coordinator owns these (or the conductor does the ship one at ship time; if it did, the coordinator just verifies).

1. **On claim/dispatch → In Progress + assign to Kyle** — see **C2b** above (mandatory, self-verified; assignment added 2026-07-21).
2. **On PR create → PR Submitted** — when a PR is opened for the ticket (you run `scripts/cerebro/cb-pr-check <slug>`, or a conductor's ship phase created it), transition the item's `jira:` key to **PR Submitted** (transition `to PR Submitted`, id `31` from In Progress — verify per-workflow). **Skip** if already PR Submitted or later (Pending Deploy / In Validation / Done).
   - **Bug-type gate:** the PR-Submitted transition on a **Bug** is validator-gated on two fields — set them first via `editJiraIssue` or it 400s:
     - `customfield_10006` **Change risk** — `{"value": "Low"}` default for a mechanical bug-push fix (allowed: Low / High / Critical; escalate only if the diff warrants).
     - `customfield_10025` **Story Points** — required + must match `0.25|0.5|1.0|2.0|3.0|5.0|8.0|13.0`; a small fix is `1`. Prefer the conductor's own sizing if it set one; these are defaults Kyle/the team can adjust.
   - Stories/tasks have no such gate — the transition goes straight through.
   - Leave **assignee** alone. This + the merge stays Kyle's.

_(Tooling gap to close: `cb-pr-check` can't do the transition itself — it has no Jira credentials/adapter. A proper fix would emit a post-create signal a Jira-capable step consumes. Until then the coordinator does it. Surfaced 2026-07-18.)_
