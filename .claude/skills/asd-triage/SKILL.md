---
name: asd-triage
description: Periodic backlog-wide pass over the ASD (Application Service Desk) ticket queue. Fetches all open ASD tickets, assesses QE completeness against the service desk template, clusters by domain, investigates QE-complete tickets (code + Kusto trace), and produces a combined routing + investigation document in 00 Inbox/. Also drafts Jira comments for reviewed findings. Distinct from the /triage skill, which handles internal EJA sprint bugs.
---

# ASD Triage

Backlog-wide pass over the ASD (Application Service Desk) ticket queue — tickets filed by carriers and EDJ users through the external portal.

---

## When to Use

- Periodic sweep of the ASD backlog (run on demand, no fixed cadence)
- Before a sprint planning or prioritization conversation to surface carrier/EDJ pain
- After a known batch of new ASD tickets arrives
- **Do not use** for internal EJA sprint bugs — those are handled by `/triage`

---

## Configuration

**Jira Cloud:** `porchsoftware.atlassian.net`

**ASD Project JQL (backlog-wide):**
```
project = ASD AND statusCategory != Done ORDER BY created DESC
```

**Legacy ASD ticket field IDs** (current — pre-new-template):

| Semantic field | Jira custom field ID |
|---|---|
| Steps to Reproduce | `customfield_10190` |
| Issue / Symptom | `customfield_10194` (carries old NYL-flavored boilerplate; reporters consistently leave it unfilled — see transition note below) |
| Expected Result | `customfield_10741` |
| Actual Result | `customfield_10742` |

**Transition period — new EDJ template DRAFTED 2026-05-20, NOT YET ROLLED OUT (as of 2026-05-27).**

The new EDJ Annuity Service Desk Template (`File ID F0B4NT922BH` in Slack) specifies a much richer field structure: Application Code (K-code), Carrier, Product Type, Application Jurisdiction, Owner Type, Screen/Page, Field(s) Affected, Form Context block (Form Name/ID + Fields Not Stamping + Participants + Missing/Wrong), and a **required Workflow Client Payload**. None of these have dedicated Jira fields today — they exist in the template doc only.

Until the portal rollout lands (see inbox stub `ops-roll-out-new-edj-asd-portal-template.md`), the operational reality is:

- `customfield_10194` ("Issue / Symptom") is **always** the old NYL-flavored boilerplate (`ADV/FA / DELE/BOA / EAPP / CASE / POLICY / PO/PI / EMAIL / REQUESTER NAME & CONTACT INFO / ZD Ticket #`) — reporters skip it because the field names are NYL-distribution-specific and don't apply to EDJ / Corebridge / MassMutual / Protective tickets. **Do not rely on customfield_10194; treat it as noise.**
- Steps / Expected / Actual (`customfield_10190 / 10741 / 10742`) ARE being used — sometimes filled, sometimes null. Use them as primary sources.
- The free-form **description** body carries the real symptom narrative for most tickets — read it carefully.
- **Application Context** (K-code, Carrier, Product, Jurisdiction, Owner Type, Screen, Field) typically lives in description prose or has to be inferred from reporter org + product mentions + screenshots. K-codes are present only when reporter explicitly includes them (rare — ~1 in 13 today).
- **Workflow Client Payload** is essentially never attached today.
- **Attachments** (screenshots, PDFs, sometimes HAR files) carry significant diagnostic value — fetch and inspect when blocked.

**When the rollout lands:** confirm new field IDs by fetching one post-template ticket with `expand: "names"`. Update this section with the new IDs. Replace the customfield_10194 row with the new structured-Application-Context fields. Make Workflow Client Payload a P0-blocking requirement in the QE Completeness Rubric.

---

## Workflow

### Step 1 — Fetch the ASD backlog

Run the JQL and fetch all open tickets:

```
mcp__plugin_atlassian_atlassian__searchJiraIssuesUsingJql
  cloudId: "porchsoftware.atlassian.net"
  jql: "project = ASD AND statusCategory != Done ORDER BY created DESC"
  fields: ["summary", "status", "assignee", "priority", "reporter", "created", "updated",
           "description", "customfield_10190", "customfield_10194",
           "customfield_10741", "customfield_10742"]
  maxResults: 100
  responseContentFormat: "markdown"
```

**Pagination is required.** The search returns at most 100 issues per page, and the response's `totalCount` reflects the page, not the global total — so a single call will silently miss tickets when the backlog exceeds 100. Paginate by re-issuing the query with an `issuekey < ASD-<lowest_returned>` filter until a page returns fewer than 100 results. Capture the union of keys across all pages as the **authoritative live open count**; you will reuse it in Step 8 to validate coverage.

For each ticket returned, also fetch full detail individually if the search response truncates description/custom fields.

### Step 1b — Compute delta vs prior snapshot

Look for the most recent prior triage file in `00 Inbox/` matching either pattern:
- `YYYY-MM-DD-asd-triage.md` (manual local runs)
- `asd-nightly-YYYY-MM-DD.md` (scheduled routine output)

Pick the most recent by date. If none exists, **skip the delta entirely** — do not emit the delta line in the header or the two delta sections in the output. State "no prior snapshot available" in the run report only.

If a prior snapshot exists:

1. Parse the ticket IDs present in that file (grep `ASD-NNN`).
2. Compute three sets against today's Jira fetch:
   - **New** — tickets in today's fetch whose `created` date equals today (run date).
   - **Closed** — ticket IDs in the prior snapshot that are NOT in today's open backlog.
   - **Updated** — tickets in today's fetch with `updated` date equal to today AND not in **New**.
3. Capture the prior total open count from the snapshot's header for the delta line.

These three sets drive the **Delta line** in the header, the `## New since yesterday` section, and the `## Updated since yesterday` section (template below).

### Step 2 — Deduplicate against vault active items

Check `00 Inbox/` (and `02 Areas/development/archive/items/`) for any item that references an ASD ticket ID. Mark those as **already-tracked** and exclude from investigation. List them in the output doc reference section.

Also check `00 Inbox/` for any backlog item sourced from ASD tickets.

### Step 3 — Assess QE completeness

For each ticket, score against the service desk template rubric (see below). Classify as:
- **QE-complete** — all required fields present; proceed to investigation
- **Needs-info** — one or more required fields missing; document gaps, skip investigation
- **Form-stamping** — Form Context section present; route to `form-stamping-investigation` skill
- **Already-assigned** — has a non-Kyle assignee; note owner, skip investigation

### Step 4 — Cluster

Group QE-complete and needs-info tickets before investigating. Cluster signals:
- Same carrier + same form family → form stamping cluster (→ `form-stamping-investigation`)
- Same code path / UI component referenced in title or steps → code-path cluster
- Same screen or page name → UI cluster
- Same XML 103 element name → XML cluster
- Same Owner/Annuitant/Beneficiary relationship flow → ownership cluster

Name clusters by domain theme (e.g., "Pacific Life — Beneficiary Stamping", "XML 103 — GovtID gaps", "Joint Annuitant — Relationship options"). Promote the richest ticket as cluster parent; link siblings.

**Link the cluster in Jira too** (not just in the vault doc). When a cluster of similar tickets is identified, the sibling tickets should carry a **"Relates"** issue link to each other (or to the shared parent/mirror story) so the relationship is visible in Jira to whoever picks them up. This is an outward Jira write → **propose, don't auto-create**: list the proposed links (which tickets, which type) in the output doc under the cluster, and create them with `createIssueLink` only on Kyle's go (one batched approval per cluster is fine). If the cluster already mirrors a single EJA story, prefer linking each sibling to that parent over N×N sibling links (less noise — see the mirror-ownership gate in Step 5).

### Step 5 — Capability lookup + Investigate

The vault carries a rich capability corpus at `03 Resources/ultron/capabilities/` + `03 Resources/ultron/reference/` that should be consulted **before** raw code archaeology. The capability docs encode:
- Symptom-to-capability mappings (e.g., XML 103 emit issues live in form-stamping cluster)
- Known gap inventories with codes (R/S/D/RE/CC/TS/ARC/EAPI/A11Y prefixes)
- File:line references to the relevant slices, models, services
- Cross-cluster overlap signals

**Step 5a — Capability lookup (do this first, for every QE-complete ticket):**

1. **Match the symptom to one or more capability pages.** Use the shared mapping: `03 Resources/reference/symptom-capability-map.md` (shared source for both triage skills).

2. **Check the relevant cluster's `*-extraction-targets.md` page** for known-gap codes. If the ticket's symptom matches a documented gap (e.g., R1 DTCC idempotency, R2 EDJ Delegator retry, S1 audit log, D1 status column, T6 form-stamping carrier conditionals), flag it explicitly in the hint:
   > "**Known-gap manifestation.** This is a symptom of [R-code / S-code / etc.] — see [[capability-X]] + inbox stub `xx-yy.md`. Fix is queued; expected behavior until the broader extraction lands. Bundle with that work rather than fix one-off."

3. **Check for cross-cluster overlap.** Capability pages list cross-references; clusters list overlap codes. A ticket may touch:
   - Reliability + data-model (e.g., DocuSign idempotency + application status)
   - Form-stamping + data-model (Trust-owner emit gaps)
   - Security + release-engineering (SAST scanning + dependency management)
   Surface the overlap explicitly in the hint and clustering comment.

4. **Pull file:line references directly from the capability page** when relevant. Capability pages already cite the slices, models, services. Use those citations in the hint rather than re-discovering paths.

**Step 5b — Investigate (only if capability lookup is insufficient):**

For each QE-complete non-stamping ticket, run the shared diagnosis procedure (`03 Resources/reference/diagnosis-procedure.md`) at **`intake` depth** with the **`opportunistic-ASD`** field-rubric. It emits root cause + `file:line` + root-cause confidence (1-5) + repro status; map confidence to High/Med/Low/None for the doc. (Coverage validation, vault-finalize, and the `## Doc updates needed` loop are unchanged.)

For form-stamping tickets: invoke `form-stamping-investigation` skill with the ticket IDs in the cluster. Do not manually trace the form tool pipeline — that skill owns it.

**When the capability lookup says "this is a documented unknown,"** stop deep investigation and route to needs-info / coordination-with-product. The capability docs make explicit what we don't know yet — don't burn investigation budget rediscovering it.

**Apply the mirror-ownership gate before grading any ticket "ready-for-kyle / ready-for-remote / ship-ready"** (per `03 Resources/reference/diagnosis-procedure.md` → *Mirror-ownership gate*). Resolve the EJA↔ASD mirror and check its assignee + status + newest comment: if the mirror is assigned and in active sprint flow, the ticket is **owned elsewhere** — record the owner + status, do NOT surface it as pick-up work no matter how clean the fix looks. A finding the mirror's owner has already fixed or disputed in a comment is not ship-ready.

**Parallelism:** Investigate up to 5 tickets in parallel within a cluster. Clusters are investigated sequentially.

**Documentation feedback loop:** if a ticket reveals that a capability page is wrong, incomplete, or doesn't cover the symptom area, flag it in the triage doc under a `## Doc updates needed` section. ASD tickets are the operational feedback signal for the capability corpus.

### Step 5c — Residual-refile (closed-but-not-resolved → fresh-EJA drafts)

Closes the recurring "deployed but still reproducing" friction (`closed-not-resolved-asd-blockers`, friction-register fix-rule): when an ASD's mirror EJA is **Done + verified in UAT** yet the ASD is **still open**, the deployed fix didn't resolve the report — and the Done mirror can't be reopened as the carrier, so a **fresh EJA bug** is the correct artifact (eng recreates the EJA for POs to schedule — the standard eng-side ASD responsibility). Spec: `99 Meta/specs/2026-07-09-asd-mirror-autofile-on-closeout.md`.

1. **Detect** — over the open ASDs that carry a **Done** EJA mirror (already resolved in Step 2/Step 5), get the deploy verdict from `deploy-verify` (`--uat-mirror-scan`, or `--batch` on just the mirror keys). Target = the **✅-in-UAT bucket where the ASD is still open**. (deploy-verify is read-only detection; it does the crawl, this step consumes the ✅ bucket.) If the tracker is unreachable (off internal network), carry the deploy status from the ticket/prior findings and flag that it wasn't re-confirmed this run.
2. **Dedup** — skip any ASD that already has a `Relates` link to a **non-Done** EJA created *after* the mirror's resolution date (a fresh mirror was already filed). Don't re-draft.
3. **Draft a fresh EJA per survivor** (do NOT auto-create): summary `<ASD summary> (residual after EJA-XXXX)`; description = the ASD repro + the deploy-verify evidence (mirror EJA-XXXX ✅ in UAT on <date>, carrying key) + a one-line "prior fix insufficient — residual defect"; links `Relates` → the ASD **and** the prior mirror EJA (not Duplicate/Cloners — it's a *distinct* residual); priority mirrors the ASD; assignee unset (PO schedules).
4. **Output by mode:**
   - **Unattended** (night shift / no Kyle): write the drafts to `00 Inbox/<LOCAL>-asd-mirror-refile-drafts.md` (one-click-fileable) + a Needs-Kyle line, and land a Needs-Kyle Inbox item per draft (`source: asd-triage`, `id:` = the lowercased ASD key, upsert per `.claude/skills/morning/needs-kyle-items.md`). Never auto-create in Jira.
   - **Supervised** (Kyle present): present the drafts, then `createJiraIssue` + `createIssueLink` per-item on his go (honors draft-before-post + no-auto-transition).

### Step 6 — Produce output document

Write `00 Inbox/YYYY-MM-DD-asd-triage.md` using the output format below. Include all tickets — investigated, needs-info, already-tracked, and assigned.

### Step 7 — Draft Jira comments

For each investigated ticket, draft a Jira comment following the comment format below. Append all drafts to the output doc under a `## Jira Comment Drafts` section.

**Present ALL drafts to Kyle before posting. Do not post without approval.**

Once Kyle approves, post using:
```
mcp__plugin_atlassian_atlassian__addCommentToJiraIssue
  cloudId: "porchsoftware.atlassian.net"
  issueIdOrKey: "ASD-NNN"
  comment: "<approved text>"
  contentFormat: "markdown"
```

### Step 8 — Validate coverage against the ASD board

Before declaring the doc done, **re-run the JQL** (with pagination per Step 1) and compare the live open-ticket set to the doc you just wrote. This is the contract: every open ticket on the board must have a section entry in the doc.

Validation procedure:

1. Paginate `project = ASD AND statusCategory != Done` and collect the union of issue keys. Record the **live open count** and the full key set.
2. Parse the produced doc and extract:
   - **Section headers** — every line matching `^### .*ASD-(\d+)` (the per-ticket entries). Distinct IDs here are the doc's actual coverage.
   - **All references** — every `ASD-\d+` mention anywhere in the doc, for the secondary "referenced but not entry'd" audit.
3. Compute the three sets:
   - **Missing in doc** = `open_keys − section_header_keys`. **Must be empty.** Any ticket here is an unaddressed gap; investigate and add an entry before completing.
   - **Stale in doc** = `section_header_keys − open_keys`. These are tickets that closed between the original sweep and now. Note them (they don't block completion, but flag for cleanup).
   - **Referenced-but-not-entry'd** = `open_keys ∩ all_references − section_header_keys`. These appear in prose, tables, or "already-tracked" lists without a triage entry. **Must also be empty** for a complete triage.
4. Add a **Coverage** section near the bottom of the doc summarizing the audit:
   - Total open on Jira board: N
   - Tickets with section entries: M (should equal N)
   - Stale (closed since): list with links
   - Verification JQL + pagination breakdown (e.g., "4 pages: ASD-539→647 = 100, ASD-406→537 = 100, ASD-221→404 = 100, ASD-22→219 = 53")
5. If missing tickets exist, **do not finalize**. Fetch them, triage them, add entries, and re-run the audit until missing = 0.

Reference implementation (Python; adapt cloudId/file paths as needed):

```python
import re, json
# 1. After paginated fetches, load all open keys into a set
open_keys = set()   # populated from paginated search results
# 2. Parse the produced doc
text = open(doc_path, encoding='utf-8').read()
section_headers = set(int(m) for m in re.findall(r'^### .*?ASD-(\d+)', text, re.MULTILINE))
all_refs        = set(int(m) for m in re.findall(r'ASD-(\d+)', text))
# 3. Audit
missing  = sorted(open_keys - section_headers)
stale    = sorted(section_headers - open_keys)
orphans  = sorted((open_keys & all_refs) - section_headers)
assert not missing, f'Missing section entries for: {missing}'
assert not orphans, f'Tickets referenced but missing entry: {orphans}'
print(f'Open: {len(open_keys)} | Entries: {len(section_headers)} | Stale: {len(stale)}')
```

Report the validation result in the chat reply so Kyle can see live-vs-doc parity at a glance.

### Step 9 — Finalize + chat report

After the vault doc passes coverage validation, finalize in the vault and report back. **The vault doc is the deliverable** — no Drive upload, no Slack canvas, no DM.

**Delivery (revised 2026-06-20):** vault-only. The vault doc (`00 Inbox/YYYY-MM-DD-asd-triage.md`) is the durable artifact and the single deliverable — documenting in the vault is sufficient (Kyle's call, 2026-06-20). Drive upload was dropped because the night-shift's auto-mode classifier blocked the external upload as a cross-boundary write on three consecutive runs (6/19–6/20); the vault already holds the full doc, so the upload added a failure mode without adding value. Slack was dropped earlier (5/28, MCP token expiry). The canvas template at [[99 Meta/templates/asd-triage-canvas]] remains a **manual-canvas reference** for when Kyle wants to post.

**Procedure:**

1. **The vault doc is final** — `00 Inbox/YYYY-MM-DD-asd-triage.md`, already written and coverage-validated. No external upload.

2. **Append instance entry** to `02 Areas/Engineering-Work/scheduled-tasks-log.md` under "## Instance history" — date/time of fire (UTC), open-ticket count, new/closed deltas, headline signal, link to the vault doc.

3. **Jira comment drafts** stay in the vault doc under the `## Jira Comment Drafts` section — do NOT auto-post; Kyle reviews + posts manually if/when.

4. **Register the blocked-on-Kyle items.** Any ticket the triage classifies as needing a **Kyle/product decision or a scope definition** before it can move → land a Needs-Kyle Inbox item per `.claude/skills/morning/needs-kyle-items.md` (`source: asd-triage`; `id:` = the lowercased ticket key, which is the dedupe axis). The triage doc scrolls off the render; a `status: needs-kyle` item is the durable surface `/morning` reads. Do NOT register needs-info (waiting on the reporter, not Kyle), already-tracked, or PO-schedulable items — only the ones genuinely waiting on Kyle.

5. **Report back** with: vault doc path, headline signal (1 line), total open / new / closed counts. Kyle reads on his own time.

**Why vault-only:** the vault doc is version-controlled, durable, and already the record Kyle reviews. The Drive copy was a redundant second surface that kept tripping the night-shift classifier; removing it eliminates a recurring failure with no loss (the doc is in the vault either way). Kyle posts to Slack manually when he wants a team-visible message.

**If Kyle later wants Drive or the Slack canvas restored**: the canvas/DM shape is at [[99 Meta/templates/asd-triage-canvas]]; the Drive upload was a single `mcp__claude_ai_Google_Drive__create_file` call to folder `1N7PMP59_C3GmTi1ilMU4eGNMNrwqnEbj` (see git history of this file for the exact params). Easy to re-add.

---

## QE Completeness Rubric

Based on the EDJ Annuity Service Desk template (drafted 2026-05-20, **not yet rolled out** in the portal — see Configuration § Transition period above).

> **Apply the rubric opportunistically, not strictly.** Per memories `feedback_asd_not_qe_rubric.md` and `feedback_asd_opportunistic_diagnosis.md`, ASD tickets are external-tester filings and most reporters don't fill the structured fields. Diagnose with what's there; ask only for specific gaps; don't push back as default. The rubric below describes what the new template **will** require post-rollout — until then, treat most of it as aspirational and lean on description + screenshots + capability mapping.

**Base fields — what the new template will require:**

| Field | What to look for | Today's reality (pre-rollout) |
|---|---|---|
| Environment | "Playground" or "UAT" explicitly stated | Usually inferable from reporter org (carrier → Playground, EDJ → UAT per memory `reference_asd_environment_routing.md`) |
| Steps to Reproduce | Numbered, reproducible steps | `customfield_10190` — sometimes filled, sometimes null |
| Application Code | K-prefixed code (e.g., K1-OH6X7-A-01) | **Rarely present today** (~1 in 13 tickets). Highest-leverage missing field. |
| Carrier | Named carrier (e.g., Pacific Life, Corebridge, MassMutual) | Inferable from reporter org / product mentions |
| Product Type | Named product (e.g., Fixed Indexed Annuity, MVA II) | Usually in description prose |
| Application Jurisdiction | US state code or name | Sometimes in description (e.g., "MVA II case in KS state") |
| Owner Type | Individual / Joint / Trust / Entity / Custodian | Usually in description |
| Screen / Page | Named page (e.g., "Beneficiary page", "Paperwork Attestation") | Usually in description |
| Field(s) Affected | Specific field name(s) | Usually in description |
| Expected Result | What should have happened | `customfield_10741` |
| Actual Result | What actually happened | `customfield_10742` |
| Client Payload | Workflow client payload copied into ticket | **Essentially never present today** — silver-bullet for backend diagnosis when it lands |

**Form Context fields — required when issue involves form stamping (post-rollout):**

| Field | What to look for | Today's reality |
|---|---|---|
| Form Name / ID | Form identifier printed on form (e.g., FR1215RFA, ICC20:25-1339-A, ACORD 951E) | In description or attached PDFs |
| Fields Not Stamping / Stamping Wrong | Specific field names and participant roles | In description or attachment screenshots |
| Participants Involved | Owner / Joint Owner / Annuitant / Primary Bene / Contingent Bene / Advisor | Inferable from owner type + context |
| Missing or wrong data | One of: Missing / Wrong data / Both | Inferable from description |

**Soft-required (flag if absent, don't block):**
- Evidence attachments (screenshots, HAR file, screen recording, AppKit PDF)
- Cache cleared confirmation

**QE gap notation** (use in output doc, **opportunistically — not as a needs-info gate today**):
```
**QE gaps:** app-code, client-payload (carrier+product+steps+actual present)
```
List what's missing first, then note what IS present. Today this surfaces leverage (e.g., "if we had the K-code we could Kusto-trace") rather than blocks investigation.

**Customfield_10194 caveat:** `customfield_10194` ("Issue / Symptom") currently shows old NYL-flavored boilerplate (`ADV/FA / DELE/BOA / EAPP / CASE / POLICY / PO/PI / EMAIL`) that reporters consistently leave unfilled. **Do not treat its presence as signal; do not flag its emptiness as a gap.** It's portal-state noise until the rollout (`ops-roll-out-new-edj-asd-portal-template.md`) replaces it with the new structured Application Context fields.

**Post-rollout transition:** When the new template lands, update this rubric:
1. Capture the new Jira custom field IDs for K-code, Carrier, Product, Jurisdiction, Owner Type, Screen, Field(s) Affected, Form Context block, Workflow Client Payload
2. Promote Workflow Client Payload to **P0-blocking** for needs-info (it's required per the new template)
3. Remove the "Today's reality" column from the table above
4. Strengthen the QE gap notation back to a real needs-info gate

---

## Output Document Format

````markdown
---
created: YYYY-MM-DD
source: asd-triage
status: ready-for-kyle
---

# ASD Backlog Triage — YYYY-MM-DD

N open ASD tickets assessed.
- X investigated
- Y needs-info
- Z already-tracked
- W assigned (not Kyle)

Delta vs prior snapshot (PRIOR-DATE): +A new / -B closed / C updated. (Omit this line entirely if no prior snapshot exists.)

JQL: `project = ASD AND statusCategory != Done ORDER BY created DESC`

## Summary

| Action           | Count | Tickets                            |
|------------------|----- -|------------------------------------|
| Investigated     | X     | [ASD-NNN](https://porchsoftware.atlassian.net/browse/ASD-NNN), ... |
| Needs-info       | Y     | [ASD-NNN](https://porchsoftware.atlassian.net/browse/ASD-NNN), ... |
| Already-tracked  | Z     | [ASD-NNN](https://porchsoftware.atlassian.net/browse/ASD-NNN) (→ vault-slug) |
| Assigned         | W     | [ASD-NNN](https://porchsoftware.atlassian.net/browse/ASD-NNN) (@person) |
| Form stamping    | V     | [ASD-NNN](https://porchsoftware.atlassian.net/browse/ASD-NNN), ... (→ form-stamping-investigation) |

## New since yesterday

*(Omit this section if no prior snapshot exists. Source: Step 1b "New" set.)*

Tickets created since the prior snapshot. Each entry:

- [ASD-NNN](https://porchsoftware.atlassian.net/browse/ASD-NNN) — [Title] · status · priority · reporter · env (if determinable)

## Updated since yesterday

*(Omit this section if no prior snapshot exists. Source: Step 1b "Updated" set — excludes anything already listed in **New since yesterday**.)*

Tickets touched since the prior snapshot but not newly created. Each entry:

- [ASD-NNN](https://porchsoftware.atlassian.net/browse/ASD-NNN) — [Title] · status · priority · reporter · what changed (status transition, assignee change, comment, field update — whatever the fetch can determine)

## Cluster A — [Carrier / Symptom theme]

### [ASD-NNN](https://porchsoftware.atlassian.net/browse/ASD-NNN) — [Title]
- **Carrier / Product:** [carrier, product name]
- **Env:** Playground / UAT
- **Jurisdiction:** [state]
- **Owner type:** [type]
- **Reporter:** [name], [date]
- **Template format:** new / legacy
- **QE gaps:** [missing fields] ([present fields])
- **Root cause:** [code path summary, if investigated]
- **Fix:** [`File.cs:NN` or `file.ts:NN` — approach]
- **Confidence:** High / Medium / Low / None
- **Action:** investigate / needs-info / already-tracked / assigned / blocked / form-stamping

#### Root Cause

[Flow diagram in inline code block:]
FE → ComponentName { field: value }
BE → GathererClass emits FIELD = null
...

[Prose explanation]

#### Fix

**`Path/To/File.cs`** — description of change:

```csharp
// proposed change
```

[Safety note if relevant]

#### Evidence
- `File.cs:NN` — what this shows
- `file.ts:NN-NN` — what this shows

#### Next Steps *(partial investigations only)*
1. [What remains]

---

## Already-tracked (reference only)

- [ASD-NNN](https://porchsoftware.atlassian.net/browse/ASD-NNN) → `00 Inbox/vault-slug.md`

---

## Jira Comment Drafts

*(Kyle reviews before posting)*

### [ASD-NNN](https://porchsoftware.atlassian.net/browse/ASD-NNN)

**[Category label]:** [concise finding. File:line. Related: [ASD-NNN](https://porchsoftware.atlassian.net/browse/ASD-NNN) if shared root cause.]
````

---

## Investigation Format

Per ticket, use this section structure (same as in the output doc above):

**Root Cause** — code flow diagram (inline code block) + prose explanation of the gap.

**Fix** — specific file path + change description + code sketch.

**Evidence** — bulleted `file.ts:NN` anchors with one-line explanations.

**Next Steps** — only for partial investigations; numbered, actionable.

**Confidence levels:**
- **High** — root cause identified, fix location known, evidence anchored to specific lines
- **Medium** — likely root cause; fix approach unclear or needs product/carrier confirmation
- **Low** — partial trace; multiple hypotheses; more investigation needed
- **None** — blocked (Schema NP auth, missing COOP data, insufficient ticket info)

---

## Jira Comment Guidelines

- Lead with a bold category label:
  - `**Code fix:**` — change required in Ultron FE or BE
  - `**Data population issue:**` — FE not sending a field the BE needs
  - `**Form tool fix:**` — fix is in form tool JSON config (lexicon key, mapping, participant slot)
  - `**COOP data fix:**` — carrier lookup data is wrong; no code change
  - `**Known-gap manifestation:**` — symptom of a documented capability gap (R/S/D/RE/CC/TS/ARC code); cite the gap + capability page + inbox stub
  - `**Cross-cluster pattern:**` — multiple tickets share an underlying surface (e.g., Trust-owner emit, Buyer's Guide form-inclusion rules, IRA + Joint-Life product matrix); name the umbrella and link siblings
  - `**Needs further diagnosis:**` — partial trace, can't confirm root cause yet
  - `**Needs-info:**` — ticket missing fields required to investigate
  - `**Same root cause as ASD-NNN.**` — already tracked or clustered
- Include specific file:line references (capability pages already cite many of these — reuse rather than rediscover)
- Reference capability pages where helpful, e.g., `(see capability-form-stamping § Trust-owner emit branch)`
- Keep under 200 words
- Don't restate the ticket description
- Use "Same root cause as ASD-NNN" not "Duplicate of" for related tickets

---

## Anti-Patterns

- **Don't post comments without Kyle's review.** Always present drafts first.
- **Don't investigate needs-info tickets.** Document the gaps and move on; investigation time is wasted without repro details.
- **Don't duplicate form-stamping investigation.** When Form Context is present, delegate to `form-stamping-investigation` skill — it owns the Schema NP API lookup and form tool JSON tracing.
- **Don't re-investigate already-tracked tickets.** Check vault active items first; if it's there, list it in the reference section only.
- **Don't fetch full ticket payloads for summary stats.** Use the `fields` parameter to limit response size; only expand to full fetch when investigating.
- **Don't speculate root cause at Low/None confidence.** State what you traced and where you stopped. A clean partial report is more useful than a guess.
- **Don't trust the first page of search results as the full backlog.** The Jira search returns max 100 per page and `totalCount` is per-page, not global. Paginate (Step 1) until a page returns fewer than 100 keys, then take the union. A doc that misses tickets silently is worse than no doc.
- **Don't finalize the doc without running Step 8 validation.** A triage doc that claims to cover the backlog but omits open tickets is a coverage bug. The validation step is the contract — run it, surface the result in the chat reply, and re-fetch any missing tickets before declaring done.
- **Escape angle brackets when copying ticket titles into the doc.** Ticket titles in this domain often contain XML element names (e.g. `<TransRefGUID>`, `<DialNumber>`, `<ChildKey>`). A bare `<Tag>` in a markdown heading or prose is read by Obsidian as an unclosed HTML tag and **swallows the rest of the document's formatting**. Wrap any `<...>` from a title in a backtick code span (`` `<TransRefGUID>` ``) or use `&lt;…&gt;`. (Broke the 2026-07-09 triage doc at the ASD-1113 heading.)
