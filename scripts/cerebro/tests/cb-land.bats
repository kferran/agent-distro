#!/usr/bin/env bats
# cb-land — files finished research/ops reports into the vault at the path that
# was computed for them at scaffold time.
#
# This script is allowed to WRITE and COMMIT the vault, so the refusal paths
# carry at least as much weight as the landing paths: what it must not clobber,
# what it must not file, and — the one that would do real damage quietly — what
# it must not sweep into a commit alongside the report.

setup() {
  # HOME is thrown away as defense-in-depth. cb-land's vault default is
  # "$HOME/vault"; if VAULT_DIR were ever dropped from a test the fallback must
  # not be Kyle's real vault.
  export HOME="$BATS_TEST_TMPDIR/home"; mkdir -p "$HOME"
  export CB_HOME="$BATS_TEST_TMPDIR/.cerebro"; mkdir -p "$CB_HOME/tasks" "$CB_HOME/logs"
  export VAULT_DIR="$BATS_TEST_TMPDIR/vault"
  mkdir -p "$VAULT_DIR/00 Inbox"
  git -C "$VAULT_DIR" init -q 2>/dev/null || true
  git -C "$VAULT_DIR" config user.email t@t; git -C "$VAULT_DIR" config user.name t
  printf 'seed\n' > "$VAULT_DIR/seed.md"
  git -C "$VAULT_DIR" add -A >/dev/null; git -C "$VAULT_DIR" commit -qm seed >/dev/null
  # No tmux in bats. Both liveness probes ECHO a state; an empty listing is a
  # legitimate `gone`, which is what every test below wants.
  export CB_WINDOW_LIST_CMD="true"
  export CB_SESSION_LIST_CMD="true"
  LOCAL="$(TZ=America/Denver date +%F)"
}

# mk_task SLUG KIND STATUS CLEARANCE DELIVERABLE
#   CLEARANCE  "-" = no brief.md at all · "" = brief.md with no clearance field
#   DELIVERABLE "-" = no deliverable= line in meta (pre-computed-path task)
mk_task() {
  local slug="$1" kind="$2" status="$3" clr="$4" dl="$5"
  local td="$CB_HOME/tasks/$slug"; mkdir -p "$td"
  { printf 'kind=%s\nsession=%s\n' "$kind" "$slug"
    [ "$dl" = "-" ] || printf 'deliverable=%s\n' "$dl"
  } > "$td/meta"
  printf -- '---\nstatus: %s\nconfidence: high\n---\n\n# Finding\n\nBody text for %s.\n' \
    "$status" "$slug" > "$td/report.md"
  case "$clr" in
    -)  : ;;
    "") printf -- '---\ntask: %s\ntype: research\n---\n\n# Objective\n' "$slug" > "$td/brief.md";;
    *)  printf -- '---\ntask: %s\ntype: research\nclearance: %s\n---\n\n# Objective\n' \
          "$slug" "$clr" > "$td/brief.md";;
  esac
}

# --- the terminal gate -------------------------------------------------------

@test "a terminal research report lands at its computed destination" {
  mk_task probe-a research complete standard "00 Inbox/2026-01-02-research-probe-a.md"
  run scripts/cerebro/cb-land probe-a
  [ "$status" -eq 0 ]
  [ -f "$VAULT_DIR/00 Inbox/2026-01-02-research-probe-a.md" ]
  grep -q "Body text for probe-a." "$VAULT_DIR/00 Inbox/2026-01-02-research-probe-a.md"
}

@test "done and partial are terminal too" {
  mk_task probe-done research done standard "00 Inbox/d.md"
  mk_task probe-part research partial standard "00 Inbox/p.md"
  run scripts/cerebro/cb-land probe-done
  run scripts/cerebro/cb-land probe-part
  [ -f "$VAULT_DIR/00 Inbox/d.md" ]
  [ -f "$VAULT_DIR/00 Inbox/p.md" ]
}

@test "a non-terminal report is skipped, nothing written" {
  mk_task probe-run research running standard "00 Inbox/2026-01-02-research-probe-run.md"
  run scripts/cerebro/cb-land probe-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"not terminal"* ]]
  [ ! -f "$VAULT_DIR/00 Inbox/2026-01-02-research-probe-run.md" ]
  [ ! -f "$CB_HOME/tasks/probe-run/landed" ]
}

@test "kind=code is skipped — its deliverable is a PR, not a vault landing" {
  mk_task fix-x code complete standard "00 Inbox/2026-01-02-code-fix-x.md"
  run scripts/cerebro/cb-land fix-x
  [ "$status" -eq 0 ]
  [[ "$output" == *"deliverable is a PR"* ]]
  [ ! -f "$VAULT_DIR/00 Inbox/2026-01-02-code-fix-x.md" ]
}

@test "a task with no report.md is skipped" {
  mkdir -p "$CB_HOME/tasks/empty-t"
  printf 'kind=research\n' > "$CB_HOME/tasks/empty-t/meta"
  run scripts/cerebro/cb-land empty-t
  [ "$status" -eq 0 ]
  [[ "$output" == *"no report.md"* ]]
}

# --- the clearance gate (§4) -------------------------------------------------

@test "clearance: confidential is surfaced, never filed" {
  mk_task secret-t research complete confidential "00 Inbox/2026-01-02-research-secret-t.md"
  run scripts/cerebro/cb-land secret-t
  [ "$status" -eq 0 ]
  [ ! -f "$VAULT_DIR/00 Inbox/2026-01-02-research-secret-t.md" ]
  grep -q "secret-t" "$CB_HOME/logs/land-surfaced"
  grep -q "## cb-land — surfaced, not filed" "$VAULT_DIR/00 Inbox/$LOCAL-vault-maintenance-ratify.md"
  grep -q "confidential" "$VAULT_DIR/00 Inbox/$LOCAL-vault-maintenance-ratify.md"
}

# The inversion of today's fail-closed rule, and the reason this whole wave
# exists: `clearance:` is script-written now, so an absent one is a scaffold
# bug. Stranding the finding forever is worse than filing it into 00 Inbox/.
@test "a brief with NO clearance field lands as standard" {
  mk_task noclr-t research complete "" "00 Inbox/2026-01-02-research-noclr-t.md"
  run scripts/cerebro/cb-land noclr-t
  [ "$status" -eq 0 ]
  [ -f "$VAULT_DIR/00 Inbox/2026-01-02-research-noclr-t.md" ]
}

@test "NO brief.md at all lands as standard" {
  mk_task nobrief-t research complete - "00 Inbox/2026-01-02-research-nobrief-t.md"
  [ ! -f "$CB_HOME/tasks/nobrief-t/brief.md" ]
  run scripts/cerebro/cb-land nobrief-t
  [ "$status" -eq 0 ]
  [ -f "$VAULT_DIR/00 Inbox/2026-01-02-research-nobrief-t.md" ]
}

@test "an unrecognised clearance is surfaced, not guessed at" {
  mk_task weird-t research complete internal-eyes-only "00 Inbox/2026-01-02-research-weird-t.md"
  run scripts/cerebro/cb-land weird-t
  [ "$status" -eq 0 ]
  [ ! -f "$VAULT_DIR/00 Inbox/2026-01-02-research-weird-t.md" ]
  grep -q "unrecognised clearance" "$CB_HOME/logs/land-surfaced"
}

# --- the destination gate ----------------------------------------------------

@test "a destination outside 00 Inbox/ is refused and surfaced" {
  mk_task stray-t research complete standard "03 Resources/ultron/some-page.md"
  run scripts/cerebro/cb-land stray-t
  [ "$status" -eq 0 ]
  [ ! -f "$VAULT_DIR/03 Resources/ultron/some-page.md" ]
  [[ "$output" == *"surfaced"* ]]
}

# `00 Inbox/../CLAUDE.md` satisfies a naive prefix test and resolves to the one
# file the fleet must never rewrite.
@test "a traversal dressed up as an 00 Inbox/ path is refused" {
  printf 'policy\n' > "$VAULT_DIR/CLAUDE.md"
  mk_task trav-t research complete standard "00 Inbox/../CLAUDE.md"
  run scripts/cerebro/cb-land trav-t
  [ "$status" -eq 0 ]
  [ "$(cat "$VAULT_DIR/CLAUDE.md")" = "policy" ]
  grep -q "trav-t" "$CB_HOME/logs/land-surfaced"
}

@test "an absolute destination is refused" {
  mk_task abs-t research complete standard "/etc/passwd-ish"
  run scripts/cerebro/cb-land abs-t
  [ "$status" -eq 0 ]
  grep -q "abs-t" "$CB_HOME/logs/land-surfaced"
}

@test "a task with no deliverable= in meta falls back to the computed path, and says so" {
  mk_task old-t research complete standard -
  run scripts/cerebro/cb-land old-t
  [ "$status" -eq 0 ]
  [ -f "$VAULT_DIR/00 Inbox/$LOCAL-research-old-t.md" ]
  [[ "$output" == *"recomputed"* ]]
}

# --- collision + idempotency -------------------------------------------------

@test "an existing file at the destination is refused, never clobbered" {
  mk_task clash-t research complete standard "00 Inbox/2026-01-02-research-clash-t.md"
  printf 'hand-edited, possibly already distilled\n' > "$VAULT_DIR/00 Inbox/2026-01-02-research-clash-t.md"
  run scripts/cerebro/cb-land clash-t
  [ "$status" -eq 0 ]
  [ "$(cat "$VAULT_DIR/00 Inbox/2026-01-02-research-clash-t.md")" = "hand-edited, possibly already distilled" ]
  grep -q "already exists" "$CB_HOME/logs/land-surfaced"
}

@test "re-running on an already-landed task is a no-op success, not a collision refusal" {
  mk_task idem-t research complete standard "00 Inbox/2026-01-02-research-idem-t.md"
  run scripts/cerebro/cb-land idem-t
  [ "$status" -eq 0 ]
  local before; before="$(git -C "$VAULT_DIR" rev-list --count HEAD)"
  local sum; sum="$(md5sum < "$VAULT_DIR/00 Inbox/2026-01-02-research-idem-t.md")"
  run scripts/cerebro/cb-land idem-t
  [ "$status" -eq 0 ]
  [[ "$output" == *"already landed"* ]]
  [ ! -s "$CB_HOME/logs/land-surfaced" ]
  [ "$(md5sum < "$VAULT_DIR/00 Inbox/2026-01-02-research-idem-t.md")" = "$sum" ]
  [ "$(git -C "$VAULT_DIR" rev-list --count HEAD)" = "$before" ]
}

# --- provenance + the landed marker -----------------------------------------

@test "provenance is stamped INTO the report's own frontmatter, fields intact" {
  mk_task prov-t research complete standard "00 Inbox/2026-01-02-research-prov-t.md"
  run scripts/cerebro/cb-land prov-t
  local f="$VAULT_DIR/00 Inbox/2026-01-02-research-prov-t.md"
  [ "$(head -1 "$f")" = "---" ]
  grep -q "^landed_from: $CB_HOME/tasks/prov-t/report.md$" "$f"
  grep -q "^landed_slug: prov-t$" "$f"
  grep -q "^landed_kind: research$" "$f"
  grep -q "^landed_by: cb-land$" "$f"
  grep -qE "^landed_at: [0-9]{4}-[0-9]{2}-[0-9]{2}T" "$f"
  # the report's own fields survive, and there is exactly ONE frontmatter block
  grep -q "^status: complete$" "$f"
  grep -q "^confidence: high$" "$f"
  [ "$(grep -c '^---$' "$f")" -eq 2 ]
}

# A `status:` that is not in a frontmatter block is not a declaration. The
# terminal gate is the same parser cb-unlanded uses, and it must not be
# satisfiable by a body line.
@test "a bare `status: complete` line outside frontmatter does not make a report terminal" {
  local td="$CB_HOME/tasks/bare-t"; mkdir -p "$td"
  printf 'kind=research\ndeliverable=00 Inbox/bare.md\n' > "$td/meta"
  printf 'status: complete\n' > "$td/report.md"   # NOT frontmatter — no fences
  run scripts/cerebro/cb-land bare-t
  # no terminal frontmatter -> not terminal -> skipped, nothing written
  [[ "$output" == *"not terminal"* ]]
  [ ! -f "$VAULT_DIR/00 Inbox/bare.md" ]
}

# A report that opens a frontmatter fence and never closes it still yields a
# `status:` to the terminal gate, so it reaches the writer. Inserting after
# line 1 would swallow the whole body into an unterminated block.
@test "an unterminated frontmatter block gets a fresh one prepended, body intact" {
  local td="$CB_HOME/tasks/mal-t"; mkdir -p "$td"
  printf 'kind=research\ndeliverable=00 Inbox/mal.md\n' > "$td/meta"
  printf -- '---\nstatus: complete\n\n# Finding\n\nUnterminated body.\n' > "$td/report.md"
  run scripts/cerebro/cb-land mal-t
  [ "$status" -eq 0 ]
  local f="$VAULT_DIR/00 Inbox/mal.md"
  [ -f "$f" ]
  grep -q "^landed_slug: mal-t$" "$f"
  grep -q "Unterminated body." "$f"
  # the created block is closed: line 1 and the line after the provenance
  [ "$(head -1 "$f")" = "---" ]
  [ "$(sed -n '7p' "$f")" = "---" ]
}

@test "the landed marker records the destination and the register is cleared" {
  mk_task mark-t research complete standard "00 Inbox/2026-01-02-research-mark-t.md"
  printf 'mark-t\tclass=blocked-ingest\tfirst=1\tlast=2\tsurfaces=9\torigin=watched\n' \
    > "$CB_HOME/logs/unlanded-register"
  printf 'other-t\tclass=unknown\tfirst=1\tlast=2\tsurfaces=1\torigin=watched\n' \
    >> "$CB_HOME/logs/unlanded-register"
  run scripts/cerebro/cb-land mark-t
  [ "$(cat "$CB_HOME/tasks/mark-t/landed")" = "00 Inbox/2026-01-02-research-mark-t.md" ]
  ! grep -q "^mark-t	" "$CB_HOME/logs/unlanded-register"
  grep -q "^other-t	" "$CB_HOME/logs/unlanded-register"
}

# --- the commit --------------------------------------------------------------

# THE invariant. `git add -A` here would swallow ns-capability-drift's
# deliberately staged-uncommitted capability edits and vault-routing's own local
# commits, and "revert one SHA" would stop being true.
@test "the commit contains ONLY the landed path — an unrelated dirty file stays out" {
  mk_task solo-t research complete standard "00 Inbox/2026-01-02-research-solo-t.md"
  printf 'someone else was editing this\n' >> "$VAULT_DIR/seed.md"   # tracked AND modified
  printf 'untracked scratch\n' > "$VAULT_DIR/scratch.md"
  run scripts/cerebro/cb-land solo-t
  [ "$status" -eq 0 ]
  run git -C "$VAULT_DIR" show --stat --format= HEAD
  [[ "$output" == *"solo-t"* ]]
  [[ "$output" != *"seed.md"* ]]
  [[ "$output" != *"scratch.md"* ]]
  # and the other work is still sitting in the tree, untouched
  git -C "$VAULT_DIR" status --porcelain | grep -q ' M seed.md'
  git -C "$VAULT_DIR" status --porcelain | grep -q '?? scratch.md'
}

@test "one commit per run, subject `land: <LOCAL> — N report(s)`" {
  mk_task multi-a research complete standard "00 Inbox/2026-01-02-research-multi-a.md"
  mk_task multi-b ops complete standard "00 Inbox/2026-01-02-ops-multi-b.md"
  local before; before="$(git -C "$VAULT_DIR" rev-list --count HEAD)"
  run scripts/cerebro/cb-land --drain
  [ "$status" -eq 0 ]
  [ "$(git -C "$VAULT_DIR" rev-list --count HEAD)" = "$(( before + 1 ))" ]
  [ "$(git -C "$VAULT_DIR" log -1 --format=%s)" = "land: $LOCAL — 2 report(s)" ]
}

# C1 (review cycle 1). The ratify worklist is a SHARED append surface —
# vault-routing, cb-ingest, the housekeeping audits and /eod all write to it and
# it accumulates pending decisions all day — so staging it wholesale commits
# whatever else is sitting in it. That is the `git add -A` failure by a narrower
# route, and the flock is no help: nothing outside cb-land and cb-distill takes
# that lock. The surfacing is a notification; the file persists on disk and
# /eod's daily commit picks it up like every other ratify append.
@test "a surfaced-only run makes NO commit at all — the shared worklist is never staged" {
  mk_task hush-t research complete confidential "00 Inbox/2026-01-02-research-hush-t.md"
  printf 'someone else was editing this\n' >> "$VAULT_DIR/seed.md"
  local before; before="$(git -C "$VAULT_DIR" rev-list --count HEAD)"
  run scripts/cerebro/cb-land hush-t
  [ "$status" -eq 0 ]
  [[ "$output" == *"! surfaced"* ]]
  [ "$(git -C "$VAULT_DIR" rev-list --count HEAD)" = "$before" ]
  # the refusal still reached Kyle: it is in the worklist, on disk, uncommitted
  grep -q 'hush-t' "$VAULT_DIR/00 Inbox/$LOCAL-vault-maintenance-ratify.md"
  # -uall: porcelain collapses a wholly-untracked directory to `?? 00 Inbox/`
  git -C "$VAULT_DIR" status --porcelain -uall | grep -q 'vault-maintenance-ratify'
}

# The reproduction, exactly as the reviewer and the Architect ran it: another
# pass's undecided line was committed under a `land:` subject.
@test "another pass's pending decision in the worklist is never swept into a land: commit" {
  printf '# Vault maintenance ratify\n\n- [ ] PENDING ROUTING DECISION from vault-routing\n' \
    > "$VAULT_DIR/00 Inbox/$LOCAL-vault-maintenance-ratify.md"
  mk_task swept-t research complete confidential "00 Inbox/2026-01-02-research-swept-t.md"
  run scripts/cerebro/cb-land swept-t
  [ "$status" -eq 0 ]
  run git -C "$VAULT_DIR" log --all -p
  [[ "$output" != *"PENDING ROUTING DECISION"* ]]
}

# A run that lands AND surfaces still commits — but only the landed report.
@test "a mixed run commits the landed path only, never the worklist alongside it" {
  mk_task both-a research complete standard "00 Inbox/2026-01-02-research-both-a.md"
  mk_task both-b research complete confidential "00 Inbox/2026-01-02-research-both-b.md"
  run scripts/cerebro/cb-land --drain
  [ "$status" -eq 0 ]
  run git -C "$VAULT_DIR" show --stat --format= HEAD
  [[ "$output" == *"both-a"* ]]
  [[ "$output" != *"vault-maintenance-ratify"* ]]
}

# cb-watch calls this every ~30s and a refusal is permanent by construction, so
# an unguarded surface would append the same bullet ~2,900 times a day and make
# a commit for each one. Same defect cb-unlanded's fingerprint guard exists for.
@test "a repeated refusal surfaces ONCE — no duplicate bullets, no second commit" {
  mk_task loop-t research complete confidential "00 Inbox/2026-01-02-research-loop-t.md"
  run scripts/cerebro/cb-land --drain
  [ "$status" -eq 0 ]
  local after1; after1="$(git -C "$VAULT_DIR" rev-list --count HEAD)"
  run scripts/cerebro/cb-land --drain
  [[ "$output" == *"already surfaced"* ]]
  run scripts/cerebro/cb-land --drain
  [ "$(grep -c 'loop-t' "$VAULT_DIR/00 Inbox/$LOCAL-vault-maintenance-ratify.md")" -eq 1 ]
  [ "$(grep -c 'loop-t' "$CB_HOME/logs/land-surfaced")" -eq 1 ]
  [ "$(git -C "$VAULT_DIR" rev-list --count HEAD)" = "$after1" ]
}

@test "a refusal whose REASON changes surfaces again" {
  mk_task shift-t research complete confidential "00 Inbox/2026-01-02-research-shift-t.md"
  run scripts/cerebro/cb-land shift-t
  # sensitivity call reversed by hand; now it collides instead
  printf -- '---\ntask: shift-t\nclearance: standard\n---\n' > "$CB_HOME/tasks/shift-t/brief.md"
  printf 'pre-existing\n' > "$VAULT_DIR/00 Inbox/2026-01-02-research-shift-t.md"
  run scripts/cerebro/cb-land shift-t
  [[ "$output" == *"surfaced"* ]]
  [[ "$output" != *"already surfaced"* ]]
  [ "$(grep -c 'shift-t' "$CB_HOME/logs/land-surfaced")" -eq 2 ]
}

@test "landing clears the surfaced marker so a later refusal is not suppressed" {
  mk_task fixed-t research complete confidential "00 Inbox/2026-01-02-research-fixed-t.md"
  run scripts/cerebro/cb-land fixed-t
  [ -f "$CB_HOME/tasks/fixed-t/surfaced" ]
  printf -- '---\ntask: fixed-t\nclearance: standard\n---\n' > "$CB_HOME/tasks/fixed-t/brief.md"
  run scripts/cerebro/cb-land fixed-t
  [ -f "$VAULT_DIR/00 Inbox/2026-01-02-research-fixed-t.md" ]
  [ ! -f "$CB_HOME/tasks/fixed-t/surfaced" ]
}

# C4 (review cycle 1). `>> "$RATIFY"` with no mkdir -p aborted the whole run
# under `set -euo pipefail` — and, because of C3, invisibly. `land_one` is
# documented at cb-land:109 as never exiting, every outcome a counted line; a
# surface() that can kill the process breaks that promise for every task after
# the first one.
@test "a missing 00 Inbox/ does not abort a --drain — every task still gets processed" {
  rm -rf "$VAULT_DIR/00 Inbox"
  mk_task c4-a research complete confidential "00 Inbox/2026-01-02-research-c4-a.md"
  mk_task c4-b research complete confidential "00 Inbox/2026-01-02-research-c4-b.md"
  run scripts/cerebro/cb-land --drain
  [ "$status" -eq 0 ]
  [[ "$output" == *"c4-a"* ]]
  [[ "$output" == *"c4-b"* ]]
  [[ "$output" == *"2 surfaced"* ]]
  grep -q 'c4-b' "$VAULT_DIR/00 Inbox/$LOCAL-vault-maintenance-ratify.md"
}

@test "--dry-run does not write the surfaced marker (it must not poison the dedup)" {
  mk_task dryd-t research complete confidential "00 Inbox/2026-01-02-research-dryd-t.md"
  run scripts/cerebro/cb-land dryd-t --dry-run
  [ ! -f "$CB_HOME/tasks/dryd-t/surfaced" ]
  run scripts/cerebro/cb-land dryd-t
  [[ "$output" == *"! surfaced"* ]]
}

@test "nothing landed and nothing surfaced -> no commit at all" {
  mk_task quiet-t research running standard "00 Inbox/2026-01-02-research-quiet-t.md"
  local before; before="$(git -C "$VAULT_DIR" rev-list --count HEAD)"
  run scripts/cerebro/cb-land quiet-t
  [ "$(git -C "$VAULT_DIR" rev-list --count HEAD)" = "$before" ]
}

# --- --dry-run ---------------------------------------------------------------

@test "--dry-run writes nothing: no vault file, no marker, no log, no commit" {
  mk_task dry-t research complete standard "00 Inbox/2026-01-02-research-dry-t.md"
  local before; before="$(git -C "$VAULT_DIR" rev-list --count HEAD)"
  run scripts/cerebro/cb-land dry-t --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"WOULD land"* ]]
  [ ! -f "$VAULT_DIR/00 Inbox/2026-01-02-research-dry-t.md" ]
  [ ! -f "$CB_HOME/tasks/dry-t/landed" ]
  [ ! -f "$CB_HOME/logs/land-surfaced" ]
  [ "$(git -C "$VAULT_DIR" rev-list --count HEAD)" = "$before" ]
}

@test "--dry-run on a confidential task surfaces to stdout but writes no ratify line" {
  mk_task dryc-t research complete confidential "00 Inbox/2026-01-02-research-dryc-t.md"
  run scripts/cerebro/cb-land dryc-t --dry-run
  [[ "$output" == *"surfaced"* ]]
  [ ! -f "$VAULT_DIR/00 Inbox/$LOCAL-vault-maintenance-ratify.md" ]
}

# --- --drain -----------------------------------------------------------------

@test "--drain skips a task whose window is still alive" {
  mk_task live-t research complete standard "00 Inbox/2026-01-02-research-live-t.md"
  export CB_WINDOW_LIST_CMD="echo live-t"
  run scripts/cerebro/cb-land --drain
  [ "$status" -eq 0 ]
  [[ "$output" == *"still live"* ]]
  [ ! -f "$VAULT_DIR/00 Inbox/2026-01-02-research-live-t.md" ]
}

@test "--drain lands the eligible tasks and leaves the rest alone" {
  mk_task ok-t research complete standard "00 Inbox/ok.md"
  mk_task run-t research running standard "00 Inbox/run.md"
  mk_task code-t code complete standard "00 Inbox/code.md"
  run scripts/cerebro/cb-land --drain
  [ "$status" -eq 0 ]
  [ -f "$VAULT_DIR/00 Inbox/ok.md" ]
  [ ! -f "$VAULT_DIR/00 Inbox/run.md" ]
  [ ! -f "$VAULT_DIR/00 Inbox/code.md" ]
  [[ "$output" == *"1 landed"* ]]
}

@test "--drain on an empty CB_HOME is a clean no-op" {
  run scripts/cerebro/cb-land --drain
  [ "$status" -eq 0 ]
  [[ "$output" == *"0 landed"* ]]
}

# --- refusing to run at all --------------------------------------------------

# cb-watch.bats throws HOME away and creates terminal report.md fixtures that
# reach the wave-3 landing arm. Without this the lander would materialise a
# whole vault tree under a bats tmpdir — or a shadow vault on any machine where
# the real one isn't checked out.
@test "no vault directory -> refuses, exits non-zero, creates nothing" {
  export VAULT_DIR="$BATS_TEST_TMPDIR/nope"
  mk_task ghost-t research complete standard "00 Inbox/ghost.md"
  run scripts/cerebro/cb-land ghost-t
  [ "$status" -ne 0 ]
  [[ "$output" == *"no vault"* ]]
  [ ! -d "$BATS_TEST_TMPDIR/nope" ]
  [ ! -f "$CB_HOME/tasks/ghost-t/landed" ]
}

@test "no vault directory -> --drain refuses the same way" {
  export VAULT_DIR="$BATS_TEST_TMPDIR/nope"
  run scripts/cerebro/cb-land --drain
  [ "$status" -ne 0 ]
  [ ! -d "$BATS_TEST_TMPDIR/nope" ]
}

@test "usage: no mode is a refusal, not a silent drain" {
  run scripts/cerebro/cb-land
  [ "$status" -eq 2 ]
  [[ "$output" == *"usage"* ]]
}

@test "a slug with shell metacharacters is refused before anything runs" {
  run scripts/cerebro/cb-land 'evil;rm -rf /'
  [ "$status" -eq 2 ]
}

# --- lib/land.sh: the destination validator ---------------------------------

@test "cb_land_dest_ok accepts a plain 00 Inbox/ file and refuses everything else" {
  source scripts/cerebro/lib/land.sh
  run cb_land_dest_ok "00 Inbox/2026-01-02-research-x.md"
  [ "$status" -eq 0 ]
  for bad in "" "/abs/x.md" "00 Inbox/../CLAUDE.md" "03 Resources/x.md" "CLAUDE.md" \
             "People/x.md" ".claude/x.md" "00 Inbox/" "00 Inbox"; do
    run cb_land_dest_ok "$bad"
    [ "$status" -eq 2 ]
  done
}

# The class C4 belonged to. `land_one` is documented at :109 as never exiting,
# but it is an ordinary function under `set -euo pipefail` — any unguarded
# failure inside it kills the process and every task queued behind it. C4 was
# one instance (a missing directory); this is a different one, and the loop must
# survive both.
@test "--drain: a task that fails mid-landing does not stop the ones after it" {
  # a REGULAR FILE where this task's destination needs a directory, so
  # atomic_write's `mkdir -p` fails and the write aborts under set -e
  printf 'not a directory\n' > "$VAULT_DIR/00 Inbox/blocked"
  mk_task aaa-fail research complete standard "00 Inbox/blocked/aaa-fail.md"
  mk_task zzz-ok  research complete standard "00 Inbox/2026-01-02-research-zzz-ok.md"
  run scripts/cerebro/cb-land --drain
  [ "$status" -eq 0 ]
  [[ "$output" == *"! failed: aaa-fail"* ]]        # named, not swallowed
  [[ "$output" != *"+ landed: aaa-fail"* ]]        # and NOT announced as landed
  [[ "$output" == *"+ landed: zzz-ok"* ]]          # and the queue kept going
  [ -f "$VAULT_DIR/00 Inbox/2026-01-02-research-zzz-ok.md" ]
  [ ! -f "$CB_HOME/tasks/aaa-fail/landed" ]
  [ "$(git -C "$VAULT_DIR" log -1 --format=%s)" = "land: $LOCAL — 1 report(s)" ]
}
