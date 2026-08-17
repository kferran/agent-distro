---
name: watch-poll
description: Cerebro watch-list poll X-Man (Job B) — poll ONE watch-list signal read-only via the Gmail / Atlassian / Google-Drive MCP, diff against its last-seen state, and append factual deltas to the shared manifest. Never writes to email/Jira/Drive; never takes an outward action; surfaces judgment to Kyle, never acts on it. Triggered by a `watch-poll <signal>` nudge (from cb-watchlist --poll's hourly tick) or "poll the <signal> watch-list signal".
---
<!-- allowed-tools intentionally omitted: this X-Man's core job is Gmail /
     Atlassian / Google-Drive MCP reads, so it needs unrestricted tool access —
     matching the MCP-heavy sibling skills (asd-triage, intake), which also omit
     it. A restrictive allowed-tools list would block the MCP calls. Read-only
     discipline is enforced by the guardrails in the body, not by the tool list. -->

# watch-poll — poll one watch-list signal

The read-only half of Job B. `cb-watchlist` (bash) owns scheduling, rendering, and
the vault write; **this skill owns the MCP reads + the diff**. You are handed one
signal name. Read it, diff it against last-seen, and append the factual deltas to
the shared manifest. That is all — `cb-watchlist --render` (the tick) turns your
manifest deltas into tracker updates and the material-change push.

**Guardrails (non-negotiable, spec §7):**
- **Read-only over email / Jira / Drive.** Never send, reply, label, transition,
  comment, or edit anything. No outward action of any kind.
- **Facts, not judgment.** Append what changed (a status flip, a new deck, a
  delivery-date move). Do NOT append risk calls, "does 7/20 slip?", or reply
  drafts — those are Kyle's. If you form a judgment, say it in your turn back to
  the coordinator; never write it to the manifest or a tracker.
- Never read `Confidential/`.

## Steps

### 1. Load the signal config
The signal name is your argument (e.g. `preprod`, `exec-committee`). Read its block
from `watchlist.md` (repo root):
```bash
sig="<signal>"
scripts/cerebro/cb-watchlist due "$sig" && echo due || echo "not due (poll anyway if asked)"
```
Note the block's `kind`, `email_threads` / `email_from`, `jira`, `gsheet`,
`material_rule` (the controlled vocab you map onto), and `target_tracker`.

Read last-seen state (opaque prior snapshot you wrote last poll):
```bash
scripts/cerebro/cb-watchlist state-get "$sig"
```

### 2. Poll each source-kind, read-only, since last-seen
- **`jira-tickets`** — for each key in `jira:`, fetch the current status via the
  Atlassian MCP. Compare to the last-seen status in state. A change is a delta.
- **`email` / `email-thread`** — search the Gmail MCP for the watched senders
  (`email_from`) / subjects (`email_threads`). A new message since the last-seen
  message id is a delta (a new status deck, an agenda, a cancellation, a bug-list
  update).
- **`gsheet`** — fetch the Drive file's `modifiedTime` via the Google-Drive MCP.
  If it advanced past last-seen, the workbook updated — read the content (relevant
  tabs: Exec Summary, Phase 1 TL Wave 1, Bugs Blocking Testers, Carrier Bugs
  Report, Change Orders) to classify WHAT changed (a delivery-date move, a status
  regression, a new blocking-tester bug) vs. a cosmetic touch.

### 3. Map each delta to the controlled vocab and append
For every real change, choose the `state` from the vocab so `material_rule` can
gate the push mechanically:
- `new` — a newly-appearing item (new blocking bug, new status deck, new ticket).
- `reopened` — a regression / a resolved thing gone un-resolved.
- `slip` — a delivery-date / milestone date moving later.
- `env-down` — an environment reported unavailable.
- `resolved` — an item cleared/closed.
- `cancelled` — a meeting/agenda cancellation.
- `note` — a factual update that is NOT material (routine daily status, cosmetic
  workbook touch). Routine, so it lands in the Log but fires no push.

Append one delta per change. `key` is a stable identifier (Jira key, a short slug
for a deck/thread, e.g. `deck-2026-07-16`); `detail` is a one-line factual summary:
```bash
scripts/cerebro/cb-watchlist append "$sig" ASD-1124 reopened "CIA/MVAII disclosure page reopened by Thomas Rosales"
scripts/cerebro/cb-watchlist append "$sig" tl-story slip     "The EDJ T&L Story: Wave 1 Go/No-Go moved 8/17 → 8/24"
```
Only append MATERIAL transitions and genuinely-new facts — the manifest records
material state changes, not every poll. If nothing changed, append nothing.

### 4. Persist last-seen + mark polled
Write the new snapshot (Jira statuses, last email ids, gsheet modifiedTime) so the
next poll diffs cleanly, then reset the poll clock:
```bash
scripts/cerebro/cb-watchlist state-set "$sig" <<'STATE'
ASD-1124=Reopened
last_email_id=<id>
gsheet_modifiedTime=<iso>
STATE
scripts/cerebro/cb-watchlist mark-polled "$sig"
```

### 5. Report back
Return a one-line factual summary of the deltas to the coordinator (e.g. "preprod:
ASD-1124 reopened, 1 new daily-status email, no date change"). Raise any JUDGMENT
here as a question for Kyle — never as a manifest/tracker write.
