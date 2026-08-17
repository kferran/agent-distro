---
name: ns-secrets-scan
description: Weekly logging-hygiene sweep — Kusto-query the non-prod Ultron log tables for code that emits secrets to logs (client_secret, bearer/JWT, api_key, password=, private_key). A hit is a LOGGING DEFECT that would leak real credentials in prod (non-prod = the canary); reported with the emitting code path to fix. Report-only. Night-shift process (Sunday, Kusto-gated); runnable solo. Triggers — "/ns-secrets-scan".
---

# /ns-secrets-scan — logging-hygiene (secrets-in-logs) sweep

Standing detection for **code that emits secrets into application logs** — a logging-hygiene **DEFECT**. Origin: run 39 (2026-07-08) a P7 Kusto sweep *incidentally* found a live `client_secret` + bearer token in outbound carrier-submission log bodies — found by luck, not a process. This makes it deterministic + weekly.

**FRAMING (Kyle, 2026-07-08 — this is what the finding means):** a secret in a **non-prod** log is **NOT a breach** — non-prod credentials are low-value and the cluster this scans (`ultron-nonprod`) is Dev/Playground/UAT only. But a secret in ANY log means **the code writes secrets to logs**, which would leak *real* credentials in production. So non-prod is the observable **canary**; a hit is a **code defect to FIX (scrub/redact the log-emit)**, NOT an incident to rotate. The deliverable is the **emitting code path**, so the fix is actionable — never "rotate this non-prod cred."

**Report-only** — never remediates, never edits code, never posts to Jira. Redacts the secret values in the report (pattern + location + count, NOT the secret itself).

## Cadence + gating

Night-shift process, **Sunday-only** (`dow===7`), **Kusto-gated** (skipped when `args.mcp.kusto === false` — the #1 auth precheck). Runnable solo any time: `/ns-secrets-scan`.

## Procedure

1. Resolve `LOCAL` (invocation, else `TZ=America/Denver date +%Y-%m-%d`). Initialize the Kusto MCP connection: cluster `https://ultron-nonprod.centralus.kusto.windows.net`, db `validation` (K0=Dev, K1=Playground, K2=UAT via `porchInstanceId`). If Kusto is unreachable, write the artifact with `status: failed` + a re-auth note and stop (never fake results).
2. Over the **trailing 7 days**, scan the log/trace tables' message + body/customDimensions fields for secret patterns (case-insensitive), the outbound-integration services first (`edj-worker`, `dtcc-worker` — where the run-39 leak was), then broaden:
   - `client_secret` / `client_secret=` / `"client_secret"`
   - bearer / JWT: `bearer ey`, `authorization: bearer`, `eyJ` (JWT header prefix)
   - `api[_-]?key`, `x-api-key`
   - `password=`, `pwd=`, `"password"`
   - `private_key`, `BEGIN RSA`, `BEGIN PRIVATE KEY`
   - `aws_secret`, `secret_access_key`
   Count matches grouped by `service.name` + environment + the field, with the earliest/latest timestamp. **Pull only enough to characterize** — a redacted 8-char context window around the match, never the full secret.
3. Classify each hit: **confirmed live secret** (a real token/key value present in the log) vs **benign** (a field literally named `client_secret` with an empty/`***`/masked value, a doc/schema string, or a test placeholder). Only confirmed-live hits are decision-grade. **For each confirmed-live hit, IDENTIFY THE EMITTING CODE PATH** — trace the log-write statement in `~/code/worktrees/main` (read-only) that puts the secret into the log. That code path is the fix target (scrub/redact the emit); the finding is a **logging defect**, and the non-prod credential itself is not the thing to act on.

## Output

- Artifact `00 Inbox/<LOCAL>-ns/secretsScan.md` (frontmatter `process: secretsScan`, `status: complete|failed`, `needs_kyle:` list). Body: per confirmed hit — pattern class, `service.name` + env, count, first/last seen, the log source (table + a redacted context snippet), and the likely emitting code path if quickly identifiable in `~/code/worktrees/main` (read-only). Benign matches summarized as a count only.
- `needs_kyle:` — any **confirmed-live** hit → `⚠️ Logging defect: <service.name> emits <pattern> to logs at <emitting code path:line> (<count>, <env>) — scrub/redact the emit (this code would leak real credentials in prod; the non-prod cred is not the concern)`. Lead with the CODE PATH so it's a spawn-ready fix, not just an alert. Clean run → empty `needs_kyle` (per-process status still ✅). A confirmed hit is **always decision-grade** — make noise (Kyle: worth tracking + surfacing loudly).

## Discipline
- Report-only: no code edits, no Jira, no log deletion, honor `Confidential/`.
- **Redact in the vault**: the report must not itself become a secret store — show the pattern + location + count, never the full credential value. (The vault is a private repo, but a logged secret written verbatim into the vault widens exposure.)
- Nothing committed/pushed (night-shift rule).

## Future — broaden to a general "shouldn't-reach-prod" logging review (Kyle, 2026-07-08)
Secrets are the first class; the intended direction is a general **production-logging-hygiene review** — additional elements that should never make it to prod logs, each with the same "non-prod = canary, fix the emit" framing:
- **PII / sensitive personal data** — SSN/TIN, full DOB, account numbers, addresses in log bodies.
- **Full request/response payloads** — whole ACORD XML / carrier payloads / customer records logged verbatim (over-logging, not just secrets).
- **Internal identifiers that shouldn't leak** — raw tokens, session IDs, internal service URLs/keys.
- **Verbose debug logging left on** — `Debug`/`Trace` level emits, stack traces with data, that shouldn't ship at prod log levels.
When built, keep the pattern set + severity calibration in one place and let this skill (or a renamed `ns-logging-review`) run the broadened sweep. Design pass before build. Not scheduled yet — captured so it isn't lost.

## Solo run
`/ns-secrets-scan` — `LOCAL` defaults to today; same Kusto query + artifact. Degrades gracefully if Kusto isn't authorized (writes `status: failed` + re-auth note).
