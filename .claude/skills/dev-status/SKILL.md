---
name: dev-status
description: Snapshot of the development area — active items with last-synced age, queued depth, drafting items with stale flags, recently archived, plus open questions across active items. Pure read; does not modify anything. Triggered by "/dev-status" or "what's the dev area look like?".
allowed-tools: Read, Glob, Grep, Bash
---

# Dev Status Skill

A briefing of the development area's current state. Use when context-switching back to dev work, or any time Kyle wants the snapshot without `/morning`'s broader scope.

This is the dev-area equivalent of `/morning` — but standalone, on-demand, and pure read. It does not write to any vault file.

## Invocation

- `/dev-status` — full snapshot.
- `/dev-status active` — only the Active section + open questions.
- `/dev-status drafts` — only the Drafting section, focusing on stale ones.

## What this skill does

1. Reads `02 Areas/development/backlog.md` to get the lifecycle rows.
2. Reads frontmatter from each item file in `00 Inbox/` to compute ages and pull supplemental fields.
3. Reads the `Open questions` section of each active item.
4. Reads `02 Areas/development/archive/items/` to find items archived in the last 7 days.
5. Renders a compact snapshot.

## What this skill does NOT do

- Does not modify any file.
- Does not commit, push, or sync.
- Does not contact Jira / Atlassian / Confluence (use `jira-backlog.md` for that — it's already a local view).
- Does not read `Confidential/`. If `00 Inbox/` references confidential items, list slug + status only without reading the body.

## Execution steps

### Step 1: Read backlog.md sections

Parse `02 Areas/development/backlog.md`. The headings `## Drafting`, `## Active`, `## Queued`, `## Recently done` define the buckets. For each row, extract:

- The slug (from the wiki link `[[items/<slug>|<slug>]]`).
- The inline summary text.
- The trailing `(last touched: YYYY-MM-DD)` stamp where present.

Don't trust the backlog as the only source — also list `00 Inbox/*.md` directly to catch items that exist on disk but aren't in the backlog (a gap worth surfacing).

### Step 2: Pull frontmatter for each item

For each item file, read frontmatter:

- `slug`, `status`, `created`, `related_project`
- Active-only: `branch`, `worktree_path`, `repo`, `last_synced`

Skip files whose path is in `Confidential/` — note them as "(N confidential, not enumerated)" only.

### Step 3: Compute ages

Today's date in YYYY-MM-DD. For each:

- **Drafting** — age = today − `last touched` from backlog row (fallback to file mtime).
- **Active** — age = today − `last_synced` from frontmatter.
- **Recently done** — date in the archive row (e.g., `(2026-04-30)`).

### Step 4: Pull open questions for active items

For each active item, read its file's `## Open questions` section. If non-empty, capture the bullets verbatim (truncate each to ~80 chars).

### Step 5: Render the snapshot

```
Dev status — 2026-05-02

🟢 Active (4)
- ppfa-extractor — 5d since sync — wave 0, 3/7 tasks done
- annuitant-validation-EJA-2110 — 4d since sync — Sprint 26 BLOCKER, AC reconciliation pending
- pav-validation-EJA-2727 — 4d since sync — worktree spawned, awaiting Remote pickup
- appsub-npn-flow-verification — 2d since sync — audit in progress, Phase 1 sanity

❓ Open questions (3 across active items)
- annuitant-validation-EJA-2110: AC numbering reconciliation between vault brief and remote spec dir
- pav-validation-EJA-2727: how to coordinate sibling-branch work with fe/pav-EJA-2705
- appsub-npn-flow-verification: confirm K1 scoping covers both joint and single audit subjects

🟡 Queued (3)
- rider-rate — needs triage before resume
- delete-ppfa-product-versions — spec complete on remote
- ppfa-product-version-details — enable/disable jurisdictions

📝 Drafting (13 — 2 stale >5d)
Stale:
- ppfa-cache-key-verify — 3d (just inside threshold)
- portfolio-alignment-validation-EJA-2705 — 4d
Fresh:
- 11 others, all <3d
(Run `/dev-status drafts` for the full list.)

✅ Recently done (2 in last 7 days)
- 103-invest-product-empty (2d ago) — Clone gap regression test shipped
- income-rider-EJA-2299 (3d ago) — merged 2026-04-29

⚠️ Anomalies
- 0 items in items/ that aren't in backlog
- 0 confidential items
```

**Section rules:**

- **🟢 Active** — show all. No cap; show count only.
- **❓ Open questions** — only if any active items have non-empty Open questions. Cap at 8 lines total; "(+N more — see item file)" if exceeded.
- **🟡 Queued** — show all up to 8; "(+N more)" beyond.
- **📝 Drafting** — split into Stale (>5d) and Fresh (≤5d). Show stale list inline; summarize fresh as count. Threshold matches `/morning`'s drift-watch.
- **✅ Recently done** — items archived in the last 7 days, oldest last.
- **⚠️ Anomalies** — only show non-zero counts:
  - Items on disk not referenced in backlog
  - Items in backlog whose file is missing
  - Active items with `last_synced` empty or > 7d
  - Confidential items (count only, no names)

### Step 6: Mode handling

- `/dev-status active` — render only Active and Open questions sections.
- `/dev-status drafts` — render Drafting in full (every entry, with stale flags but not summarized).

## Output format

The full block, in chat. No file writes. No questions afterward — Kyle reads it and decides what to do next.

Keep it scan-friendly. Indent levels matter; emoji headings let Kyle visually grep the section he wants.

## Edge cases

- **backlog.md missing or unparseable**: fall back to scanning items/ directly, ordering by status frontmatter; note "backlog.md unavailable, listing from items/".
- **Item file missing referenced in backlog**: surface in Anomalies with file path.
- **Item with `status:` value other than drafting/queued/active/done**: list under Anomalies.
- **`last_synced` malformed or missing on an active item**: show as "?d since sync" and add to Anomalies.
- **Empty backlog (no items)**: report "Dev area is empty." and exit cleanly.

## Integration

- Standalone. Not invoked from `/morning` (which has its own narrower drift watch).
- Pairs with manual sync flow (`/morning` doesn't dive this deep into dev).
- When `/dev-switch <slug>` is built later, it can reuse the per-item read logic.
