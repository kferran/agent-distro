---
name: triage
description: Run incoming Jira and ASD tickets through a small state machine — needs-triage, needs-info, ready-for-remote, ready-for-kyle, wontfix. Fetches via the Atlassian MCP, gathers prior context, recommends category and state, and on promotion creates a vault dev item from the ticket. Triggered by "/triage", "/triage EJA-####", "triage incoming tickets", "what should I look at next?".
allowed-tools: Read, Write, Edit, Glob, Grep, Bash
---

# Triage Skill

Mediates the flow from Jira / ASD (Application Service Desk) tickets into vault dev items. Adapted from mattpocock/skills `triage`. The vault analog of GitHub Issues triage.

## Project scope

Currently in scope:

- **EJA** — EDJ Annuity engagement. Primary project. Most triage activity flows through here.
- **ASD** — Application Service Desk. Customer-facing failure reports (typically prefixed `ASD EJA - …` in summary). Often EJA-tagged or convertible to EJA.

Other Jira projects exist but are out of scope for now. When a new project becomes a focus area, update this section and revisit the JQL queries in `02 Areas/development/jira-backlog.md`'s frontmatter.

If `/triage` is invoked against a ticket key from a project not listed above, surface the ambiguity:

> "EJA-#### is the current scope; key XYZ-#### is outside it. Add XYZ to scope, or skip?"

Don't silently expand scope.

## Concepts

**Triage roles** are a small state machine for incoming work. Every ticket carries one **category** and one **state** while in triage.

**Categories:**
- `bug` — something is broken
- `enhancement` — new feature or improvement
- `investigation` — needs codebase / data exploration before category can be assigned (often the right starting state for ASD reports without enough detail)

**States:**
- `needs-triage` — newly pulled, not yet evaluated
- `needs-info` — waiting on the reporter (ASD QE, business stakeholder, dev team) for clarification
- `ready-for-remote` — fully specified, brief is ready to hand to Remote-Claude
- `ready-for-kyle` — Kyle implements himself (judgment call, architectural decision, or manual investigation)
- `bundle-with-extraction` — symptom matches a documented capability gap (R/S/D/RE/CC/TS/ARC/EAPI/A11Y code) with an existing inbox stub. The ticket is real but the work belongs to broader extraction effort; don't create a single-ticket dev item. See Pattern E.
- `wontfix` / `wontdo` — explicitly declined, with reasoning preserved in `02 Areas/development/out-of-scope.md`

**State transitions:** an unlabeled ticket normally goes to `needs-triage` first. From there it moves to `needs-info`, `ready-for-remote`, `ready-for-kyle`, `bundle-with-extraction`, or `wontfix`. `needs-info` returns to `needs-triage` once the reporter replies. Kyle can override at any time — flag transitions that look unusual and confirm before proceeding.

These roles live in the **Vault status** column of `02 Areas/development/jira-backlog.md` (e.g., `triage:needs-info`, `triage:ready-for-remote`). Once a ticket is promoted to a dev item, the role is implicit (the file's existence + status frontmatter carry it).

## Invocation

- `/triage` — show what needs attention. List `needs-triage` and `needs-info` rows, oldest first.
- `/triage EJA-2719` — triage a specific ticket. Fetch from Jira, gather context, recommend category + state.
- `/triage promote EJA-2719` — once decided as `ready-for-remote` or `ready-for-kyle`, create the vault dev item from the ticket.
- `/triage bundle EJA-2719 <inbox-stub-name>` — bundle a ticket with a documented gap's existing inbox stub (Pattern E). Use when the ticket is a real-world manifestation of a documented R/S/D/RE/CC/TS/ARC code.
- `/triage wontfix EJA-2719 "<reason>"` — close out a ticket as out-of-scope, append to `02 Areas/development/out-of-scope.md`.
- `/triage <free-form description>` — interpret the request and act. Examples: "show me anything blocking the sprint", "promote the License Check one", "anything still waiting on a reporter?".

## What this skill does

1. Reads `02 Areas/development/jira-backlog.md` to get the list of tickets and their current Vault status.
2. Fetches Jira context via the Atlassian MCP (`mcp__plugin_atlassian_atlassian__getJiraIssue`, `searchJiraIssuesUsingJql`).
3. For bugs, runs the QE diagnostic completeness check against the rubric in `QE-DIAGNOSTIC-RUBRIC.md` (sibling file).
4. For bugs, diagnoses via the shared diagnosis procedure (`03 Resources/reference/diagnosis-procedure.md`) at `intake` depth — which, for qualifying new bugs, runs the bounded Kusto log-search (per `LOG-SEARCH.md`, sibling file) and traces to `file:line`.
5. Recommends a category and state with reasoning.
6. For bugs, attempts a code-reading reproduction before grilling.
7. On promotion, creates the dev item file from the template, pre-fills it with Jira context (including any captured log evidence), and updates the backlog row.
8. On wontfix, appends to the out-of-scope log.

## What this skill does NOT do

- Does not transition tickets, edit fields, or post investigation findings. Field updates (assignee, story points, change risk, severity, status transitions) and post-investigation comments belong to `ultron:jira-bulk-triage`, which runs Remote-side with code-investigation context.
- Does not auto-promote to `ready-for-remote` without Kyle's explicit confirmation.
- Does not commit or push.
- Does not bypass `/grill` for sharpening — once a dev item is created, follow-on sharpening hands off.
- Does not read `Confidential/`. If a ticket references confidential context, surface the link without reading; let Kyle direct.

## Jira write boundary

The skill writes to Jira in **exactly one case**: when the QE diagnostic
check (Pattern B step 3) recommends `needs-info` due to missing required
diagnostics. In that case, the skill drafts a comment listing the missing
items and posts it on Kyle's per-instance confirmation. See
`QE-DIAGNOSTIC-RUBRIC.md` § "Auto-drafted reporter ask" for the comment
template, posting flow, and confirmation rules.

This bounded write-back keeps `/triage` distinct from
`ultron:jira-bulk-triage`:
- `/triage` writes "ask reporter for missing info" comments only.
- `ultron:jira-bulk-triage` writes investigation findings and field
  updates after Remote-Claude has investigated code. Different lane.

If the team's process changes such that Vault-Claude should also do
field updates or transitions, revisit the boundary — at that point
consolidating with `ultron:jira-bulk-triage` may be worth reconsidering.

**Planned expansion (deferred):** once the log-search step (Pattern B
step 4) builds operational confidence, the boundary will expand to
include posting log-evidence and code-locator findings as Jira
investigation comments. This convergence with `ultron:jira-bulk-triage`
is anticipated and tracked in `LOG-SEARCH.md` § "Future enhancements"
(v2 / v3). The consolidation question gets re-opened then.

## Execution patterns

### Pattern A: Show what needs attention (`/triage` cold)

1. Read `02 Areas/development/jira-backlog.md`.
2. Bucket rows into:
   - **`needs-triage`** — Vault status empty or set to `triage:needs-triage`. Oldest by Jira created date first.
   - **`needs-info`** — Vault status `triage:needs-info`. If the underlying Jira ticket has had reporter activity since the triage notes, surface those especially.
   - **Untracked** — rows in the backlog with no Vault status at all (treat as `needs-triage`).
3. For each bucket, show counts and a one-line summary per ticket:
   ```
   needs-triage (5):
   - EJA-2719 Blocker — License Check Does Not Display Issues In Client Residence State
   - EJA-2654 Bug — Annuity - Update display for License Check Errors
   - …

   needs-info (2):
   - EJA-2814 (waiting on Sean since 2026-04-30) — silent state-prefill on 2nd Create New annuitant
   - …
   ```
4. Ask Kyle which to triage next. Don't prescribe.

### Pattern B: Triage a specific ticket (`/triage EJA-####`)

1. **Fetch.** Use `mcp__plugin_atlassian_atlassian__getJiraIssue` to pull the full ticket (body, comments, labels, reporter, dates). If it's an ASD ticket, parse out the customer-facing details (FA ID, account, environment, screenshots).
2. **Gather prior context.** Check:
   - Does a dev item file already exist at `00 Inbox/*-EJA-####.md`? If so, surface its Status and Log.
   - Search `Meetings/` for any meeting that mentions this ticket key.
   - Search `Daily/` for any daily note that mentions it.
   - For ASD tickets, check the platform hub (`03 Resources/technical/<platform>.md` → Operational signals) for related patterns.
   - **Capability + stub lookup** (new). Match the symptom to one or more capability pages in `03 Resources/ultron/capabilities/` and their cluster extraction-targets pages. Then grep `00 Inbox/` for stubs (filename patterns: `be-*`, `fe-*`, `re-*`, `te-*`, `cc-*`, `a11y-*`, `eapi-*`, `arc-*`). If the ticket symptom matches an existing inbox stub or a documented R/S/D/RE/CC/TS/ARC/EAPI/A11Y gap, flag it. This is the strongest signal toward `bundle-with-extraction` in step 5.
     - Symptom→capability mapping: `03 Resources/reference/symptom-capability-map.md` (shared source for both triage skills).
3. **QE diagnostic check (bugs only).** If the ticket looks like a bug, run the rubric in `QE-DIAGNOSTIC-RUBRIC.md` against the description body and attachments. Render the per-item ✓ / ⚠ / ✗ block. Apply the severity rules to influence the recommended state in step 5 — hard-required missing (#5 steps, #6 actual, #7 expected, or #8 HAR-when-error-mentioned) or 3+ missing pushes to `needs-info`. When the rubric forces `needs-info`, draft the reporter-ask comment and offer to post it to Jira on confirmation (the skill's only Jira write — see `QE-DIAGNOSTIC-RUBRIC.md` § "Auto-drafted reporter ask" for the posting flow, and "Jira write boundary" below for scope).
4. **Diagnose (bugs only).** Diagnose via the shared procedure (`03 Resources/reference/diagnosis-procedure.md`) at **`intake` depth** with the **`strict-EJA`** field-rubric (a missing hard-required field → needs-info + reporter ask, per `QE-DIAGNOSTIC-RUBRIC.md`). It emits root cause + `file:line` + root-cause confidence (1-5) + repro status; feed that into the category/state decision. **Log-search scoping (this skill's gate, layered on the procedure's step-4 trigger):** run the bounded Kusto log-search (per `LOG-SEARCH.md`) only for *qualifying new bugs* — priority Blocker/High/Medium, created within the last 7 days, the QE rubric did not push to `needs-info`, and a log handle is extractable (App#/URL/FWID identifiers, or a K-code). When it runs, render the `Log evidence` block. (Procedure step 5 traces to `file:line` in the synced worktree.)
5. **Recommend.** Tell Kyle:
   - Recommended category (bug / enhancement / investigation) with reasoning.
   - Recommended state (`needs-triage` / `needs-info` / `ready-for-remote` / `ready-for-kyle` / `bundle-with-extraction` / `wontfix`) with reasoning. For bugs, the QE check from step 3 informs this directly; log evidence from step 4 (when present) strengthens or weakens the recommendation per `LOG-SEARCH.md` § "Effect on recommendation". **Capability + stub matches from step 2 are the strongest signal toward `bundle-with-extraction`** — when a ticket is a confirmed real-world manifestation of a documented gap with an existing inbox stub, don't create a new dev item; route to the broader extraction work instead.
   - A brief codebase summary if relevant (paths touched in similar prior fixes, related dev items, related branches).
   - When a capability page applies, cite it (e.g., "see `capability-reliability-and-failure-modes` R1") so Kyle has the substrate for any architectural decision.
6. **Apply the repro to the state decision (bugs only).** Use the repro status the procedure (step 4) emitted. A confirmed repro makes a far stronger brief and pushes toward `ready-for-remote`. A confirmed repro can override a soft QE-check `needs-info` (1–2 non-critical missing items) — code-side certainty trumps reporter-side gaps. Hard-required missing items still hold; missing reproduction steps means the brief Remote-Claude would receive isn't actionable, regardless of how confident the code-reading repro is.
7. **Wait for direction.** Kyle confirms category, state, and next step.

**Documentation feedback loop:** if Pattern B step 2's capability lookup found that the symptom isn't well-covered by any existing capability page, surface it in the recommendation:
> "⚠ Doc gap: this ticket's symptom area isn't covered in our capability docs. Worth a follow-up survey of [<area>] after triage."
This is the operational signal that the capability corpus needs expansion. ASD and EJA tickets are both feedback channels; EJA tends to surface internal-platform gaps, ASD tends to surface partner-integration gaps.

### Pattern C: Promote to dev item (`/triage promote EJA-####`)

Once Kyle chooses `ready-for-remote` or `ready-for-kyle`:

1. **Choose the slug.** Format: `<short-descriptive-slug>-EJA-####`. E.g., `license-check-residence-state-EJA-2719`. Pull the slug stem from the Jira summary (lowercase, hyphenated, drop punctuation, keep it under ~5 words).
2. **Create the dev item file** at `00 Inbox/<slug>.md` from `99 Meta/templates/dev-item.md`. Fill in:
   - Frontmatter: `slug`, `status: drafting`, `created: <today>`, `related_project` (inferred from project keywords — see `meeting-synthesis` Step 4 table).
   - **`files:`** — paths this fix is expected to touch, when the Pattern B investigation
     already named them: a capability page's file map, paths from a similar prior fix, or a
     component the log evidence points at. Comma-separated. Feeds R5 dispatch serialization
     — a live conductor holding one of these makes `cb-start` refuse and intake leave the
     item queued, which is what stops two agents meeting at PR time.
     **Only what the investigation actually surfaced — never guess to fill the field.** R5
     refuses on a declared overlap, so a wrong path buys a false refusal, while blank costs
     nothing worse than a missed catch. Omit it entirely when Pattern B didn't reach code.
   - **Goal**: pulled from Jira summary + first paragraph of description, condensed to one or two sentences.
   - **Context**: pulled from Jira description body, recent comments. Cite the Jira link.
     - If log evidence was captured during Pattern B step 4, append a `### Log evidence (Kusto, captured YYYY-MM-DD)` subsection with environment, window, errors observed, and component flow. See `LOG-SEARCH.md` § "Persistence on promotion" for the format.
     - If Pattern B step 2's capability lookup found a relevant capability page (and the ticket isn't bundled — that's Pattern E), cite it under context: `Capability reference: [[capability-X]] § Y`. The dev item's brief is shorter when the capability page already covers the surface.
   - **Constraints**: anything the Jira ticket explicitly notes (sprint deadline, dependency, must-not-break behavior). Often empty at promotion.
   - **References**:
     - `[EJA-####](<jira-url>)` — Jira ticket
       - If log evidence was captured: a `Kusto TraceIDs:` sub-bullet listing the trace IDs, so Remote-Claude can resume queries via `ultron:log-investigation` without re-investigating.
     - **Capability page(s)** that apply (e.g., `[[capability-form-stamping]]`)
     - **Cluster extraction-targets page(s)** if relevant (e.g., `[[form-stamping-extraction-targets]]` for the T-code list)
     - Any sibling dev items (existing or recently archived) on the same epic / branch / component
     - Platform hub link if relevant
   - **Open questions**: anything left ambiguous from the Jira ticket. Use `**proposed:**` framing.
   - Leave Out of scope, Status, Log empty.
3. **Pre-fill the agent-brief block** at the bottom of Context, using the template at `AGENT-BRIEF.md` (sibling file in this skill directory). The brief is what Remote-Claude (or Kyle) starts from. Behavioral, not procedural — describe what the system should do, not how to implement it.
4. **Handle ASD attachments.** If the Jira ticket has screenshots:
   - Create `00 Inbox/<slug>-attachments/`.
   - Note that screenshots need to be downloaded manually (Atlassian MCP can't download attachments directly).
   - List the attachment filenames in References for Kyle to fetch.
5. **Update jira-backlog.md.** Set the row's Vault status column to `tracked: [[00 Inbox/<slug>|<slug>]]`.
6. **Update backlog.md.** Add a new row to the Drafting section with today's `last touched` stamp.
7. **Suggest follow-on `/grill`.** "Created `<slug>`. Run `/grill <slug>` to sharpen the brief before queueing?"

### Pattern D: Close as out-of-scope (`/triage wontfix EJA-####`)

1. **Capture the reason.** Kyle provides a short reason (mandatory). Without one, refuse — out-of-scope without rationale is just deletion.
2. **Append to `02 Areas/development/out-of-scope.md`** with the format:
   ```markdown
   ## EJA-#### — [Jira summary]

   - **Closed:** YYYY-MM-DD
   - **Category:** bug / enhancement / investigation
   - **Reason:** [Kyle's reason]
   - **Jira:** [EJA-####](<url>)
   - **Related (if any):** [[items/<slug>|<slug>]]
   ```
3. **Update jira-backlog.md.** Set Vault status to `wontfix: <today>`.
4. **Do not modify the Jira ticket.** Kyle handles the Jira-side close (transition, comment) himself.

### Pattern E: Bundle with documented extraction (`/triage bundle EJA-#### <inbox-stub-or-gap-code>`)

Use when Pattern B step 2's capability + stub lookup found that the ticket is a real-world manifestation of a documented gap (R/S/D/RE/CC/TS/ARC code) and an inbox stub already covers the broader work.

1. **Confirm the mapping.** Kyle confirms the ticket → stub / gap-code link. If unclear, fall back to `ready-for-remote` and create a normal dev item.
2. **Locate the stub.** `00 Inbox/<stub>.md` — the stub that captures the broader extraction work.
3. **Update the stub** to record the EJA reference:
   - Add a `## Real-world manifestations` section if not present
   - Append: `- [EJA-####](<jira-url>) — <short description> — confirmed in prod / UAT on YYYY-MM-DD`
   - Each EJA reference on the stub strengthens the case to schedule the broader work soon
4. **Do NOT create a new dev item** at `00 Inbox/`. The dev item shape is per-EJA; bundling explicitly avoids the per-EJA duplication when the work is already captured.
5. **Update jira-backlog.md.** Set Vault status to `bundled: [[<inbox-stub-without-extension>]]`.
6. **Draft a Jira comment** for Kyle's review noting the bundling:
   ```
   **Known-gap manifestation.** This ticket reports a real-world occurrence of [brief description of the documented gap], tracked under <gap-code> in our capability documentation. The broader fix is captured at <inbox-stub-name> and will resolve this class of issues. Closing this individual ticket as duplicate-of-broader-work; the fix lands when <gap-code> is scheduled.
   ```
7. **Do not post the comment automatically.** Kyle reviews and posts manually (mirrors the asd-triage pattern).
8. **Optional promotion.** If multiple EJA tickets are now bundled under the same stub, that's a signal to **promote the stub to a Jira ticket** — surface to Kyle ("3 EJAs now reference this stub; schedule the broader work?").

⚠ **Use sparingly.** Bundle only when the match is clean — symptom matches a documented gap, stub captures the broader work, the EJA isn't going to be fixed independently of that work. When in doubt: `ready-for-remote` with a capability-page citation is the safer call.

## ASD-specific handling

ASD tickets (those whose Jira summary starts with `ASD EJA -`) come from QE / customer-facing failure reports. They tend to:

- Reference a specific FA (financial advisor) ID, account number, or case code.
- Include screenshots and a reproduction recipe.
- Have a specific environment (Playground, UAT, Production).
- Sometimes lack root cause analysis — investigation is part of triage.

When triaging an ASD ticket, additionally:

1. Pull the FA ID / account / environment into the dev item Context.
2. Check if there's a sibling Sentry/Kusto query worth surfacing (cross-reference `03 Resources/technical/<platform>.md` → Operational signals).
3. **Flag PII**: FA names, customer names, account numbers may need redaction depending on the dev item's destination. If the dev item will end up scp'd to Remote-Claude's worktree, Kyle decides what's safe to send.

The QE diagnostic check (Pattern B step 3) still applies. ASD tickets typically pre-satisfy #1 (credentials — FA ID + account come standard) and often #3 (App# / case code), so those rows are usually `✓` without extra effort. The rubric items most likely to be missing on ASD tickets are #6 (Actual Behavior header), #7 (Expected Behavior header), and #9 (logs) — ASD tends to prose-describe behavior rather than label it.

## Outward-text check — run the detector before anything is drafted for posting

Any text this skill drafts for a human to read outside the vault — a Jira comment, a reporter ask, a
reply to QE — goes through `avoid-ai-writing`'s detector before it is handed to Kyle. Rules in context
are not self-enforcing: on 2026-08-09 a comment drafted for QE was hand-audited against
`personality.md`, declared clean, and the detector then scored it **4** on a surviving em dash and
uniform paragraph length. Neither came out of reading the rules carefully.

```bash
node -e 'const {analyzeText}=require("/home/kyle/vault/.claude/skills/avoid-ai-writing/detector/patterns.js");
const t=require("fs").readFileSync(process.argv[1],"utf8");
const r=analyzeText(t,{context:"casual"});
console.log(r.score); console.log(JSON.stringify(r.issues,null,1));' /tmp/draft.txt
```

⚠️ The result key is **`issues`**, not `findings` — reading the wrong key returns an empty array and
looks like a clean pass.

**Context profile:** `casual` for Jira comments and Slack. Not the default `blog` profile, which
converts bullets to prose and would fight the house style. **Iterate to score 0** before handing the
draft over, and keep `personality.md` canonical wherever the two disagree.

## Output format

For each pattern:

- **Pattern A** — bulleted list, oldest first, ask which to triage.
- **Pattern B** — for bugs: QE diagnostic check block first, then (for qualifying new bugs) Log evidence block, then recommendation block (category, state, reasoning, repro result, auto-drafted reporter ask if `needs-info`). For enhancements / investigations: recommendation block only. Then wait for Kyle.
- **Pattern C** — terse confirmation: "Created `<slug>`, updated jira-backlog and backlog. Run `/grill <slug>` to sharpen?"
- **Pattern D** — terse confirmation: "Logged EJA-#### to out-of-scope.md. Update Jira-side yourself."

Keep all output scan-friendly. Kyle is moving fast through the triage queue.

## Edge cases

- **Atlassian MCP unavailable**: degrade to working from the row in `jira-backlog.md` alone. Note the limitation in the recommendation.
- **Ticket not in jira-backlog.md yet**: ask if it should be added first (the backlog is sourced from the JQL queries in its frontmatter — Kyle re-syncs that periodically).
- **Slug collision**: if `<slug>-EJA-####` already exists in items/ or archive/items/, refuse and ask Kyle. Don't silently overwrite.
- **Multiple Jira tickets for the same underlying issue**: surface the cluster and let Kyle decide whether to consolidate (one dev item, multiple Jira refs) or treat separately.
- **Confidential ticket**: do not auto-promote into the regular `items/` path. Surface the conflict; the right home is `Confidential/development/items/`, which Kyle owns the call on.
- **ASD ticket with PII in summary**: never echo PII into chat without need. Use the Jira key + a redacted summary.

## Integration

- **Composes with `/grill`**: after `/triage promote`, the natural next step is `/grill <slug>` to sharpen the new dev item.
- **Reads from**: `02 Areas/development/jira-backlog.md`, `00 Inbox/`, `02 Areas/development/archive/items/`, `Meetings/`, `Daily/`, platform hubs.
- **Writes to**: `00 Inbox/<slug>.md` (new), `00 Inbox/<slug>-attachments/` (new dir), `02 Areas/development/jira-backlog.md` (Vault status column), `02 Areas/development/backlog.md` (Drafting section), `02 Areas/development/out-of-scope.md` (wontfix entries).
- **Reference template**: see `AGENT-BRIEF.md` in this skill directory.
- **QE diagnostic rubric**: see `QE-DIAGNOSTIC-RUBRIC.md` in this skill directory.
- **Log search reference**: see `LOG-SEARCH.md` in this skill directory.

## See also

- `02 Areas/development/README.md` — full lifecycle, sync discipline, vault → remote pipe
- `02 Areas/development/jira-backlog.md` — the live ticket list
- `02 Areas/development/out-of-scope.md` — declined work log
- `99 Meta/templates/dev-item.md` — the dev item template
- `QE-DIAGNOSTIC-RUBRIC.md` (sibling) — bug-ticket completeness rubric, sourced from Confluence page 2440233030
- `LOG-SEARCH.md` (sibling) — Kusto log-search step for qualifying new bugs
- `ultron:jira-bulk-triage` — Remote-side counterpart for code investigation, batch field updates, and findings-comments. Distinct lane; see "Jira write boundary" above for the split.
- `ultron:log-investigation` — Remote-side deeper investigation. `LOG-SEARCH.md` is the bounded vault-side subset; defer to this skill on the worktree for fuller request-flow tracing.
