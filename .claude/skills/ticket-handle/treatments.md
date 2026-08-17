# ticket-handle — treatment modules

One treatment per classified type (see [`classification.md`](classification.md)). Each produces a **terminal artifact** — a vault draft. None builds code or writes to Jira.

---

## epic — recurse + split

1. **Fetch the epic + all children** via `ultron:jira-context` (epic-with-children). Traverse both `parent = <EPIC>` AND the epic's `issuelinks` to related epics (e.g. EJA-3599 "Change Order Batch 1" *relates to* EJA-3602 "EDJ Forms Change Order 6/26" — the form stories hang off 3602). Also sweep the created-window/range as a backstop when child-linkage is loose. Dedupe by key. **State confidence if linkage is ambiguous** (stories not formally childed) — don't overstate the tree.
2. **Classify each child** per `classification.md`.
3. **Split:**
   - **code-bound children** (bug-code, code story) → run the story/bug treatment → each becomes a **scoped dev-item** (conductor-ready).
   - **non-code children** (form add/remove/replace/re-version, config, product) → collect into the **change-order PO-plan**.
4. **Roll up** into the epic decomposition draft (see Output): a **Code track** (conductor-ready scoped items) + a **Non-code track** (the PO-ready batch plan) + a one-line routing summary (N → conductor / M → PO / K → owners).

Never build; never create Jira children. The split IS the deliverable — code to the executor, forms/config to the PO.

---

## story — scope-to-dev-item

Produce a scoped dev-item **draft** (not a promoted item):
- **What it touches** — files/subsystems from a read-only trace.
- **Size** — S / M / L.
- **Mechanical vs code** — form-tool/config vs real code.
- **Dependencies** + the acceptance criteria restated.

Home: a `### <KEY>` block in the epic decomposition doc (when reached via epic recursion), or `00 Inbox/<slug>.md` at `status: drafting` when handled standalone. Conductor-ready = seeds `/work {feature}` later. **No spawn** — Kyle promotes.

---

## change-order — PO-ready batch plan

For a forms change-order batch, group children by action and make it *actionable*, not descriptive:
- Per form: `key | form id/name | action (added/removed/replaced/re-versioned) | carrier | status | owner`.
- Totals: forms touched, **mechanical-form-tool vs code** split, current **ownership gap** (unassigned / Scoping Backlog), and what it's **waiting on** (PO refinement).

This is the terminal artifact — form-tool/config is **not built** by autofix/conductor (it's PO/refinement work). Home: the epic decomposition doc, or `00 Inbox/<LOCAL>-ticket-handle-<KEY>.md` standalone.

---

## mirror-resolution (bug-path helper)

Resolve whether a code-bound bug already has an EJA/ARCH mirror to claim + spawn on, or needs one drafted. Order:

1. **If `<KEY>` is itself an EJA/ARCH** → `self` (no mirror needed; claim `<KEY>` directly).
2. **If `<KEY>` is an ASD** → find its mirror:
   a. Fetch `<KEY>`'s issuelinks via `ultron:jira-context` (or `getJiraIssue` expand=issuelinks). Collect any linked EJA/ARCH (`Relates`, `Mirror`, `Cloners`).
   b. Cross-check the vault: `grep -rl "<KEY>" "00 Inbox/"` + the diagnosis cache row; check the RCA doc frontmatter/body for a stated mirror.
   c. **Mirror found** → `mirror-exists`: record `{ mirror_key, status, assignee }`. Apply the **mirror-ownership gate** (`03 Resources/reference/diagnosis-procedure.md`): if the mirror is assigned + in active sprint flow, it is **owned elsewhere** → STOP, report owner, do NOT spawn.
   d. **No mirror** (RCA/cache says "no EJA/ARCH mirror — genuinely untouched", or the fetch finds none) → `no-mirror: draft-required`.
3. Emit the resolved state (`self` / `mirror-exists` / `no-mirror: draft-required`) + a one-line rationale.

---

## bug-code — RCA-lift → mirror-resolve → spawn (Phase 2)

Drive a code-fixable bug from classification to a running conductor. Never writes code (the conductor does); the only autonomous Jira write is autofix's claim on an **existing** ticket.

### 1. RCA-lift
- **Reuse if present:** if `00 Inbox/<LOCAL>-rca-<KEY>.md` (or a recent dated `*-rca-<KEY>.md`) exists with `verdict: SPAWN-READY`, use it as the spec — do NOT re-run RCA. **Re-baseline first:** the RCA may be older than live `main`; before it becomes the spawn spec, re-read its cited `file:line` anchors on current `main` and confirm they still hold (Kyle's re-baseline rule — a stale spec over-trusts the conductor).
- **Else lift confidence:** run `/rca <KEY>` (deep single-ticket) to produce the RCA. If it comes back not-spawn-ready (autonomy <4, or confidence < high, or verdict names a product/data/config gate) → route to the **bug-gapped / product-AC** handoff with the RCA's stated gate; do NOT spawn.

### 2. Mirror-resolve
Run **mirror-resolution** (above). Branch:
- **`self`** (KEY is EJA/ARCH) → claim `<KEY>` (autofix claim path), go to Spawn.
- **`mirror-exists`** → apply the mirror-ownership gate. Owned + active → STOP, report owner (track, don't spawn). Else claim the mirror, go to Spawn.
- **`no-mirror: draft-required`** → **draft a fresh EJA mirror** (do NOT auto-create):
  - summary = the ASD summary; description = the RCA's root-cause + `file:line` + repro + a "mirror of `<ASD-KEY>` — spawn-ready, no prior mirror" line. **Flag any product-decided behavior change explicitly** (e.g. a fix that alters UX/semantics, not just a defect) so a reviewer/PO/QA sees it was intentional. Priority mirrors the ASD (note any Jira-vs-approved discrepancy). Links `Relates → <ASD-KEY>`; assignee unset.
  - Write the draft to the output doc and surface it. **Gate:** the spawn cannot proceed until the EJA exists. On Kyle's per-item approval → `createJiraIssue` + `createIssueLink (Relates)`, claim the new EJA, go to Spawn. Absent approval → `outcome: mirror-draft-pending` (staged; land a Needs-Kyle Inbox item per `.claude/skills/morning/needs-kyle-items.md`, `id:` = the lowercased ASD key).

### 3. Spawn
Once a claimable EJA/ARCH exists, run **spawn-execution** (below) with the re-baselined RCA as the piped spec. Emit `outcome: spawned` with slug, branch, worktree path, tmux session, and claimed key. Never build code; never merge; the conductor self-verifies and stops at the PR.

---

## spawn-execution (bug-path helper)

Reuse the development-README spawn pattern (`02 Areas/development/README.md` → Going active) + the autofix→conductor flow. Do NOT invent a new mechanism.

1. **Dev-item:** create `00 Inbox/<slug>.md` at `status: active` (slug = branch name, stable). Frontmatter: `domain` (from the RCA), `branch: fe/<slug>`, `worktree_path`, `repo`, `related_project`, `last_synced: <LOCAL>`. Body = the RCA (root cause + `file:line` + scoped fix + verification).
2. **Worktree:** create the git worktree at `~/code/worktrees/<slug>` off current `main`.
3. **Pipe the spec:** write the RCA to `<worktree>/.ai/specs/<slug>/vault-context.md`.
4. **In-flight:** add a one-line entry to the domain `wiki.md` **In flight**, linking the dev item.
5. **Spawn the conductor:** `tmux new-session -d -s <slug>` in the worktree, then start Remote-Claude `/work <EJA-KEY>` (work-conductor, bug type) — self-verifying, stops at the PR. Emit the PR-create URL for Kyle (never browser-create).
6. **Verify it landed:** confirm the tmux session is alive (`tmux has-session -t <slug>`) and `/work` is actually running (capture-pane) before reporting `spawned` — don't report an unverified spawn.
7. Report: slug · branch · worktree · tmux session · claimed key.

---

## bug-code / other (legacy stub note)

The bug path above supersedes the Phase-1 stub. The `/rca`→`/autofix`→`work-conductor` spine it reuses is the same flow used for EJA-3427/3538/ARCH-157.

## bug-gapped / product-AC / owner-handoff (Phase 1 stubs)

Emit the classified type + intended treatment to the output doc with `outcome: stub-pending`; surface for manual routing. Do not attempt the module yet:
- **bug-gapped** → "owner-handoff draft (data/config owner) — pending Phase 3".
- **product-AC** → "product-decision brief — pending Phase 3".

## non-actionable

Emit a **close/verify recommendation**: if already-fixed/merged → "verify deploy (`/deploy-verify`) + close, do not re-fix"; if duplicate/WAD → note which and recommend close.

---

## Output contract

Write `00 Inbox/<LOCAL>-ticket-handle-<KEY>.md`:

```markdown
---
ticket: <KEY>
classified_type: <type>
date: <LOCAL>
outcome: <handled | decomposed | spawned | mirror-draft-pending | already-fixed | stub-pending | needs-classification>
---
# ticket-handle — <KEY> (<classified_type>)
```

- **For an EPIC** (`outcome: decomposed`):
  - `## Code track` — per-child scoped dev-item blocks (conductor-ready).
  - `## Non-code track` — the PO-ready batch plan (the change-order table + totals).
  - `## Routing summary` — one line: `N → conductor · M → PO refinement · K → owners`.
- **For a bug-code ticket:**
  - `outcome: spawned` — record the claimed EJA/ARCH key, slug, branch, worktree path, tmux session, and the PR-create URL once the conductor reaches it.
  - `outcome: mirror-draft-pending` — the RCA summary + the **drafted EJA mirror** (summary / description / priority / `Relates → <ASD>`) awaiting Kyle's create, + the staged spawn plan. Register a Needs-Kyle line.
- **For a single ticket (other)** — the one treatment's artifact (scoped dev-item / PO-plan / stub note / close rec).

Link every Jira key (`https://porchsoftware.atlassian.net/browse/<KEY>`). On-demand: also return the headline inline. **Never commit/push** (rides Kyle's `/push`); nothing routed outward (Kyle routes).
