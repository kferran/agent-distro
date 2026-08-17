# QE Diagnostic Rubric

Reference checklist for verifying that a Jira bug ticket includes the
diagnostic information QE is supposed to provide.

Source of truth: [How to Create Defects in Jira](https://porchsoftware.atlassian.net/wiki/spaces/IKBS/pages/2440233030/How+to+Create+Defects+in+Jira)
(Confluence page `2440233030`).

**Last verified against Confluence:** 2026-05-10 (page version 30, edited
2026-04-16). Re-verify periodically; if QE updates the process, this file
needs to follow.

## Scope

Applied during `/triage <ticket>` Pattern B, after the Jira fetch and
before the category/state recommendation, **only when the recommended
category is `bug`**. Not applied to enhancements or investigations.

Description-body diagnostics only (v1). Title format, sprint assignment,
and priority discipline from the Confluence page are not checked here —
they're easier to verify visually and less load-bearing for triage
decisions. Add later if needed.

## Items

All items the Confluence guidance lists as required are **hard-required**
here. Missing any hard-required item → `needs-info` AND auto-drafted
Jira comment. Item #4 is informational-only (Kyle's call). Item #9
(logs) stays soft because pasted logs aren't always a separate field
when a HAR is attached. Items #8, #10 are conditional on the bug shape.

| # | Item | Tier | Heuristic | Notes |
|---|------|------|-----------|-------|
| 1 | Credentials (FA, QE user, or SSO) | **hard-required** | Presence of email pattern, `j####` FA ID, "UserID", "SSO", "QE User" | ASD tickets typically pre-satisfy this with FA ID + account. |
| 2 | URL | **hard-required** | `http(s)://` link in description | URL conveys the page the user was on → component scope. App# alone is not a substitute (App# tells you where the case was created; URL tells you where the user was when the bug occurred — these can differ during QE work). |
| 3 | App# / AppID | **hard-required** | `K0-[A-Z0-9]+-A-\d+` pattern, "App ID", "AppID", or URL containing `/app/` | The case code is the unique handle for Remote-Claude work and the primary log-search filter. |
| 4 | PO type / jurisdiction / product trigger | informational | State abbreviations (FL, NY, AK, etc.), "Trad IRA" / "Roth" / "NQ" / "SEP" / "SIMPLE", carrier name (Lincoln, NW, Corebridge, PacLife, etc.) | Never counted as `✗` toward severity. Flag absence as a soft note. |
| 5 | Steps to reproduce | **hard-required** | "Steps:" / "Reproduction:" / "To Reproduce:" header, OR numbered list with ≥3 items | — |
| 6 | Actual Behavior | **hard-required** | "Actual:" / "Actual Behavior" header | — |
| 7 | Expected Behavior | **hard-required** | "Expected:" / "Expected Behavior" header | — |
| 8 | HAR file | **hard-required when** 4xx/5xx mentioned | Attachment with `.har` extension; conditional on a 4xx/5xx error mention in description | If no error mentioned, item is N/A. |
| 9 | Logs | soft | Stack-trace pattern (regex: `at \w+\.\w+`, `Exception:`, `Error:`), pasted log block, or attachment | Flag missing only if the bug is a backend/exception failure and HAR is also absent. |
| 10 | Screenshots / recordings | **hard-required when** bug is UI-visible | Attachment with `image/*` or `video/*` MIME, or filenames ending `.png` `.jpg` `.gif` `.mp4` `.mov` `.webm` | Confluence guidance says "Include screenshots and screen recordings" — treat as hard-required by default. |

## Output format

```
QE diagnostic check — EJA-####
✓ 1. Credentials (<brief evidence>)
✓ 5. Steps to reproduce (<count> items)
✓ 7. Expected Behavior
⚠ 6. Actual Behavior — <reason for unclear>
✗ 3. App# / AppID — not found
✗ 8. HAR file — 500 error mentioned but no .har attached
✗ 10. Screenshots — none
Missing N, unclear M.
```

## Severity rules → effect on recommended state

Apply in order; first match wins. Item #4 is informational-only and
does not count toward any of these tallies. Item #9 is soft and only
counts when both a backend/exception failure is described AND no HAR
is attached.

1. **Any hard-required missing.** Any `✗` on a hard-required item
   (#1, #2, #3, #5, #6, #7, conditional-#8, conditional-#10) →
   recommend `needs-info` AND draft the auto-reporter-ask comment for
   posting to Jira.
2. **Soft-only missing.** `✗` only on item #9 (logs) → keep the
   existing category/state recommendation, but list in dev item's
   Open questions on promotion.
3. **All present or only `⚠ unclear`.** No effect on recommendation.

**Why this is strict:** the QE Confluence guidance lists each of
these items as required. The triage process exists to expedite
developer resolution by ensuring the bug brief contains everything
needed for diagnosis. Accepting incomplete filings sustains the gap;
posting a comment back to QE trains the source-of-data over time.

## Auto-drafted reporter ask (when `needs-info`)

When the rubric pushes the recommended state to `needs-info`, draft a
comment and post it to Jira on Kyle's confirmation. This is the one
case where `/triage` writes to Jira (see `SKILL.md` § "Jira write
boundary" for scope).

**Comment template (ADF):**

The comment must be posted in **ADF format**, not markdown. The
`mcp__plugin_atlassian_atlassian__addCommentToJiraIssue` markdown
parser does NOT render `[~accountid:...]` mention syntax — it
escapes the brackets as literal text and the mention silently fails
(no notification fires). Verified empirically 2026-05-10 (see memory:
`feedback_jira_adf_mentions.md`).

Use `contentFormat: "adf"` and pass the ADF document as a
JSON-serialized string in `commentBody`. Template structure:

```json
{
  "type": "doc",
  "version": 1,
  "content": [
    {
      "type": "paragraph",
      "content": [
        {
          "type": "mention",
          "attrs": {
            "id": "<reporter.accountId>",
            "text": "@<reporter.displayName>",
            "accessLevel": ""
          }
        },
        { "type": "text", "text": " — to triage, we need:" }
      ]
    },
    {
      "type": "bulletList",
      "content": [
        {
          "type": "listItem",
          "content": [
            { "type": "paragraph", "content": [{ "type": "text", "text": "<item>" }] }
          ]
        }
      ]
    },
    {
      "type": "paragraph",
      "content": [
        { "type": "text", "text": "Reference: " },
        {
          "type": "text",
          "text": "https://porchsoftware.atlassian.net/wiki/spaces/IKBS/pages/2440233030",
          "marks": [
            {
              "type": "link",
              "attrs": {
                "href": "https://porchsoftware.atlassian.net/wiki/spaces/IKBS/pages/2440233030"
              }
            }
          ]
        }
      ]
    }
  ]
}
```

Pull the reporter's `accountId` and `displayName` from the Jira ticket
fetch (`reporter.accountId`, `reporter.displayName`). The `mention`
node fires the notification; the `link` mark on the Reference URL
makes the Confluence link clickable. Add one `listItem` per missing
rubric item.

**Verification after post:** the response body should include
`<custom data-type="mention" data-id="id-0">@<Name></custom>` — that's
Atlassian's serialization of a successful mention element. If the
response body shows `\[\~accountid:...\]` (escaped brackets), the
mention failed and the comment must be re-posted in ADF.

**Concision rules** — Jira comments are scanned, not read. Keep them tight:

- Target under 50 words. Hard cap 100.
- One bullet per missing item. No "could you please" / "when you get a chance" / softeners.
- No restating what the bug is — the reporter knows.
- No explaining why each item is needed unless genuinely non-obvious. The reporter-facing name (from the table below) is enough.
- Drop the inline clarification suffix. If an item's name is too terse to be self-explanatory (rare), tighten the name in the table rather than padding the comment.
- Skip the trailing "thanks!" / "appreciate it!" sign-offs. Reference link covers tone.

**Good:**
```
[~accountid:712020:7367e531-f833-47cf-a994-01c243f7cae8] — to triage, we need:
- App number / AppID (from the URL)
- HAR file (the network capture for the error)
- Screenshots showing the failed state
Reference: https://porchsoftware.atlassian.net/wiki/spaces/IKBS/pages/2440233030
```

**Bad** (verbose, restates the bug, soft, generic ping):
```
Hi @QE! Thanks for filing this ticket about the License Check error. To help
us triage this issue, could you please provide the following additional
information when you get a chance? We need the App number / AppID which
should be available from the URL bar, a HAR file capturing the network
error so we can see the 500, and a screenshot showing the failed state
so we can confirm the visual symptom. Thanks so much!
```

**Posting flow:**

1. Show Kyle the rendered preview AND the ADF JSON alongside the QE
   check block. Kyle has been burned by silent mention failures; the
   raw ADF makes verification possible before posting.
2. Ask: "Post to Jira? (y/n/edit)". On `edit`, accept revised text,
   re-confirm.
3. On `y`, post via `mcp__plugin_atlassian_atlassian__addCommentToJiraIssue`
   with `contentFormat: "adf"` and the ADF JSON as a string in
   `commentBody`.
4. On `n`, leave the comment unposted; record the draft in the dev item
   on promotion (Open questions section) so Kyle can paste it later if
   he changes his mind.
5. After post, inspect the response body for the `<custom
   data-type="mention" ...>` marker confirming the mention rendered.
   If it shows escaped brackets, surface the failure to Kyle.

**Never post without explicit confirmation.** A Jira comment is visible
to the reporter, the team, and audit logs — auto-mode does not
authorize external-facing writes without a per-instance check.

**Item-name normalization for the comment:**

When the comment lists missing items, use these reporter-facing names
(not the internal rubric names):

| Rubric item | Comment label |
|---|---|
| #1 Credentials | "FA credentials (email/SSO UserID, or QE user)" |
| #2 URL | "URL" |
| #3 App# / AppID | "App number / AppID (from the URL)" |
| #4 PO type / jurisdiction / product trigger | "Trigger condition (PO type, jurisdiction, or product type)" |
| #5 Steps to reproduce | "Steps to reproduce (numbered, detailed)" |
| #6 Actual Behavior | "Actual Behavior" |
| #7 Expected Behavior | "Expected Behavior" |
| #8 HAR file | "HAR file (the network capture for the error)" |
| #9 Logs | "Logs (stack trace or pasted log block)" |
| #10 Screenshots / recordings | "Screenshots or screen recording showing the failed state" |

## Heuristic limitations

These are best-effort presence checks. Known cases where the rubric
under- or over-reports:

- **Inline behavior description.** Some QE tickets describe actual /
  expected behavior in prose without explicit headers. The heuristic
  flags this as `⚠ unclear`; Kyle confirms.
- **Screenshots embedded inline.** Markdown image links inside the
  description body don't always show up as ticket attachments. If the
  description references "see screenshot" but no attachment is found,
  flag as `⚠ unclear` not `✗`.
- **HAR not always needed.** A frontend rendering bug doesn't need a
  HAR even if the description mentions "500-line component" or other
  numeric coincidences. Heuristic conditions HAR on a 4xx/5xx pattern
  to reduce false-flagging.
- **ASD-tagged tickets** typically pre-satisfy #1 (credentials) and
  often #3 (App#) via the standard ASD shape. The rubric still
  applies; usually those rows are `✓` without extra work.

## Updating the rubric

When QE updates the Confluence page:

1. Re-fetch the page via `mcp__plugin_atlassian_atlassian__getConfluencePage`.
2. Diff against this rubric. New items, removed items, or changed
   wording all warrant updating the table here.
3. Update the "Last verified against Confluence" date at the top.
4. Commit the change with a message that names the source page.

If the page goes through major restructuring (e.g., new sections for
title format or priority handling), revisit the v1 scope decision —
extending the rubric beyond description-body diagnostics may be worth
it then.
