#!/usr/bin/env bats
# cb-distill — the mechanical half of auto-distillation: the write gate, the
# queue, and the commit that is only allowed to happen once the change summary
# accounts for everything that changed.
#
# The refusals carry the weight here. This script rewrites vault prose IN PLACE
# and commits it, and §7's argument for why that is safe rests entirely on the
# summary being complete — so the tests that matter most are the ones proving
# `--commit` refuses an incomplete summary and never sweeps up work that is not
# the distiller's.

setup() {
  # HOME thrown away as defense-in-depth: the vault default is "$HOME/vault",
  # and if VAULT_DIR were ever dropped the fallback must not be Kyle's vault.
  export HOME="$BATS_TEST_TMPDIR/home"; mkdir -p "$HOME"
  export CB_HOME="$BATS_TEST_TMPDIR/.cerebro"; mkdir -p "$CB_HOME/tasks" "$CB_HOME/logs"
  export VAULT_DIR="$BATS_TEST_TMPDIR/vault"
  mkdir -p "$VAULT_DIR/00 Inbox" "$VAULT_DIR/03 Resources" \
           "$VAULT_DIR/01 Projects" "$VAULT_DIR/02 Areas/development/items" "$VAULT_DIR/People"
  git -C "$VAULT_DIR" init -q 2>/dev/null || true
  git -C "$VAULT_DIR" config user.email t@t; git -C "$VAULT_DIR" config user.name t
  printf 'seed\n' > "$VAULT_DIR/seed.md"
  printf '# Wiki\n\nOriginal claim.\n' > "$VAULT_DIR/03 Resources/wiki.md"
  git -C "$VAULT_DIR" add -A >/dev/null; git -C "$VAULT_DIR" commit -qm seed >/dev/null
  LOCAL="$(TZ=America/Denver date +%F)"
  SUMMARY="$VAULT_DIR/00 Inbox/$LOCAL-distill-summary.md"
}

# mk_landed SLUG — a task cb-land has already filed, awaiting distillation.
mk_landed() {
  local slug="$1"; local td="$CB_HOME/tasks/$slug"; mkdir -p "$td"
  printf 'kind=research\nsession=%s\n' "$slug" > "$td/meta"
  printf '00 Inbox/2026-01-02-research-%s.md\n' "$slug" > "$td/landed"
}

# mk_summary <line...> — the change summary the distilling agent writes.
mk_summary() { printf '# Distill summary\n\n'; for l in "$@"; do printf -- '- %s\n' "$l"; done; }

# --- --check-path: the write gate -------------------------------------------

@test "--check-path allows the roots §7 marks ✅" {
  run scripts/cerebro/cb-distill --check-path "03 Resources/ultron/capabilities/capability-x.md"
  [ "$status" -eq 0 ]
  run scripts/cerebro/cb-distill --check-path "01 Projects/edj-annuities-phase2/notes.md"
  [ "$status" -eq 0 ]
  run scripts/cerebro/cb-distill --check-path "02 Areas/development/items/slug.md"
  [ "$status" -eq 0 ]
}

# §7's table row "`03 Resources/` domain wikis, capability docs" misprefixes half
# of itself: the five domain wikis it calls the main distillation target live
# under 02 Areas/platform/, which is why §7 also names that directory's CLAUDE.md
# as the governing write-shape rule.
@test "--check-path allows the platform domain wikis — but only that subtree of 02 Areas" {
  run scripts/cerebro/cb-distill --check-path "02 Areas/platform/forms/wiki.md"
  [ "$status" -eq 0 ]
  run scripts/cerebro/cb-distill --check-path "02 Areas/Org-Performance/notes.md"
  [ "$status" -eq 2 ]
  [[ "$output" == *"outside the distiller's roots"* ]]
  run scripts/cerebro/cb-distill --check-path "02 Areas/Engineering-Work/scheduled-tasks-log.md"
  [ "$status" -eq 2 ]
}

# A directory CLAUDE.md is a rule surface, not a page — it is the conventions
# file that loads when an agent works there, so rewriting one silently changes
# how every later agent behaves. The root-only match left all three of these
# inside an allowed root and writable.
@test "--check-path refuses a CLAUDE.md at ANY depth, inside an allowed root" {
  run scripts/cerebro/cb-distill --check-path "03 Resources/CLAUDE.md"
  [ "$status" -eq 2 ]
  [[ "$output" == *"never-touch list"* ]]
  run scripts/cerebro/cb-distill --check-path "02 Areas/platform/CLAUDE.md"
  [ "$status" -eq 2 ]
  run scripts/cerebro/cb-distill --check-path "02 Areas/development/items/CLAUDE.md"
  [ "$status" -eq 2 ]
  run scripts/cerebro/cb-distill --check-path "01 Projects/edj-annuities-phase2/CLAUDE.md"
  [ "$status" -eq 2 ]
  # outside the allowlist as well, so this one was already refused — pinned so a
  # future widening of `02 Areas/development/` cannot quietly open it
  run scripts/cerebro/cb-distill --check-path "02 Areas/development/CLAUDE.md"
  [ "$status" -eq 2 ]
}

# --- the shared denylist itself ----------------------------------------------
# Tested at the lib, not only through cb-distill: `cb-ingest` calls the same
# function, so a regression here would reopen the hole in both writers at once.

@test "cb_is_forbidden refuses a CLAUDE.md at any depth, and still refuses the root one" {
  source scripts/cerebro/lib/denylist.sh
  for p in "CLAUDE.md" "03 Resources/CLAUDE.md" "02 Areas/platform/CLAUDE.md" \
           "02 Areas/development/CLAUDE.md" "a/b/c/CLAUDE.md"; do
    cb_is_forbidden "$p" || { echo "not refused: $p"; false; }
  done
}

@test "cb_is_forbidden keeps every case it carried before the CLAUDE.md widening" {
  source scripts/cerebro/lib/denylist.sh
  for p in "profile.md" "personality.md" "hot.md" "board.md" "magneto.md" \
           ".claude/settings.json" "Confidential/x.md" "People/someone.md" \
           ".git/config" "scripts/cerebro/cb-distill" "/tmp/x.md" "../x.md"; do
    cb_is_forbidden "$p" || { echo "not refused: $p"; false; }
  done
}

@test "cb_is_forbidden still allows an ordinary page — it is a denylist, not an allowlist" {
  source scripts/cerebro/lib/denylist.sh
  for p in "03 Resources/wiki.md" "02 Areas/platform/forms/wiki.md" \
           "01 Projects/edj/notes.md" "00 Inbox/x.md" "claude.md" "MY-CLAUDE.md"; do
    ! cb_is_forbidden "$p" || { echo "wrongly refused: $p"; false; }
  done
}

@test "--check-path refuses People/ — interpersonally sensitive, never auto-written" {
  run scripts/cerebro/cb-distill --check-path "People/someone.md"
  [ "$status" -eq 2 ]
  [[ "$output" == *"never-touch list"* ]]
}

@test "--check-path refuses the rule surfaces" {
  for p in CLAUDE.md profile.md personality.md hot.md board.md; do
    run scripts/cerebro/cb-distill --check-path "$p"
    [ "$status" -eq 2 ]
  done
}

@test "--check-path refuses scripts/, .claude/ and Confidential/" {
  run scripts/cerebro/cb-distill --check-path "scripts/cerebro/cb-distill"
  [ "$status" -eq 2 ]
  run scripts/cerebro/cb-distill --check-path ".claude/settings.json"
  [ "$status" -eq 2 ]
  run scripts/cerebro/cb-distill --check-path "Confidential/comp.md"
  [ "$status" -eq 2 ]
}

@test "--check-path refuses traversal and absolute paths" {
  run scripts/cerebro/cb-distill --check-path "../x.md"
  [ "$status" -eq 2 ]
  run scripts/cerebro/cb-distill --check-path "/tmp/x.md"
  [ "$status" -eq 2 ]
  # satisfies the allowlist prefix, resolves to the one file the fleet must
  # never rewrite — the denylist has to run FIRST for this to be caught
  run scripts/cerebro/cb-distill --check-path "03 Resources/../CLAUDE.md"
  [ "$status" -eq 2 ]
}

@test "--check-path refuses a vault path outside the allowlist" {
  # 00 Inbox/ is where reports LAND; distilling into it would just move the
  # untriaged pile around
  run scripts/cerebro/cb-distill --check-path "00 Inbox/2026-01-02-research-x.md"
  [ "$status" -eq 2 ]
  [[ "$output" == *"outside the distiller's roots"* ]]
  run scripts/cerebro/cb-distill --check-path "Meetings/2026/08/x.md"
  [ "$status" -eq 2 ]
  run scripts/cerebro/cb-distill --check-path "Daily/2026/2026-08-14.md"
  [ "$status" -eq 2 ]
}

# --- --queue -----------------------------------------------------------------

@test "--queue lists landed-not-distilled only, and prints nothing when empty" {
  run scripts/cerebro/cb-distill --queue
  [ "$status" -eq 0 ]
  [ -z "$output" ]                                  # `/eod` gates on emptiness
  mk_landed alpha
  mk_landed beta; printf 'x\n' > "$CB_HOME/tasks/beta/distilled"
  mkdir -p "$CB_HOME/tasks/gamma"                   # never landed
  run scripts/cerebro/cb-distill --queue
  [[ "$output" == *"alpha"* ]]
  [[ "$output" != *"beta"* ]]
  [[ "$output" != *"gamma"* ]]
  [ "$(printf '%s\n' "$output" | wc -l)" -eq 1 ]
}

# --- --commit: the summary-completeness check --------------------------------

# THE check. §7's safety argument is that every in-place rewrite is reported
# with its before and after — so an unverified summary is narration, not a
# safety mechanism, and a rewrite the agent forgot to report is exactly the case
# this exists to catch.
@test "--commit REFUSES when a changed file is not named in the summary" {
  mk_landed alpha
  start_pass
  printf '# Wiki\n\nRewritten claim.\n' > "$VAULT_DIR/03 Resources/wiki.md"
  mk_summary "nothing of consequence happened (alpha)" > "$SUMMARY"
  local before; before="$(git -C "$VAULT_DIR" rev-list --count HEAD)"
  run scripts/cerebro/cb-distill --commit
  [ "$status" -ne 0 ]
  [[ "$output" == *"REFUSED"* ]]
  [[ "$output" == *"03 Resources/wiki.md"* ]]
  # nothing committed, nothing marked, the tree left exactly as it was
  [ "$(git -C "$VAULT_DIR" rev-list --count HEAD)" = "$before" ]
  [ ! -f "$CB_HOME/tasks/alpha/distilled" ]
  git -C "$VAULT_DIR" status --porcelain | grep -q '03 Resources/wiki.md'
  grep -q "Rewritten claim." "$VAULT_DIR/03 Resources/wiki.md"
}

@test "--commit REFUSES an untracked new file the summary does not name" {
  mk_landed alpha
  start_pass
  printf '# New page\n' > "$VAULT_DIR/03 Resources/new-page.md"
  mk_summary "unrelated prose (alpha)" > "$SUMMARY"
  run scripts/cerebro/cb-distill --commit
  [ "$status" -ne 0 ]
  [[ "$output" == *"03 Resources/new-page.md"* ]]
}

@test "--commit REFUSES when there is no change summary at all" {
  mk_landed alpha
  start_pass
  printf '# Wiki\n\nRewritten.\n' > "$VAULT_DIR/03 Resources/wiki.md"
  run scripts/cerebro/cb-distill --commit
  [ "$status" -ne 0 ]
  [[ "$output" == *"no change summary"* ]]
  [ "$(git -C "$VAULT_DIR" rev-list --count HEAD)" -eq 1 ]
}

@test "a summary naming the file as file:line satisfies the check" {
  mk_landed alpha
  start_pass
  printf '# Wiki\n\nRewritten claim.\n' > "$VAULT_DIR/03 Resources/wiki.md"
  mk_summary "alpha → \`03 Resources/wiki.md:3\` — before: \"Original claim.\" after: \"Rewritten claim.\"" > "$SUMMARY"
  run scripts/cerebro/cb-distill --commit
  [ "$status" -eq 0 ]
  [[ "$output" == *"1 findings into 1 files"* ]]
}

# --- --commit: what it stages ------------------------------------------------

# THE invariant. `git add -A` would swallow ns-capability-drift's deliberately
# staged-uncommitted capability edits and vault-routing's own local commits, and
# "wholesale revert is one SHA" would stop being true.
@test "--commit stages ONLY the changed paths + the summary — unrelated dirt stays out" {
  mk_landed alpha
  printf 'someone else was editing this\n' >> "$VAULT_DIR/seed.md"      # tracked AND modified
  printf 'untracked scratch\n' > "$VAULT_DIR/scratch.md"                # untracked, outside the roots
  start_pass                                                            # both are in the baseline
  printf '# Wiki\n\nRewritten claim.\n' > "$VAULT_DIR/03 Resources/wiki.md"
  mk_summary "alpha → \`03 Resources/wiki.md:3\` — before: \"Original claim.\" after: \"Rewritten claim.\"" > "$SUMMARY"
  run scripts/cerebro/cb-distill --commit
  [ "$status" -eq 0 ]
  [[ "$output" == *"into 1 files"* ]]        # not a vacuous 0-file pass
  run git -C "$VAULT_DIR" show --stat --format= HEAD
  [[ "$output" == *"03 Resources/wiki.md"* ]]
  [[ "$output" == *"distill-summary"* ]]
  [[ "$output" != *"seed.md"* ]]
  [[ "$output" != *"scratch.md"* ]]
  # and the other work is still sitting in the tree, untouched
  git -C "$VAULT_DIR" status --porcelain | grep -q ' M seed.md'
  git -C "$VAULT_DIR" status --porcelain | grep -q '?? scratch.md'
}

# `git add -- <path>` stages the whole worktree blob, so a file someone else has
# already staged would carry their work into this commit — the same defect as
# `add -A`, just narrower.
@test "--commit REFUSES a file that already carries someone else's staged work" {
  mk_landed alpha
  start_pass
  printf '# Wiki\n\nDrift edit, staged for Kyle.\n' > "$VAULT_DIR/03 Resources/wiki.md"
  git -C "$VAULT_DIR" add -- "03 Resources/wiki.md"
  printf '# Wiki\n\nDrift edit, then a distill rewrite on top.\n' > "$VAULT_DIR/03 Resources/wiki.md"
  mk_summary "alpha → \`03 Resources/wiki.md:3\` — before: \"Original claim.\" after: \"a distill rewrite on top.\"" > "$SUMMARY"
  local before; before="$(git -C "$VAULT_DIR" rev-list --count HEAD)"
  run scripts/cerebro/cb-distill --commit
  [ "$status" -ne 0 ]
  [[ "$output" == *"STAGED work"* ]]
  [ "$(git -C "$VAULT_DIR" rev-list --count HEAD)" = "$before" ]
}

@test "--commit marks each source task distilled, and only after the commit" {
  mk_landed alpha; mk_landed delta
  start_pass
  printf '# Wiki\n\nRewritten.\n' > "$VAULT_DIR/03 Resources/wiki.md"
  mk_summary "alpha → \`03 Resources/wiki.md:3\` — before: \"Original claim.\" after: \"Rewritten.\"" \
             "declined: delta — ambiguous, left for /ingest" > "$SUMMARY"
  run scripts/cerebro/cb-distill --commit
  [ "$status" -eq 0 ]
  [ -f "$CB_HOME/tasks/alpha/distilled" ]
  [ -f "$CB_HOME/tasks/delta/distilled" ]
  run scripts/cerebro/cb-distill --queue
  [ -z "$output" ]
}

@test "one commit per run, subject \`distill: <LOCAL> — N findings into M files\`, never pushed" {
  mk_landed alpha; mk_landed delta
  start_pass
  printf '# Wiki\n\nRewritten.\n' > "$VAULT_DIR/03 Resources/wiki.md"
  mkdir -p "$VAULT_DIR/01 Projects/edj"                    # the real shape: 01 Projects/<slug>/notes.md
  printf '# Notes\n' > "$VAULT_DIR/01 Projects/edj/notes.md"
  mk_summary "alpha → \`03 Resources/wiki.md:3\` — before: \"Original claim.\" after: \"Rewritten.\"" \
             "delta → \`01 Projects/edj/notes.md:1\` — before: \"(new file)\" after: \"# Notes\"" > "$SUMMARY"
  run scripts/cerebro/cb-distill --commit
  [ "$status" -eq 0 ]
  [ "$(git -C "$VAULT_DIR" log -1 --format=%s)" = "distill: $LOCAL — 2 findings into 2 files" ]
  [ "$(git -C "$VAULT_DIR" rev-list --count HEAD)" -eq 2 ]      # seed + one distill commit
  [ -z "$(git -C "$VAULT_DIR" remote)" ]                        # nothing to push to, and nothing tried
}

# A pass that declines everything as ambiguous is a legitimate outcome: the
# declines are the summary's content, and the queue still retires.
@test "--commit with no vault changes still commits the summary" {
  mk_landed alpha
  start_pass
  mk_summary "declined: alpha — destination is ambiguous, left for /ingest" > "$SUMMARY"
  run scripts/cerebro/cb-distill --commit
  [ "$status" -eq 0 ]
  [ "$(git -C "$VAULT_DIR" log -1 --format=%s)" = "distill: $LOCAL — 1 findings into 0 files" ]
  run git -C "$VAULT_DIR" show --stat --format= HEAD
  [[ "$output" == *"distill-summary"* ]]
}

@test "--commit --dry-run commits nothing and marks nothing" {
  mk_landed alpha
  start_pass
  printf '# Wiki\n\nRewritten.\n' > "$VAULT_DIR/03 Resources/wiki.md"
  mk_summary "alpha → \`03 Resources/wiki.md:3\` — before: \"Original claim.\" after: \"Rewritten.\"" > "$SUMMARY"
  run scripts/cerebro/cb-distill --commit --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"WOULD commit"* ]]
  [ "$(git -C "$VAULT_DIR" rev-list --count HEAD)" -eq 1 ]
  [ ! -f "$CB_HOME/tasks/alpha/distilled" ]
}

# --- --run -------------------------------------------------------------------

@test "--run scaffolds an ops task and prints the spawn line without spawning" {
  mk_landed alpha
  run scripts/cerebro/cb-distill --run
  [ "$status" -eq 0 ]
  [[ "$output" == *"cb-start --ops distill-$LOCAL"* ]]
  local td="$CB_HOME/tasks/distill-$LOCAL"
  grep -q '^type: ops$' "$td/brief.md"
  grep -q '^clearance: standard$' "$td/brief.md"
  grep -q "^deliverable: 00 Inbox/$LOCAL-ops-distill-$LOCAL.md$" "$td/brief.md"
  grep -q 'alpha' "$td/brief.md"
  grep -q '^kind=ops$' "$td/meta"
  grep -q "^deliverable=00 Inbox/$LOCAL-ops-distill-$LOCAL.md$" "$td/meta"
  [ ! -f "$td/launch.sh" ]                          # spawning is dispatch's job
}

@test "--run with an empty queue is a clean no-op" {
  run scripts/cerebro/cb-distill --run
  [ "$status" -eq 0 ]
  [[ "$output" == *"nothing to do"* ]]
  [ ! -d "$CB_HOME/tasks/distill-$LOCAL" ]
}

@test "--run refuses to overwrite a distill task that already exists" {
  mk_landed alpha
  run scripts/cerebro/cb-distill --run
  [ "$status" -eq 0 ]
  run scripts/cerebro/cb-distill --run
  [ "$status" -eq 2 ]
  [[ "$output" == *"already scaffolded"* ]]
}

@test "usage: no mode is a refusal, not a default" {
  run scripts/cerebro/cb-distill
  [ "$status" -eq 2 ]
  [[ "$output" == *"usage:"* ]]
}

# --- C2/C5/F6 (review cycle 1): the run baseline ------------------------------
#
# `--commit` used to derive "the distiller's changes" from `git status` alone,
# which cannot tell the pass's writes from what was already dirty when it
# started. That single conflation is what made C2 and C5 possible: pre-existing
# dirt was demanded in the summary (so pasting its path committed it) and an
# out-of-roots write was indistinguishable from Kyle's own. `--run` now records
# the dirty set as a baseline and `--commit` subtracts it.

# start_pass — the `--run` half of a real pass, and the only thing that writes
# the baseline. It MUST run before the simulated distiller writes: a write made
# first lands IN the baseline, gets subtracted, and the test passes vacuously.
start_pass() { scripts/cerebro/cb-distill --run >/dev/null; }

@test "--commit REFUSES outright when there is no --run baseline" {
  mk_landed alpha
  printf '# Wiki\n\nRewritten.\n' > "$VAULT_DIR/03 Resources/wiki.md"
  mk_summary "\`03 Resources/wiki.md:3\` — before: \"Original claim.\" after: \"Rewritten.\" (alpha)" > "$SUMMARY"
  run scripts/cerebro/cb-distill --commit
  [ "$status" -ne 0 ]
  [[ "$output" == *"no run baseline"* ]]
  [ "$(git -C "$VAULT_DIR" rev-list --count HEAD)" -eq 1 ]
}

# C2, part 1. THE reproduction: Kyle's own uncommitted edit sat in an allowed
# root, `--commit` demanded it in the summary, and the refusal printed the path
# ready to paste — so satisfying the check committed his work under a `distill:`
# subject. Dirt that predates the pass is not the distiller's, full stop.
@test "pre-existing dirt in an allowed root is neither demanded nor committed" {
  mk_landed alpha
  printf '# Wiki\n\nKyle edited this by hand, uncommitted.\n' > "$VAULT_DIR/03 Resources/wiki.md"
  start_pass
  mk_summary "declined everything as ambiguous (alpha)" > "$SUMMARY"
  run scripts/cerebro/cb-distill --commit
  [ "$status" -eq 0 ]
  [[ "$output" == *"0 files"* ]]
  run git -C "$VAULT_DIR" show --stat --format= HEAD
  [[ "$output" != *"wiki.md"* ]]
  git -C "$VAULT_DIR" status --porcelain | grep -q '03 Resources/wiki.md'
}

# C2, part 2. DoD #5 — "the change summary shows before/after prose for every
# in-place rewrite" — was unenforced: `grep -qF` was satisfied by the path
# appearing anywhere, and the refusal message printed exactly that path.
@test "a bare path paste no longer satisfies the completeness check" {
  mk_landed alpha
  start_pass
  printf '# Wiki\n\nRewritten by the distiller.\n' > "$VAULT_DIR/03 Resources/wiki.md"
  printf '# Distill summary\n\n03 Resources/wiki.md\n\nalpha\n' > "$SUMMARY"
  local before; before="$(git -C "$VAULT_DIR" rev-list --count HEAD)"
  run scripts/cerebro/cb-distill --commit
  [ "$status" -ne 0 ]
  [[ "$output" == *"REFUSED"* ]]
  [[ "$output" == *"before"* ]]
  [ "$(git -C "$VAULT_DIR" rev-list --count HEAD)" = "$before" ]
}

# C2, part 3. The refusal must not read as an instruction the agent can satisfy
# by pasting — that is the sentence that walked it into committing Kyle's work.
@test "the refusal says pasting the path is not the fix" {
  mk_landed alpha
  start_pass
  printf '# Wiki\n\nRewritten.\n' > "$VAULT_DIR/03 Resources/wiki.md"
  mk_summary "nothing reported (alpha)" > "$SUMMARY"
  run scripts/cerebro/cb-distill --commit
  [ "$status" -ne 0 ]
  [[ "$output" == *"Pasting the path"* ]]
  [[ "$output" == *"is NOT the fix"* ]]
}

@test "an entry carrying the path with before: and after: satisfies the check" {
  mk_landed alpha
  start_pass
  printf '# Wiki\n\nRewritten claim.\n' > "$VAULT_DIR/03 Resources/wiki.md"
  mk_summary "alpha → \`03 Resources/wiki.md:3\` — before: \"Original claim.\" after: \"Rewritten claim.\" why: it owns this subject." > "$SUMMARY"
  run scripts/cerebro/cb-distill --commit
  [ "$status" -eq 0 ]
  [[ "$output" == *"1 findings into 1 files"* ]]
}

# C5. A distiller write to `People/someone.md` was neither committed (correct),
# nor refused, nor reported — it just sat as `?? People/`. Silence on a
# forbidden write is the finding: nobody learns the agent tried. The baseline is
# what makes it detectable, because it separates the pass's writes from dirt.
@test "--commit REFUSES loudly on a pass write outside the roots, naming it" {
  mk_landed alpha
  start_pass
  printf '# Someone\n\nA finding about a person.\n' > "$VAULT_DIR/People/someone.md"
  mk_summary "declined (alpha)" > "$SUMMARY"
  local before; before="$(git -C "$VAULT_DIR" rev-list --count HEAD)"
  run scripts/cerebro/cb-distill --commit
  [ "$status" -ne 0 ]
  [[ "$output" == *"REFUSED"* ]]
  [[ "$output" == *"People/someone.md"* ]]
  [ "$(git -C "$VAULT_DIR" rev-list --count HEAD)" = "$before" ]
  # not staged, not reverted — naming it IS the whole job
  [ -f "$VAULT_DIR/People/someone.md" ]
}

# The one the allowlist alone would miss: inside an allowed root, on the
# never-touch list. A rule surface rewritten by an automated pass changes how
# every later agent behaves in that directory.
@test "--commit REFUSES a pass write to a denylisted path inside an allowed root" {
  mk_landed alpha
  start_pass
  printf '# conventions\n\nrewritten by a pass\n' > "$VAULT_DIR/03 Resources/CLAUDE.md"
  mk_summary "declined (alpha)" > "$SUMMARY"
  run scripts/cerebro/cb-distill --commit
  [ "$status" -ne 0 ]
  [[ "$output" == *"03 Resources/CLAUDE.md"* ]]
}

# The other side of it: out-of-roots dirt that was already there is Kyle's, or
# another pass's, and must not block this commit.
@test "out-of-roots dirt that predates the pass does not refuse the commit" {
  mk_landed alpha
  printf 'kyle was editing this\n' >> "$VAULT_DIR/seed.md"
  printf '# Someone\n\nKyle wrote this himself\n' > "$VAULT_DIR/People/someone.md"
  start_pass
  mk_summary "declined (alpha)" > "$SUMMARY"
  run scripts/cerebro/cb-distill --commit
  [ "$status" -eq 0 ]
  run git -C "$VAULT_DIR" show --stat --format= HEAD
  [[ "$output" != *"seed.md"* ]]
  [[ "$output" != *"someone.md"* ]]
}

# F6 (Architect finding, reproduced). `--commit` marked EVERY pending slug
# distilled once the commit landed, so a pass that handled 2 of 5 and named only
# its own changed files passed the check and permanently retired the other 3
# with nobody having looked at them. The existing completeness check is
# one-directional — it catches "a file changed but was not reported" and never
# "a queued report was never addressed", which is the exact failure §Risk names.
@test "--commit REFUSES when a pending report is never named in the summary" {
  mk_landed alpha; mk_landed omitted
  start_pass
  printf '# Wiki\n\nRewritten.\n' > "$VAULT_DIR/03 Resources/wiki.md"
  mk_summary "alpha → \`03 Resources/wiki.md:3\` — before: \"Original claim.\" after: \"Rewritten.\"" > "$SUMMARY"
  local before; before="$(git -C "$VAULT_DIR" rev-list --count HEAD)"
  run scripts/cerebro/cb-distill --commit
  [ "$status" -ne 0 ]
  [[ "$output" == *"omitted"* ]]
  [ "$(git -C "$VAULT_DIR" rev-list --count HEAD)" = "$before" ]
  # and neither slug is retired — the whole run stays pending for another pass
  [ ! -f "$CB_HOME/tasks/omitted/distilled" ]
  [ ! -f "$CB_HOME/tasks/alpha/distilled" ]
}

# Declining is the ONLY way to drop something, which is the point: a decline is
# recorded and routed to /ingest, silence is not.
@test "an explicit decline names the report and lets the commit through" {
  mk_landed alpha; mk_landed omitted
  start_pass
  printf '# Wiki\n\nRewritten.\n' > "$VAULT_DIR/03 Resources/wiki.md"
  mk_summary "alpha → \`03 Resources/wiki.md:3\` — before: \"Original claim.\" after: \"Rewritten.\"" \
             "declined: \`omitted\` — ambiguous between two pages, left for /ingest" > "$SUMMARY"
  run scripts/cerebro/cb-distill --commit
  [ "$status" -eq 0 ]
  [ -f "$CB_HOME/tasks/omitted/distilled" ]
}

# The landed `00 Inbox/` file is what the skill tells the agent to cite, so
# citing it counts as naming the report.
@test "naming a report by its landed path counts as naming it" {
  mk_landed alpha
  start_pass
  mk_summary "\`00 Inbox/2026-01-02-research-alpha.md\` — nothing worth integrating, declined" > "$SUMMARY"
  run scripts/cerebro/cb-distill --commit
  [ "$status" -eq 0 ]
}

@test "--run records the dirty baseline in the task dir" {
  mk_landed alpha
  printf 'dirty before the pass\n' >> "$VAULT_DIR/seed.md"
  start_pass
  [ -f "$CB_HOME/tasks/distill-$LOCAL/dirty-baseline" ]
  run tr '\0' '\n' < "$CB_HOME/tasks/distill-$LOCAL/dirty-baseline"
  [[ "$output" == *"seed.md"* ]]
}

# The C5 inference, corrected 2026-08-15. Asking "is this path out of bounds?"
# and concluding "then the distiller wrote it" is false for a file with its own
# writer on a timer: cb-board rewrites board.md from every ~30s cb-watch tick,
# a pass takes minutes, so the refusal fired on essentially every real run and
# the nightly pass would have been permanently non-functional. The split lives
# in lib/denylist.sh as cb_is_generated_surface, next to the list it divides.
@test "a fleet-generated file rewritten mid-pass is NOTED, and the commit still lands" {
  mk_landed alpha
  printf 'board\n' > "$VAULT_DIR/board.md"
  git -C "$VAULT_DIR" add -A >/dev/null; git -C "$VAULT_DIR" commit -qm board >/dev/null
  start_pass                                            # clean tree at --run
  printf '# Wiki\n\nRewritten claim.\n' > "$VAULT_DIR/03 Resources/wiki.md"
  printf 'board refreshed by cb-board\n' > "$VAULT_DIR/board.md"   # its own writer, mid-pass
  mk_summary "alpha → \`03 Resources/wiki.md:3\` — before: \"Original claim.\" after: \"Rewritten claim.\"" > "$SUMMARY"
  run scripts/cerebro/cb-distill --commit
  [ "$status" -eq 0 ]
  [[ "$output" == *"board.md"* ]]                       # noted, by name
  [[ "$output" != *"REFUSED"* ]]
  # and it stays out of the commit and out of the summary's obligations
  run git -C "$VAULT_DIR" show --stat --format= HEAD
  [[ "$output" != *"board.md"* ]]
  [[ "$output" == *"03 Resources/wiki.md"* ]]
  git -C "$VAULT_DIR" status --porcelain | grep -q 'board.md'
}

# The companion, and the reason the split is not a blanket exemption: nothing on
# this machine writes People/ on a timer, so a change there during the pass IS
# the pass, and it keeps refusing exactly as before.
@test "a hand-maintained destination written mid-pass still REFUSES" {
  mk_landed alpha
  start_pass
  printf '# Someone\n\nA finding about a person.\n' > "$VAULT_DIR/People/someone.md"
  printf 'board refreshed by cb-board\n' > "$VAULT_DIR/board.md"   # noise, not cover
  mk_summary "declined (alpha)" > "$SUMMARY"
  run scripts/cerebro/cb-distill --commit
  [ "$status" -ne 0 ]
  [[ "$output" == *"REFUSED"* ]]
  [[ "$output" == *"People/someone.md"* ]]
}

@test "cb_is_generated_surface names the three timer-written files and nothing else" {
  source scripts/cerebro/lib/denylist.sh
  for p in hot.md board.md magneto.md; do
    cb_is_generated_surface "$p"
    cb_is_forbidden "$p"                                # still never writable
  done
  for p in CLAUDE.md profile.md personality.md "People/x.md" "Confidential/x.md" \
           ".claude/settings.json" "scripts/cb-x" "03 Resources/CLAUDE.md" "03 Resources/wiki.md"; do
    run cb_is_generated_surface "$p"
    [ "$status" -ne 0 ]
  done
}
