# Log Search

Reference for the log-search step in `/triage` Pattern B (step 4).
Pulls Kusto trace evidence to strengthen the brief Remote-Claude
receives, turning a `ready-for-remote` recommendation into a
`ready-for-remote-with-evidence` recommendation.

Source patterns adapted from `ultron:log-investigation`. Kept here
because `/triage` runs Vault-side and needs its own bounded query set
that doesn't pull in the full investigation skill.

## Scope

This file describes the v1 log-search step only. For deeper investigation
(tracing full request flows, multi-trace correlation, log-keyword search),
defer to `ultron:log-investigation` Remote-side after the dev item is
spawned to a worktree.

## When the step runs

All conditions must hold. Skip silently otherwise.

| Condition | Source |
|---|---|
| Recommended category is `bug` | step 4 of Pattern B |
| Priority is `Blocker`, `High`, or `Medium` | Jira ticket `priority.name` |
| Ticket created within last 7 days | Jira ticket `created` field, compared to today |
| QE rubric did not push to `needs-info` | step 3 of Pattern B; either rubric cleared or only soft items missing |
| App# extractable from description | regex `K[012]-[A-Z0-9]+-A-\d+` or `K[012]-[A-Z0-9]+` |
| URL extractable from description | regex `https?://[^\s]+` |

If any condition fails, skip the step and emit a one-line note in the
Pattern B output: e.g., `Log search skipped — priority Low.` or
`Log search skipped — App# not found in description.`

## Connection setup

Run once per session before the first query:

```
mcp__kusto-mcp__initialize-connection
  cluster_url: "https://ultron-nonprod.centralus.kusto.windows.net"
  database: "validation"
```

If initialization fails, skip the log-search step with note
`Log search skipped — Kusto unavailable.` Do not block triage.

## Environment scoping

Derive the environment per `03 Resources/reference/environment-derivation.md`
(shared source) — Path B (URL hostname → environment). The URL is the
authoritative source: the App# prefix only tells you where the case was
created, not where the user observed the bug. The hostname→environment
table and the URL → App#-prefix → skip fallback chain both live in that
reference.

If URL parsing fails (hostname doesn't match any known pattern), fall
back to App# prefix. If that also fails, skip the log-search step with
note `Log search skipped — environment indeterminate.`

The `porchInstanceId` (K0/K1/K2) carried in the env-derivation table is
what the queries below filter on via `{env_hostname_pattern}`.

## Time window

24 hours centered on ticket creation date (creation − 12h to
creation + 12h). Total span 24h.

## Queries

Three queries per ticket. Each bounded with `| take 20`. Run sequentially.

### Query 1 — Case lookup

Confirm the case exists in the expected environment. Establishes that
log evidence is queryable at all.

```kql
Traces
| where StartTime between (datetime({creation_minus_12h}) .. datetime({creation_plus_12h}))
| where TraceAttributes has "porch.projectCode"
| extend projectCode = tostring(TraceAttributes["porch.projectCode"]),
         server = tostring(TraceAttributes["server.address"])
| where projectCode has "{app_code}"
| where server has "{env_hostname_pattern}"
| project StartTime, projectCode, server, SpanName,
         status = toint(TraceAttributes["http.response.status_code"])
| order by StartTime desc
| take 20
```

If 0 rows: case not found in environment + window. Note in output:
`Case {app_code} not found in {env} between {window}.` This is itself
useful evidence — may indicate stale ticket, environment mismatch, or
case GUID rolled.

### Query 2 — Errors in window for the case

Surface 4xx / 5xx and span errors associated with this case.

```kql
Traces
| where StartTime between (datetime({creation_minus_12h}) .. datetime({creation_plus_12h}))
| where TraceAttributes has "porch.projectCode"
| extend projectCode = tostring(TraceAttributes["porch.projectCode"]),
         status = toint(TraceAttributes["http.response.status_code"]),
         path = tostring(TraceAttributes["url.path"]),
         server = tostring(TraceAttributes["server.address"])
| where projectCode has "{app_code}"
| where server has "{env_hostname_pattern}"
| where status >= 400 or SpanStatus == "STATUS_CODE_ERROR"
| project StartTime, TraceID, status, path, SpanName, SpanStatus
| order by StartTime desc
| take 20
```

### Query 3 — Component request flow

Filter by the URL's path component. Surfaces what the frontend was
calling when the bug was reported.

```kql
Traces
| where StartTime between (datetime({creation_minus_12h}) .. datetime({creation_plus_12h}))
| where TraceAttributes has "porch.projectCode"
| extend projectCode = tostring(TraceAttributes["porch.projectCode"]),
         path = tostring(TraceAttributes["url.path"]),
         server = tostring(TraceAttributes["server.address"])
| where projectCode has "{app_code}"
| where server has "{env_hostname_pattern}"
| where path has "{url_path_segment}"
| project StartTime, path, SpanName,
         status = toint(TraceAttributes["http.response.status_code"])
| order by StartTime desc
| take 20
```

`{url_path_segment}` is the path part of the URL (everything after
the hostname, e.g., `/case/12345/product`).

## Output format

In Pattern B output, emit a `Log evidence` block between the QE check
block and the Recommend block:

```
Log evidence — EJA-####
  Environment: <env> (derived from URL: <hostname>)
  Window: <YYYY-MM-DDTHH:MM> to <YYYY-MM-DDTHH:MM>
  Case lookup: <N> traces found / 0 traces (case not found)
  Errors in window: <N> 4xx/5xx / 0
    - <status> <method> <path> at <timestamp> — TraceID <id>
    - …
  Component flow: <N> spans on path "<segment>" / 0
Effect on recommendation: <one line>
```

The `Effect on recommendation` line shapes step 5:

| Findings | Effect |
|---|---|
| Errors found near reported time AND in component path | Strengthens bug confirmation; tilt toward `ready-for-remote` with TraceID evidence cited in the brief |
| Errors found, but unrelated to URL path | Still cite as context; don't alter recommendation |
| Case found, no errors | "Bug not log-visible" — could be UI/state-only bug; no effect on recommendation |
| Case not found in window/environment | Note in output; consider asking QE to re-verify ticket, but don't auto-push to `needs-info` (the bug may have happened, just not in the window we queried) |
| Kusto unavailable | One-line note; no effect |

## Cost discipline

- 3 queries per ticket × 1 ticket per Pattern B run = 3 queries.
- Each query bounded with `| take 20` and a 24h `between` filter.
- No re-run within a single /triage invocation; re-runs across
  invocations re-query (no cache).
- If a triage run targets multiple tickets (e.g., `/triage` cold list
  followed by triaging several in sequence), each qualifying ticket
  gets its own 3-query batch.

## Persistence on promotion

When `/triage promote` runs on a ticket that had log evidence:

1. Add a `## Log evidence` subsection inside the dev item's Context,
   after the Jira-context paste:

   ```markdown
   ### Log evidence (Kusto, captured YYYY-MM-DD)
   - Environment: <env>
   - Window: <range>
   - Errors observed: <count>
     - <status> <method> <path> @ <timestamp> — TraceID `<id>`
     - …
   - Component flow: <count> spans on path "<segment>"
   ```

2. Append TraceIDs to References as a sub-bullet under the Jira link:

   ```markdown
   - [EJA-####](<jira-url>) — Jira ticket
     - Kusto TraceIDs: `<id1>`, `<id2>`, `<id3>`
   ```

This survives the dev item across the worktree handoff. Remote-Claude
can pick up the TraceIDs and run deeper queries via
`ultron:log-investigation` without re-investigating from scratch.

## Anti-patterns

- **Don't query without a time filter.** Every query must have the
  `between(...)` filter; full-table scans are forbidden.
- **Don't expand the window past 24h** in v1. Wider windows belong in
  Remote-side `ultron:log-investigation`.
- **Don't follow trace IDs into deeper investigation.** v1 surfaces
  evidence; doesn't reproduce the bug from logs. That's the next step,
  not this one.
- **Don't write Kusto evidence to the dev item Open Questions section.**
  Open Questions is for unresolved decisions; log evidence is resolved
  facts. They go in Context with a captured-on date.
- **Don't post log evidence to Jira (yet).** v1's only Jira write is the
  QE needs-info comment. See "Future enhancements" below for the
  expected scope expansion.

## Future enhancements

Held until v1 has built operational confidence. Trigger to revisit:
~10 qualifying tickets processed and the log-evidence block has been
useful (informed at least one recommendation flip, or surfaced
unrelated context that shaped a fix) without being misleading.

### v2 — Log findings to Jira

Once log-search proves itself reliable, `/triage` should optionally
post the log-evidence block as a Jira comment, on Kyle's per-instance
confirmation (same posting flow as the QE needs-info comment). Comment
format:

```
**Log evidence (Kusto, <env>, <window>):**
- <N> errors observed: <status> <method> <path> @ <timestamp> — TraceID `<id>`
- <N> spans on path "<segment>"
```

Subject to the same concision rules as the QE comment (under 100
words, no softeners, lead with the finding).

### v3 — Code locator + finding comment

Extend Pattern B step 6 (Reproduce) to produce a structured "suspect
locations" hypothesis: file paths, line ranges, components most likely
to own the surfaced behavior. Combine with log evidence into a single
investigation-finding comment:

```
**Investigation finding:**
- Symptom: <short>
- Log: <N> errors at <path>, TraceID `<id>`
- Suspect: `<file>:<line-range>` (component: `<name>`) — <one-line reason>
- Adjacent fixes: <related EJA-#### tickets if any>
```

This crosses meaningfully into `ultron:jira-bulk-triage`'s lane (which
also writes investigation-finding comments). When v3 lands, revisit
the consolidation question — the architectural argument I made when
splitting them (Vault-Claude can't do code investigation) was weaker
than I claimed; `/triage` already does code-reading in Pattern B
step 6. The remaining honest distinctions:

- `/triage`: single-ticket, vault-side, runs at intake.
- `ultron:jira-bulk-triage`: multi-ticket batch, Remote-side, runs
  with full worktree code-investigation depth, owns field updates and
  transitions.

If at v3 the Vault-side investigation depth approaches Remote-side,
consolidation may be the right move — possibly by retiring `/triage`'s
investigation surface and reserving `/triage` for intake-and-promote
only, while `ultron:jira-bulk-triage` (or a successor) owns all
findings-writing. Decision deferred until v3 design.
