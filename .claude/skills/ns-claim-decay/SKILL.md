---
name: ns-claim-decay
description: Vault-internal claim-decay sweep — cross-checks recorded claims against reality (spec status-vs-review_status flags, active dev items vs live worktrees/tmux, wiki In-flight entries vs item state) and flags mismatches, report-only. Night-shift process P15, nightly, no MCP; runnable solo. Triggers — "/ns-claim-decay".
allowed-tools: Read, Write, Glob, Grep, Bash
---

# ns-claim-decay

Recorded claims in the vault don't decay on their own — spec flags say "unbuilt" after the work ships, items say `active` after the worktree dies, In-flight lines outlive their items. This sweep cross-checks the cheap, vault-internal claim surfaces against reality every night and FLAGS mismatches. **Report-only — never auto-fix** (the mismatch might be the reality side; Kyle or the owning skill corrects the record). Night-shift process **P15**; also runnable on demand.

_Origin: the 2026-07-07 enhancement audit — 4 of 5 audit items and 3 of 4 ticket candidates were stale claims (shipped work flagged pending-review, drafts pointing at fixed code, "dead" labels on an active project). This is the re-baseline discipline applied to the vault's own meta-layer._

## Invocation

Invoked by the `night-shift-fanout` workflow as `/ns-claim-decay for LOCAL=<date>` (nightly, Drift wave, no MCP guard). Runnable solo: `/ns-claim-decay`.

## Artifact contract (PRIMARY OUTPUT)

Resolve `LOCAL` (from the invocation, else `TZ=America/Denver date +%Y-%m-%d`). Write `00 Inbox/<LOCAL>-ns/P15.md` with frontmatter `process: P15`, `status: complete|failed`, an optional `needs_kyle:` list, and a body = the report-section text. Create the dir if absent (`mkdir -p "00 Inbox/<LOCAL>-ns"`). Do NOT commit/push; honor Confidential/ strict mode (never read/scan `Confidential/`).

## Checks (all cheap — grep/fs/tmux only, no MCP, no code-worktree reads)

**CHECK 1 — Spec-flag mismatches.** For every `99 Meta/specs/*.md`, compare `status:` and `review_status:` frontmatter. The live status vocabulary is FREEFORM (`draft-for-review`, `✅ shipped 2026-06-13 (…)`, `design-approved`…), so match by SUBSTRING, case-insensitive — never assume an enum. Flag: `status` containing `implemented` or `shipped` while `review_status` is `pending-review` or `draft` (shipped work still flagged for review — the friction-loop-design class); and the reverse — `review_status: shipped` while `status` starts with `draft`/`plan`/`proposed` AND the file has no `shipped:`/`implemented:` date field. Report `file — status X vs review_status Y`.

**CHECK 2 — Active dev items vs live worktrees.** For every `00 Inbox/*.md` with `status: active`: reality probes — does the `worktree_path` dir exist (`test -d`, expand `~`), and does a matching tmux session appear in `tmux ls`? MATCH KEY (stated because filename ≠ slug ≠ branch for several items): a session/dir matches an item if its name equals or contains ANY of — the `slug:` frontmatter, the filename minus date-prefix/extension, the `branch` basename (strip a `fe/` prefix), or the `worktree_path` basename. BOTH probes absent → flag `active-but-no-worktree` (status likely rotted, or torn down without closing the item). **⚠️ SCOPE THE WORKTREE PROBE TO CODE ITEMS (2026-07-21 — fixes a recurring false-positive):** a `task_type: research` or `task_type: ops` item **legitimately has no `worktree_path`** — those run in the shared checkout / a `cb:` window, not a per-slug worktree — so the `active-but-no-worktree` flag does NOT apply to them. For research/ops items, skip that flag and instead flag ONLY if the item is **stale (last_synced / most-recent Log >14d)** AND has no matching live `cb` research window — i.e. an abandoned research item, not merely a worktree-less one. (Origin: the 2026-07-21 shift flagged 8 research-type items as "missing worktree_path" — all expected, all noise.) **DISPOSITION (2026-07-08 #5b — make the flag actionable without MCP):** for each such item read its OWN file (no MCP) and propose a likely disposition from vault-internal signals — most-recent `## Log` entry / `last_synced` **stale >14d** → _"likely stale-active — verify closeout (archived or shipped since?)"_; **recent** activity but worktree gone → _"worktree torn down while still active — re-confirm or re-spawn"_. Always append the guard _"verify the item's OWN residual before archiving — parent-Done ≠ item-done"_. The disposition is a PROPOSAL surfaced with the flag; still report-only, never an auto-status-change. One probe present → no flag (parked/detached is normal). Also the reverse sweep: for each live tmux session EXCEPT the orchestrator host (`PorchVault` — any session named as a `host_session` in the scheduled-tasks-log manifest is host, never flagged), find a matching item at ANY status: no item at all → flag `worktree-without-item` (untracked work); a matching item that merely lacks `status:` frontmatter → flag `item-missing-status` (tracked, but the lifecycle field rotted — do NOT label it untracked).

**CHECK 3 — In-flight integrity.** For every `02 Areas/platform/*/wiki.md` `## In flight` entry: resolve the `[[link]]` target. Flag when the target file is missing, lives in `02 Areas/development/archive/items/`, or carries `status: archived|done` — an In-flight line that outlived its item ("removed on completion" per the section contract).

**CHECK 4 — Memory-corpus health.** Run `scripts/cerebro/cb-memcheck --flags` and put its output lines in the body under a `Memory corpus` heading (it prints `Memory corpus: clear` when there is nothing, which is the expected steady state). It is read-only and needs no MCP. It flags **regressions only** — an index hook over the 100-char budget, an entry missing from `MEMORY.md`, an index line pointing at a file that does not exist, a dead `[[link]]` — so once the index is ratified any output means something changed *that night*. **Never edit `.claude/memory/` from this pass**, not even the index: memory is Kyle's and a wrong deletion is silent and unrecoverable. The deeper judgment pass (is this entry still earning its context slot?) is the monthly `cb-memcheck --report` + `--pairs` read, not this one.

**Bounds:** cap the report at 10 flags/check (+N more); a check that errors is noted `check failed (<reason>)` and the others still run (failure-isolated). All clear → body is "Claim decay: clear" (one line).

## Reporting

- Flags land in the artifact BODY, one line each with the file and the mismatch.
- `needs_kyle:` gets ONE summary line only when something implies live risk: any CHECK-2 flag (lost/untracked work), or ≥3 total flags. Otherwise leave `needs_kyle:` empty — routine metadata rot is body-visibility, not a decision demand (Needs-Kyle gate).
- Do NOT auto-correct any record. The fix belongs to the owning surface (Kyle, /eod, or the skill that wrote the claim). Repeat flags across runs are expected until fixed — the friction-loop nudge in FINALIZE will tag persistent ones.

## Solo run

Same behavior; LOCAL defaults to today. Still writes `00 Inbox/<LOCAL>-ns/P15.md`.
