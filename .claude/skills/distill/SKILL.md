---
name: distill
description: Integrate the findings in landed X-Man reports into the vault pages that own them — refined-not-appended, in place, into one reviewable `distill:` commit with a before/after change summary. The judgment half of auto-distillation; `cb-distill` is the mechanical half (queue, write gate, summary check, commit). Invoked by `/eod` when `cb-distill --queue` is non-empty, or on demand as "distil the landed reports".
---

# distill — land the prose, not just the file

`cb-land` files a finished research/ops report into `00 Inbox/` at a path computed
before the agent ever ran. That moves the backlog; it does not drain it. **A landed
report nobody distils is still an unread report — it has just moved somewhere
better.** Your job is the other half: take what the report actually found and put it
into the page that owns it, written as that page's prose.

You are an `--ops` X-Man. You write the vault within the scope below, you never
commit by hand, and you never push.

**Split of labour:** `scripts/cerebro/cb-distill` owns the queue, the write gate, the
summary-completeness check and the commit. You own every decision — which page owns a
finding, what the integrated prose says, and what to decline. Anything mechanical,
call the script for; do not reimplement it.

## Guardrails (non-negotiable)

- **Never `People/`, never `Confidential/`.** A finding whose home is a person's file
  is a decline, always. Interpersonal content is unfalsifiable later and its write
  shape ("integrate into existing prose, never Update: lines") is a judgment no
  automated pass should make.
- **Never a rule surface** — `CLAUDE.md`, `profile.md`, `personality.md`, `hot.md`,
  `board.md`. A self-modifying ruleset is a separate decision nobody has taken.
- **Never `git commit` or `git add` yourself, and never push.** `cb-distill --commit`
  is the only way this work lands. It refuses if your summary is incomplete, which is
  the point.
- **Decline rather than guess.** An ambiguous destination is a legitimate outcome and
  costs nothing — it goes in the summary and `/ingest` picks it up. A confident write
  into the wrong page costs a reader who believes it.

## Steps

### 1. Read the queue

```bash
scripts/cerebro/cb-distill --queue      # one `slug<TAB>landed-path` line per pending report
```

Each line names a task slug and the `00 Inbox/` file `cb-land` wrote. Read the landed
file — it is the report, with provenance stamped into its frontmatter
(`landed_from`, `landed_slug`, `landed_at`). Empty output means nothing is pending;
stop.

### 2. Per finding, decide the destination

Not per report — a report often carries several findings with different homes, and
one of them may be a decline while the others land.

`02 Areas/platform/CLAUDE.md` holds the boundary rule that decides this: **could the
night shift's capability-drift pass confirm or refute the claim from the code?** Yes
(a `path:line`, a symbol, a flow) → a capability doc under
`03 Resources/{ultron,ironman}/capabilities/`. No (the load-bearing part is judgment,
a diagnosis, a trap) → the domain wiki, `02 Areas/platform/<domain>/wiki.md` (the five
are `ownership` · `forms` · `products` · `case-flow` · `carriers`). Spans domains →
`03 Resources/technical/`. An index or a spine → the platform hub. Read that file
rather than working from this summary of it; it also owns the write shape and the cap
in step 3.

**A mixed claim splits — it does not pick a home.** The seam goes in the capability
doc, the one-line trap in the domain wiki, linking out. Two writes, both reported.

Where you may write — check every destination before you touch it:

```bash
scripts/cerebro/cb-distill --check-path "03 Resources/ultron/capabilities/capability-x.md"
```

Exit 0 means write; exit 2 means the path is refused and the finding is a decline.
The gate is the shared never-touch list (`scripts/cerebro/lib/denylist.sh`) plus an
allowlist of `03 Resources/`, `01 Projects/`, `02 Areas/platform/`,
`02 Areas/development/items/`.

⚠️ A `CLAUDE.md` is refused at **every** depth, including
`02 Areas/platform/CLAUDE.md` and `03 Resources/CLAUDE.md` — those are the conventions
files that load when an agent works in that directory, so they are rule surfaces, not
pages. Read them; never write them.

### 3. Write it in place, refined not appended

**This is the part that is not appending.** These pages are refined: integrate the
finding into the entry that already covers the subject, restructure the section when
the new information exposes a better organization, and when a finding *corrects* an
existing claim, edit that claim and say what it previously said — never write a second
bullet twenty lines below the first. Append-only was considered for this pass and
rejected 2026-08-14 — it produces exactly the accretion the convention exists to
prevent.

`02 Areas/platform/CLAUDE.md` is the rule, and two of its clauses bind you directly:

- **A domain wiki has two sections with opposite rules.** `## Knowledge` is refined,
  never appended. `## In flight` is a generated work register — one line per active
  dev item, added by `dispatch` and removed by `/ingest`. **Never write to
  `## In flight`;** it does not travel with the Knowledge half.
- **The 12-entry cap on `## Knowledge`, per domain.** Count the entries before you
  write. At the thirteenth you do not add a thirteenth: you **merge two existing
  entries, or promote one out** — to a capability doc or a `03 Resources/technical/`
  page — as part of the same edit, and you report that merge or promotion in the
  summary like any other rewrite, with its before and after. The cap is what makes
  "refined" enforceable; without it, "integrate where it fits" degrades into "append
  at the end" every time. Three domains already exceed it (`case-flow`, `forms`,
  `ownership` as of 2026-08-10), so a write to one of those merges as it goes — but
  do **not** launch a retroactive compaction sweep across the corpus, which is
  separate, Kyle-approved work.

Keep provenance. A trailing `(EJA-3663, PR #2557 merged 2026-07-28.)` is how a claim
gets re-verified later; what is forbidden is accumulation, not citation.

Write like the page, not like a report. The reader is Kyle six weeks from now with no
memory of the X-Man run — no "the investigation found", no dated update lines, no
coined shorthand for a failure mode. Say the mechanism in a sentence.

### 4. Write the change summary — it IS the deliverable

`00 Inbox/<LOCAL>-distill-summary.md`, where `<LOCAL>` is Kyle's Mountain-time date
(`scripts/cerebro/cb-distill --queue` and the commit both use it; the server clock is
UTC and rolls over during his evening).

Kyle reads the summary, not the diff. It is also the whole safety argument for
rewriting prose in place: a bad integration has to be visible here without opening
the diff.

**The entry form is checked, so write it exactly.** One entry per write, on one
line, carrying the destination as `file:line` plus a `before:` and an `after:`:

```markdown
- `<slug>` → `03 Resources/ultron/capabilities/forms.md:41` — before: "<the prose that was there, verbatim>" after: "<the prose now, verbatim>" why: <this page and not another>
```

`cb-distill --commit` reads that line: the path, `before:` and `after:` all have to
be on it. A path with no before/after behind it reports nothing, so the check
refuses it — the prose is the deliverable, and the path is only its address.

**Every queued report needs a line, whether you wrote for it or not.** The commit
retires the whole queue, so a report you leave unmentioned is written off unread —
name it by slug or by its `00 Inbox/` path. Then a `## Declined` section: every
finding you did not write, with its reason (`People/`, ambiguous between two pages,
outside the allowlist, needs a decision). `/ingest` picks those up, so a decline is
routed, not dropped. Declining is the only way to drop something; silence is not.

### 5. Commit through the script

```bash
scripts/cerebro/cb-distill --commit
```

It derives what actually changed from git — not from your summary — comparing
against the dirty set recorded when the pass was scaffolded, so what it holds you to
is what *this pass* wrote. It refuses, and leaves the tree alone, when:

- **a file you changed has no before/after entry.** Write the entry, with the prose.
  ⚠️ Pasting the path into the summary is not the fix and will not satisfy the check:
  a path with no prose behind it makes an unreviewable rewrite look reported. If a
  named file is not one of yours, do not adopt it — say so and leave it dirty.
- **a queued report is not named anywhere.** Write it up or decline it by name.
- **the pass wrote outside its roots** — `People/`, a `CLAUDE.md`, anything the
  allowlist does not cover. That write stays in the tree; it is not reverted and not
  committed. Tell Kyle what you were trying to do.

A file the fleet regenerates on a timer — `board.md`, `hot.md`, `magneto.md` — is
different: it prints as a `note —` line, not a refusal, because its own writer changed
it, not you. Leave those alone; you may not write them either.

On success it stages the exact changed paths plus the summary, makes one
`distill: <LOCAL> — N findings into M files` commit, and marks each source task
distilled. Nothing is pushed.

## Activation

**`/eod` — one trigger, and only one.** Step 6.13 runs `cb-distill --queue` and
scaffolds this pass when the queue is non-empty; Step 7 spawns it *after* eod's
own auto-commit, so the prose you rewrite cannot be swept into that commit
instead of your `distill:` one. `/eod` is the surface whose local
commits Kyle already diffs in the morning, which is exactly the review-after model
this pass depends on. It is deliberately **not** on the night shift as well: two
schedulers on one job is the duplicate-scheduler pattern at the top of
`02 Areas/Engineering-Work/scheduled-tasks-log.md`, and it is not on `cb-watch`
either — a pass that costs model turns does not belong in a 30-second daemon loop.

On demand: "distil the landed reports", or `cb-distill --run` to scaffold the ops
task and print its spawn line.
