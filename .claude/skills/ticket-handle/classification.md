# Ticket classification — true type, not raw issuetype

The filed Jira issuetype is unreliable (a "Bug" can be a Story — EJA-2877; a "Story" can be a defect — EJA-3569). Resolve the REAL type before routing.

## Procedure

1. **Cache first (no re-diagnosis).** If `00 Inbox/<LOCAL>-ns/clusterB.md` (or the most recent prior `*-ns/clusterB.md`) has a diagnosis row for the key, use its disposition (bug / product-AC / data-gap / change-order / story-relabel). Don't re-diagnose what the night shift already cached.
2. **Else classify from Jira** (read-only fetch — summary, description, issuetype, status, acceptance criteria, issuelinks, children-if-epic).
3. **Ambiguous → `needs-classification`** — never guess; surface for a human call (mirrors the diagnosis "diagnosed but unscored → manual decide" rule).

## Types

| Type | What it is | Routes to |
|---|---|---|
| **bug-code** | a defect with a plausible code fix (Bug, or a "Story" that's really a defect) | bug-code treatment (RCA-lift → mirror-resolve → spawn) |
| **bug-gapped** | a real defect whose fix is NOT code — data (PPFA), config (Schema/Alkhema form-tool JSON), or needs a product decision first | owner-handoff draft |
| **story** | net-new feature/behavior work | scope-to-dev-item |
| **epic** | a parent with children (fetch children via `ultron:jira-context`) | recurse + split |
| **change-order** | a batch of form add/remove/replace/re-version stories (a carrier forms change order) | PO-ready batch plan |
| **product-AC** | an acceptance-criteria / product-rule question, not an eng defect | product-decision brief |
| **non-actionable** | works-as-designed, duplicate, or already-fixed/merged | close/verify recommendation |

## Signals

- **epic** — issuetype Epic, OR has children (`parent = <KEY>` returns rows), OR is an umbrella that `relates to` other epics (e.g. EJA-3599 "Change Order Batch 1" relates to EJA-3602).
- **change-order** — summary/description names a carrier "change order" / "forms" batch; children are form add/remove/replace/re-version stories. A change-order is often itself an epic — classify the parent `epic`, and its non-code children collect into the change-order PO-plan.
- **bug-code vs bug-gapped** — is there a plausible in-repo code fix? If the fix is in PPFA product data, Schema/Alkhema form-tool config, or needs a product rule defined → `bug-gapped`. (The EJA/ARCH **mirror lookup happens in-treatment** — see `treatments.md` › mirror-resolution — not at classify; classify only decides code-fixable-vs-gapped.)
- **product-AC** — the ticket asks "what should the rule be?" not "the code is wrong."
- **non-actionable** — a merged PR references the key, the mirror is Done/deployed and the repro no longer reproduces, or it's a duplicate.
