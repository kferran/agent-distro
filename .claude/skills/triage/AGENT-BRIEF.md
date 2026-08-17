# Writing Agent Briefs

When `/triage promote` creates a new dev item, the bottom of its **Context** section gets pre-filled with an **Agent Brief** block. The brief is the contract that Remote-Claude (or Kyle, for `ready-for-kyle` items) starts from.

The original Jira ticket is reference; the dev item brief is the working specification.

## Principles

### Durability over precision

The dev item may sit in drafting → queued for days before active execution. The codebase will change in the meantime. Write the brief so it stays useful even as files are renamed, moved, or refactored.

- **Do** describe interfaces, types, and behavioral contracts
- **Do** name specific types, function signatures, or config shapes that the agent should look for or modify
- **Don't** reference file paths — they go stale (callouts in Context for orientation are fine; load-bearing instructions in the brief are not)
- **Don't** reference line numbers
- **Don't** assume the current implementation structure will remain the same

### Behavioral, not procedural

Describe **what** the system should do, not **how** to implement it. Remote-Claude will explore the codebase fresh and make its own implementation decisions.

- **Good:** "When Owner = Annuitant, the Owner/Annuitant person must not be selectable as a Beneficiary at any Bene entry point (primary or contingent)"
- **Bad:** "Add a check at line 247 of BeneficiarySelector.tsx that hides the option"
- **Good:** "License Check error must include client residence-state mismatch detail in the error message body"
- **Bad:** "Modify the LicenseCheckError class to include a new field"

### Complete acceptance criteria

The agent needs to know when it's done. Every brief has concrete, testable acceptance criteria. Each criterion is independently verifiable.

- **Good:** "Validation runs symmetrically for single-annuitant and joint-annuitant inputs (same error class, same surfacing)"
- **Bad:** "Validation should work correctly"

### Explicit scope boundaries

State what is out of scope. This prevents the agent from gold-plating or making assumptions about adjacent features.

For ASD-derived briefs especially: the FA case that surfaced the bug is one example, not the whole spec. Be explicit about whether the fix is global or scoped to that case's specific conditions.

## Template

```markdown
## Agent Brief

**Category:** bug / enhancement / investigation
**Summary:** one-line description of what needs to happen

**Current behavior:**
Describe what happens now. For bugs, this is the broken behavior with the
specific reproduction conditions where known. For enhancements, this is
the status quo the feature builds on.

**Desired behavior:**
Describe what should happen after the work is complete. Be specific about
edge cases (joint vs single, all carriers vs specific carrier, all states
vs residence-state-only, etc.) and error conditions.

**Key interfaces:**
- `TypeName` or component name — what needs to change and why
- Relevant validation / submission / persistence boundary — what currently
  happens vs what should happen
- Config shape or feature flag if any new toggles are needed

**Acceptance criteria:**
- [ ] Specific, testable criterion 1
- [ ] Specific, testable criterion 2
- [ ] Specific, testable criterion 3

**Out of scope:**
- Adjacent feature that might seem related but is separate
- Specific conditions that the fix should NOT cover
```

## Worked examples

### Bug brief (ASD-derived)

```markdown
## Agent Brief

**Category:** bug
**Summary:** License Check error message does not surface client-residence-state mismatch

**Current behavior:**
When an FA's license-check fails specifically because the FA is unlicensed
in the client's residence state, the error message lumps it into a generic
"license/training error" without naming the residence state. UAT-reproducible
with FA `j34933` + account `948-15211` (FL); also AK/AK.

**Desired behavior:**
When the failure mode is residence-state-specific, the error message must
name the residence state explicitly so the FA knows which jurisdiction
gap to address. Other license-check failure modes (training, generic
unlicensed) keep their existing messaging.

**Key interfaces:**
- The license-check result type that flows from the validation layer to
  the UI surfacing — needs to carry enough context to distinguish the
  residence-state-specific failure from generic ones
- The error message rendering layer that consumes that result

**Acceptance criteria:**
- [ ] Residence-state failures produce a message naming the state
- [ ] Generic license/training failures keep their existing messaging unchanged
- [ ] FL/FL and AK/AK reproductions confirmed fixed
- [ ] Adjacent recent work `credential-check-skip-custodial` not regressed

**Out of scope:**
- Restructuring the license-check pipeline itself
- Changing which states require licensure
- Surfacing this distinction in any non-error UI (analytics, logs, etc.)
```

### Enhancement brief

```markdown
## Agent Brief

**Category:** enhancement
**Summary:** Block Owner/Annuitant from being selectable as a Beneficiary when Owner = Annuitant

**Current behavior:**
The Beneficiary selector lets the user pick the Owner/Annuitant person as
a Bene entry, even when Owner = Annuitant. This produces an invalid
distribution path (the same person can't be both annuitant and beneficiary
in this scenario).

**Desired behavior:**
When Owner = Annuitant, that person is excluded from the selectable list
in every Bene entry point (Primary Bene, Contingent Bene). Other Bene
entry behavior unchanged.

**Key interfaces:**
- The Bene selector data source — needs to be aware of the Owner = Annuitant
  condition
- All Bene entry points (Primary, Contingent) consume the same selector

**Acceptance criteria:**
- [ ] Owner/Annuitant person not selectable in Primary Bene when Owner = Annuitant
- [ ] Same for Contingent Bene
- [ ] Behavior unchanged when Owner ≠ Annuitant
- [ ] Existing Bene entries created before this change are not retroactively invalidated

**Out of scope:**
- Validation of Bene entries created prior to this rule
- Changes to who CAN be a Bene in any other scenario
- UX treatment beyond exclusion (no error toast, no explanation tooltip — just absence)
```

### Investigation brief

```markdown
## Agent Brief

**Category:** investigation
**Summary:** Verify NPN flow end-to-end from EDJ launch through participant storage to AppSub form-stamping

**Current behavior:**
Three distinct EDJ entry points each write NPN data; one downstream
form-stamping consumer reads it. Topology is documented but not verified
under real traffic. Read-only audit only.

**Desired behavior:**
A documented trace, per audit subject, of how NPN flows from each entry
point through participant storage to the AppSub form-stamper. Discrepancies
flagged but not fixed in this work item.

**Audit subjects:**
- K1-BYKAQ (joint, FA Johnny R)
- K1-C9M8X (single, FA Johnny R)

Same FA across both is intentional — provides an NPN-consistency cross-check.

**Acceptance criteria:**
- [ ] Phase 0: case-code lookup confirms both subjects in Playground (`porchInstanceId == "K1"`)
- [ ] Phase 1: sanity check — both subjects have NPN data at each layer
- [ ] Phase 2: timeline traces from launch to AppSub for each
- [ ] Phase 3: ingress confirms which entry point each came through
- [ ] Phase 4: sink confirms what AppSub form-stamping received

**Out of scope:**
- Any code changes
- Production data (Playground only)
- Other case codes
- Carriers other than what these subjects route to
```

## Bad brief — what to avoid

```markdown
## Agent Brief

**Summary:** Fix the License Check thing

**What to do:**
The license check is broken when the FA can't service the client's state.
Look at the validation code and fix the message.

**Files to change:**
- src/licensing/check.ts (line 247)
- src/types.ts (LicenseCheckResult)
```

This is bad because:
- No category
- Vague summary
- References file paths and line numbers that will go stale
- No acceptance criteria
- No reproduction conditions
- No scope boundary (does it apply to all license failures, or only residence-state failures?)
- No mention of related prior work to coordinate with
