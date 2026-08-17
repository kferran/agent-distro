---
name: ns-pushed-fixes
description: Weekly "pushed fixes" report — tickets (EJA/ASD/ARCH) whose fixes landed on Ultron main this week, from git merge/commit history. Night-shift process PF (Friday-gated), runnable solo. Triggers — "/ns-pushed-fixes".
allowed-tools: Read, Write, Edit, Glob, Grep, Bash
---

# ns-pushed-fixes

Weekly delivery-from-the-code-side report: **which tickets got a fix pushed to Ultron `main` this week**, derived from git history (not Jira status). Night-shift process **PF**; also runnable on demand.

Distinct from `ns-weekly-delivery` (PW): PW is **Jira-completion** based (status → Done/Closed *last* week, exec-facing rebuttal for the Monday EDJ sync). PF is **git-push** based (code actually merged to `main` *this* week) — Kyle's internal week-close view of what shipped in code. The two are siblings, not duplicates: a fix can be pushed (PF) before its ticket is marked Done (PW), or vice-versa.

Signal source decided 2026-07-09 (Kyle): **git merge history** (truest "pushed" signal). Cadence: **weekly, Friday** — delivered by the Saturday ~00:17 MT run (`dow===6`), windowed to the current work week.

## Invocation
Invoked by the `night-shift-fanout` workflow as `/ns-pushed-fixes for LOCAL=<date>` (dispatched only when `dow===6`). Runnable solo: `/ns-pushed-fixes` (defaults LOCAL to today; computes the current-week window relative to today).

**Gating:** the Friday-only gate is the WORKFLOW's (`night-shift-fanout` dispatches PF only when `dow === 6`). The skill itself runs whenever invoked — a solo run works any day and reports the current week to date. **No MCP dependency** — pure git + local files, so it dispatches regardless of the Atlassian probe.

## Window
Resolve `LOCAL` (from the invocation, else `TZ=America/Denver date +%Y-%m-%d`). The week window is **this week's Monday 00:00 → LOCAL end-of-day**:
```bash
MON=$(date -d "$LOCAL -$(( ($(date -d "$LOCAL" +%u) - 1) )) days" +%Y-%m-%d)   # Monday of LOCAL's week
```
On the intended Friday-night run (LOCAL = Saturday, `dow===6`) this captures Mon→Fri pushes. A solo run mid-week captures Mon→today.

## Data source
Ultron main checkout: `/home/kyle/code/worktrees/main` (canonical `main`; see `.claude/memory/feedback_main_worktree.md`). Read-only:
```bash
REPO=/home/kyle/code/worktrees/main
git -C "$REPO" fetch origin main --quiet          # refresh ref only; do NOT touch the working tree / checkout
git -C "$REPO" log origin/main --since="$MON 00:00" --until="$LOCAL 23:59" \
    --pretty=format:'%h%x09%ad%x09%s' --date=short
```
- Scan **all commits on `origin/main`** in-window (not just `--merges`) — the repo's merge style (squash vs merge-commit) varies, and squash-merges carry the ticket key in the squashed subject, not a merge commit. Include merge-commit subjects too (PR titles usually carry the key).
- Extract ticket keys with `(EJA|ASD|ARCH)-\d+` (case-insensitive) from each commit subject. A commit may carry >1 key; count each. Dedupe to a per-ticket rollup: **#commits, first push date, last push date, representative subject**.
- Never mutate the repo — `fetch` refreshes the remote ref only; no `checkout`/`pull`/`reset`. If `$REPO` is missing or `fetch` fails (offline), fall back to local `main` and note the ref used + staleness in the report.

## Artifact contract (PRIMARY OUTPUT)
Keeps its **own-doc contract** (like PW): write the deliverable `00 Inbox/<LOCAL>-pushed-fixes-week.md`.
ADDITIONALLY write `00 Inbox/<LOCAL>-ns/PF.md` — frontmatter `process: PF`, `status: complete|failed`, optional `needs_kyle:` — body = headline totals + a pointer to `[[00 Inbox/<LOCAL>-pushed-fixes-week]]` — so the orchestrator's artifact glob sees it.

Do NOT commit/push. No MCP, no external writes.

## Report shape
`00 Inbox/<LOCAL>-pushed-fixes-week.md`, frontmatter (`date: <LOCAL>`, `type: pushed-fixes-week`, `window: <MON>/<LOCAL>`, `ref: origin/main`):
- **Headline:** _N tickets had fixes pushed to main this week (M commits), <MON>→<LOCAL>._ Split by project: EJA / ASD / ARCH counts.
- **Table**, grouped by project then most-recent push: `Ticket | #commits | first→last push | representative subject`. Link every key (`https://porchsoftware.atlassian.net/browse/<KEY>`).
- **Caveat line:** commits on `main` in-window with **no** ticket key (count only) — infra/chore/refactor pushes the report doesn't attribute to a ticket. State the ref used and any fetch/staleness fallback.
- Keep it factual and scannable — this is Kyle's internal delivery view, not exec-facing (that's PW). No Jira calls; "pushed" ≠ "done" (a pushed fix may still be in QA/deploy) — say so once.

## Solo run
Runs any day; LOCAL defaults to today. Compute the Monday-of-this-week window relative to today exactly as above; write both the report doc and the `-ns/PF.md` stub. Read-only git; nothing committed or pushed.

## Notes
- **Why git, not Jira dev-panel:** Jira PR/dev data isn't cleanly queryable via the Atlassian MCP; `origin/main` history is the authoritative, directly-accessible record of what pushed. (Decided 2026-07-09.)
- **ARCH included** alongside EJA/ASD — see `.claude/memory/reference_arch_jira_project.md`.
- To retime (e.g. move to Monday to pair with PW for the exec sync): change the workflow gate `dow===6` → `dow===1` and this skill's window to the prior week; update the night-shift roster map + ASSEMBLY reconciliation accordingly.
