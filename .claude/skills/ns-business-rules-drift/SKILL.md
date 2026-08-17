---
name: ns-business-rules-drift
description: Business-rules-layer drift vs Confluence — re-fetch each tracked page's lastModified by id, flag drift in index.md/carriers, detect new rule pages. Night-shift process P14, runnable solo. Triggers — "/ns-business-rules-drift".
allowed-tools: Read, Write, Edit, Glob, Grep, Bash
---

# ns-business-rules-drift

Business-rules-layer drift check against Confluence (the P2 discipline applied to the annuity business-rules layer at `03 Resources/technical/annuity-business-rules/`). Night-shift process **P14**; also runnable on demand.

Loads the Atlassian/Confluence MCP via ToolSearch at run time (`select:mcp__plugin_atlassian_atlassian__getConfluencePage`, and the CQL search tool for new-page detection); Confluence cloudId is `6f606d1b-47d6-4734-8f6f-33012126c7e7`.

## Invocation
Invoked by the `night-shift-fanout` workflow as `/ns-business-rules-drift for LOCAL=<date>`. Runnable solo: `/ns-business-rules-drift` (defaults LOCAL to today; solo = the on-demand behavior in "Solo run" below).

**Cadence gating:** the Sunday-only gate is enforced by the WORKFLOW — `night-shift-fanout` dispatches this process ONLY when `dow === 7` (Sunday). The skill itself carries no day gate and runs whenever invoked, so a solo `/ns-business-rules-drift` works on any day.

## Artifact contract (PRIMARY OUTPUT)
Resolve `LOCAL` (from the invocation, else `TZ=America/Denver date +%Y-%m-%d`). Write `00 Inbox/<LOCAL>-ns/P14.md` with frontmatter `process: P14`, `status: complete|failed`, and a body = the report-section text (drift findings + new-page candidates) — this artifact is the source of truth. Do NOT commit/push; honor Confidential/ strict mode. All drift edits/flags into the layer stay UNCOMMITTED.

**DIGEST-EXEMPT (2026-07-02): P14 does NOT populate `needs_kyle:`.** Its role is to keep the `/autofix` correctness-gate's business-rules layer fresh (a machine dependency), not to occupy Kyle's decision surface — Kyle demoted it from the morning digest while keeping it running for the gate. Its findings (drift flags, new-page recommend-adds, detection-rule gaps) live in the report body + the FINALIZE per-process roll-up ONLY, never the Needs-Kyle digest. Leave `needs_kyle:` empty/absent even when it finds drift; the body carries the record.

## Procedure

PROCESS 14 — Business-rules-layer drift (the P2 discipline applied to the annuity business-rules layer at `03 Resources/technical/annuity-business-rules/`). Read-only on Confluence; the only writes are drift FLAGS into the layer + the report.
- For each page row in `03 Resources/technical/annuity-business-rules/_sources.md` (the `id` + `lastModified` columns), re-fetch the page metadata `lastModified` **by id** (`getConfluencePage`, cloudId `6f606d1b-47d6-4734-8f6f-33012126c7e7`; NEVER full-text). Unchanged → skip.
- Changed → **flag the affected `index.md` / `carriers/<carrier>.md` entries as drifted** in the report (and re-digest mechanically ONLY if the change is unambiguous; otherwise surface for Kyle — rules are high-stakes, no silent rewrite). Note: the per-carrier XML/Drive rows are **pointers, not API-trackable** — track at the Data-Catalog *page* level (3844046851); flag XML-attachment changes as "manual re-check" since the blobs aren't reliably addressable.
- **New-page detection:** re-run the id/title-targeted queries on the tracked spaces (PPM/CAR/EJ; `title ~ "business rule"|"product rule"|"PPfA"|"eApp Fields"`) to catch new rule pages. **ALSO run a date sweep — `created >= <last_synced>` (CQL) on the tracked spaces — as the reliable net: the title-keyword query has missed in-scope pages 3× (6/24, 6/28, and the 7/5 "FIA on Porch"/"FIA Resources" pages all matched no keyword and were caught only by the created-since sweep). Run BOTH; the date sweep is authoritative for coverage.** Surface candidates under "business-rules — new pages," do NOT auto-add.
- All edits/flags stay UNCOMMITTED. Fold a one-line drift summary into the report.

## Solo run
Runs the drift check on any day (no Sunday gate when invoked directly — the gate lives in the workflow). LOCAL defaults to today (`TZ=America/Denver date +%Y-%m-%d`). No diagnosis cache is involved (P14 consumes none). Still write the `00 Inbox/<LOCAL>-ns/P14.md` artifact; all drift flags into the layer stay uncommitted.
