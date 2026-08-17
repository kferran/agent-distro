---
name: dev-items-ratify
description: Batch-ratify pass over stale dev-item drafts — bulk-checks each drafting item's Jira ticket status and drafts an archive/keep recommendation per item into one worklist Kyle approves in bulk. Surface-only; nothing is archived without ratification. Runnable solo or invoked nightly by /eod (Step 6.10; re-homed off ns-goal-loop 2026-07-07). Triggers — "/dev-items-ratify", "ratify the dev drafts", "clean up stale drafts".
allowed-tools: Read, Write, Glob, Grep, Bash, ToolSearch
---

# dev-items-ratify

The dev-item counterpart to `aging-inbox-ratify`: drafts accumulate because capture is cheap and expiry is manual (2026-07-07 baseline: 64 drafts piled up; 46 had tickets already Done/Closed). This pass bulk-checks every `status: drafting` item against its Jira ticket and produces ONE ratify worklist with a recommendation per item. **Surface-only — nothing moves until Kyle ratifies.**

## Invocation

- Solo: `/dev-items-ratify` (LOCAL defaults to today, `TZ=America/Denver date +%Y-%m-%d`).
- From `/eod`: Step 6.10 invokes it nightly (Mon–Fri) with LOCAL. (Re-homed 2026-07-07; previously ns-goal-loop P13c on Sundays.)

## Procedure

1. **Gather.** Every `00 Inbox/*.md` with `status: drafting`. Extract per item: filename, `jira:` frontmatter (fall back to an `EJA-\d+`/`ASD-\d+` key in the filename), `created:`, last-touched (`git log -1 --format=%ad --date=short -- <file>`).
2. **Bulk Jira pull** (Atlassian MCP via ToolSearch — `searchJiraIssuesUsingJql`, cloudId `porchsoftware.atlassian.net` (site hostname — accepted by the tool; if rejected, resolve via `getAccessibleAtlassianResources`)): one `key in (...)` query over all extracted keys, fields `status, resolution, updated` only. Expect the result to overflow to a file — parse it there (known gotcha). **Graceful degradation:** if the Atlassian MCP is unavailable/unauthorized, SKIP the Jira classification, note "Jira check skipped (mcp-auth)" in the output, and still emit the age-based section (step 3b).
3. **Classify:**
   - (a) **Ticket resolved** (every key on the item is Done/Closed) → recommend **archive**, reason `ticket resolved (<KEY> <Status>) — draft never activated`. An item with a mixed key set (any key still open) → keep.
   - (b) **No key + last-touched >30d** → list under "no-ticket, aging — Kyle review" with the item's Goal line quoted (these are often Kyle's parked ideas — recommendation is a review, not an archive).
   - (c) Everything else → keep (listed as a count, not itemized).
4. **Write the worklist** to `00 Inbox/<LOCAL>-dev-items-ratify.md` (frontmatter `type: ratify-worklist`, `status: awaiting-ratify`): checkbox per archive-rec item, the no-key review section, the keep count. Skip writing entirely if there are zero recommendations (note "dev drafts: clean" instead).
5. **On Kyle's ratification** (a later interactive session, not this pass): apply approved moves — `status: archived` + `archived: <date>` + `archived_reason:` in frontmatter, `git mv` to `02 Areas/development/archive/items/`, tick the worklist, flip its `status:` when fully dispositioned.

## Bounds

- NEVER auto-archive — the worklist is the entire output of an unattended run.
- Read-only on Jira (search only; no comments, no transitions, no edits).
- Don't touch items in `active|queued|paused` states; don't read `Confidential/`.
- Surfacing is OWNED by the caller: `/eod` links a written worklist from the day's End-of-day section (don't also add pointers here — doubled lines); a solo run needs no pointer.
