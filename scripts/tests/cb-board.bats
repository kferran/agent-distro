setup() {
  load ../lib/classify.sh   # R12: decision-log helpers for arranging open decisions
  export CB_HOME="$BATS_TEST_TMPDIR/.cerebro"; export CB_VAULT="$BATS_TEST_TMPDIR/vault"
  mkdir -p "$CB_HOME/tasks/done1" "$CB_HOME/tasks/run1" "$CB_VAULT"
  printf -- '---\nstatus: complete\n---\n' > "$CB_HOME/tasks/done1/report.md"; printf running > "$CB_HOME/tasks/done1/status"
  printf running > "$CB_HOME/tasks/run1/status"
}
# 2026-08-11: Reports is a COUNT AND A POINTER, so done1 no longer has a line of
# its own — it is counted. The invariant this test has always guarded (the
# reading pile sits above Running) is asserted on the headline instead.
@test "renders board.md with the reports count above running" {
  run scripts/cerebro/cb-board
  [ -f "$CB_VAULT/board.md" ]
  grep -q '📄 Reports to read (1)' "$CB_VAULT/board.md"
  local rep_line running_line
  rep_line="$(grep -n '📄 Reports to read' "$CB_VAULT/board.md" | cut -d: -f1)"
  running_line="$(grep -n '⏳ Running' "$CB_VAULT/board.md" | cut -d: -f1)"
  [ "$rep_line" -lt "$running_line" ]
  # counted, never listed — and the count is the whole point: no silent truncation
  ! grep -q '^- done1 (ready-for-review)' "$CB_VAULT/board.md"
}

@test "section order: decisions, then reports, then Running, then Failed" {
  mkdir -p "$CB_HOME/tasks/fail1"
  printf -- '---\nstatus: failed\n---\n' > "$CB_HOME/tasks/fail1/report.md"
  run scripts/cerebro/cb-board
  [ "$status" -eq 0 ]
  local dec_line rep_line running_line failed_line
  dec_line="$(grep -n '⚠ Needs a decision' "$CB_VAULT/board.md" | cut -d: -f1)"
  rep_line="$(grep -n '📄 Reports to read' "$CB_VAULT/board.md" | cut -d: -f1)"
  running_line="$(grep -n '⏳ Running' "$CB_VAULT/board.md" | cut -d: -f1)"
  failed_line="$(grep -n '✗ Failed' "$CB_VAULT/board.md" | cut -d: -f1)"
  [ -n "$dec_line" ] && [ -n "$rep_line" ] && [ -n "$running_line" ] && [ -n "$failed_line" ]
  [ "$dec_line" -lt "$rep_line" ]
  [ "$rep_line" -lt "$running_line" ]
  [ "$running_line" -lt "$failed_line" ]
}

# 2026-08-11: empty sections are dropped, so an idle fleet renders the header and
# the decisions anchor and nothing else. "⚠ Needs a decision" is deliberately
# still unconditional — it is the live-attention set, and it is what distinguishes
# an idle board from a render that died halfway.
@test "empty task list renders a bare board — decisions anchor only, no crash" {
  export CB_HOME="$BATS_TEST_TMPDIR/.cerebro-empty"
  export CB_VAULT="$BATS_TEST_TMPDIR/vault-empty"
  mkdir -p "$CB_HOME/tasks" "$CB_VAULT"
  run scripts/cerebro/cb-board
  [ "$status" -eq 0 ]
  [ -f "$CB_VAULT/board.md" ]
  grep -q '^## Board — ' "$CB_VAULT/board.md"
  grep -q '⚠ Needs a decision (0)' "$CB_VAULT/board.md"
  for s in '📄 Reports to read' '⏳ Running' '⏸ Paused' '✓ Done' '✗ Failed' 'Needs relaunch'; do
    ! grep -q "$s" "$CB_VAULT/board.md"
  done
  ! grep -q '^- ' "$CB_VAULT/board.md"
}

# --- T21: code states, cost order (needs-input above ready-for-review), Done ---

mk_code_task() { # mk_code_task <slug> <current_task>
  local slug="$1" cur="$2"
  mkdir -p "$CB_HOME/tasks/$slug"
  local wt="$BATS_TEST_TMPDIR/wt-$slug"; mkdir -p "$wt/.ai/specs/$slug"
  printf 'kind=code\nworktree=%s\njira=EJA-1\nsession=%s\n' "$wt" "$slug" > "$CB_HOME/tasks/$slug/meta"
  printf -- '---\ncurrent_task: %s\n---\n' "$cur" > "$wt/.ai/specs/$slug/manifest.md"
}

# --- ❓ No open question (2026-08-04) ---
# needs-input has no state bucket in the case above — such a task reached this
# board ONLY through the decision projection. So when _decision_for declines to
# project (no gate signal, just a resume pointer), something else has to render it
# or fix 1 would silently falsify R13's own rationale at classify.sh:796, which
# justifies classifying an unprovable state as needs-input because it is
# "human-visible (board bucket + digest)".
# The fixture is the REAL shape of the two tasks that caused this: a live session,
# a manifest that has not moved in hours, and a quiet pane — classify.sh:800's
# R13 arm, which reads "I cannot establish what this is" as needs-input. The gate
# text available to describe it is `ship/complete`, which is not a question.
mk_stalled_code_task() { # mk_stalled_code_task <slug> <current_task>
  mk_code_task "$1" "$2"
  touch -d '2 hours ago' "$BATS_TEST_TMPDIR/wt-$1/.ai/specs/$1/manifest.md"
  export CB_SESSION_LIST_CMD="printf '$1\n'"
  export CB_PANE_CMD="true"      # quiet pane: no menu, no busy spinner, no wedge
}
@test "no-gate: a needs-input code task with no gate renders on its own line, but IS counted" {
  mk_stalled_code_task quiet ship/complete
  run scripts/cerebro/cb-board
  [ "$status" -eq 0 ]
  grep -q '❓ Stopped, no question asked (1)' "$CB_VAULT/board.md"
  grep -q 'quiet (needs-input at ship/complete, no gate declared)' "$CB_VAULT/board.md"
  # it stays OUT of the answerable list — there is nothing to answer …
  ! grep -q 'quiet (needs-input:' "$CB_VAULT/board.md"
  # … but it COUNTS, because a task with no question is still a task that stopped.
  # Changed 2026-08-07: the headline read "(0)" here while a real conductor sat
  # parked for two days under a heading that reads as nothing-to-do.
  grep -q '⚠ Needs a decision (1)' "$CB_VAULT/board.md"
}
@test "no-gate: the line is omitted entirely when nothing qualifies" {
  mk_code_task gated2 build/awaiting-approval
  export CB_SESSION_LIST_CMD="printf 'gated2\n'"
  run scripts/cerebro/cb-board
  ! grep -q "No open question" "$CB_VAULT/board.md"
  grep -q 'gated2 (needs-input: build/awaiting-approval)' "$CB_VAULT/board.md"
}
# It is state-derived, so it cannot become the phantom it replaces: nothing is
# written, and it clears the instant the classification changes.
@test "no-gate: the line clears itself when the task stops classifying needs-input" {
  mk_stalled_code_task quiet2 ship/complete
  run scripts/cerebro/cb-board
  grep -q 'quiet2 (needs-input at ship/complete' "$CB_VAULT/board.md"
  printf MERGED > "$CB_HOME/tasks/quiet2/pr.state"    # now terminal → done
  run scripts/cerebro/cb-board
  ! grep -q "No open question" "$CB_VAULT/board.md"
  grep -q 'quiet2' "$CB_VAULT/board.md"               # still on the board, under Done
}

# THE BOARD MUST NOT RE-PROJECT A SEALED KEY. The live-projection path does not
# read the fold — it recomputes _decision_for and dedupes against `open_decisions`,
# which returns nothing for a sealed key. So without the seal check the board would
# render "Needs a decision" while cb-digest (open_decisions_live) reads none: the
# same phantom, relocated to the surface Kyle actually looks at, and unclearable by
# answering because it is projected live rather than read from the log. It fires on
# the ORDINARY answered-gate window — cb-send writes `resolved`, and until the
# conductor clears `gate:` the task still classifies needs-input on the same key.
@test "sealed: an answered gate whose gate: is not yet cleared is NOT re-projected as a decision" {
  mk_code_task answered build/3-implement
  printf -- '---\ncurrent_task: build/3-implement\ngate: needs-input\ngate_question: one PR or two?\n---\n' \
    > "$BATS_TEST_TMPDIR/wt-answered/.ai/specs/answered/manifest.md"
  export CB_SESSION_LIST_CMD="printf 'answered\n'"
  k=$(_decision_key needs-input "one PR or two?")
  _decision_open "$CB_HOME/tasks/answered" "$k" needs-input "one PR or two?"
  _decision_resolve "$CB_HOME/tasks/answered" "$k"            # Kyle answered via cb-send
  run scripts/cerebro/cb-board
  [ "$status" -eq 0 ]
  ! grep -q 'answered (needs-input:' "$CB_VAULT/board.md"      # no phantom decision
  # Counted, but not as an answerable one — it lands in "Stopped, no question asked"
  # alongside the never-declared case (headline rule changed 2026-08-07).
  grep -q '⚠ Needs a decision (1)' "$CB_VAULT/board.md"
  # board and digest AGREE — this is the split classify.sh:106-114 warns about
  run open_decisions_live "$CB_HOME/tasks/answered"; [ -z "$output" ]
  # and the task is still visible, with an HONEST reason
  grep -q 'answered (needs-input at one PR or two?, answered — gate not cleared)' "$CB_VAULT/board.md"
}

# `blocked` is on this line too. cb-remediate only promotes to needs-relaunch AT
# THE CAP, so a blocked task under the cap would otherwise sit invisible while the
# robot quietly retried — a hole the projection suppression would have opened.
@test "no-gate: gate: blocked IS a signal — it still renders as a real blocked decision" {
  mk_stalled_code_task wedged ship/complete
  printf 'kind=code\nworktree=%s\njira=EJA-1\nsession=wedged\n' "$BATS_TEST_TMPDIR/wt-wedged" \
    > "$CB_HOME/tasks/wedged/meta"
  printf -- '---\ncurrent_task: ship/complete\ngate: blocked\n---\n' \
    > "$BATS_TEST_TMPDIR/wt-wedged/.ai/specs/wedged/manifest.md"
  touch -d '2 hours ago' "$BATS_TEST_TMPDIR/wt-wedged/.ai/specs/wedged/manifest.md"
  run scripts/cerebro/cb-board
  [ "$status" -eq 0 ]
  # `gate: blocked` IS a gate signal, so this one is a real decision, not the line
  grep -q 'wedged (blocked: ship/complete)' "$CB_VAULT/board.md"
}
@test "no-gate: a blocked task whose key is SEALED still renders, as blocked" {
  mk_stalled_code_task wedged2 ship/complete
  printf -- '---\ncurrent_task: ship/complete\ngate: blocked\n---\n' \
    > "$BATS_TEST_TMPDIR/wt-wedged2/.ai/specs/wedged2/manifest.md"
  touch -d '2 hours ago' "$BATS_TEST_TMPDIR/wt-wedged2/.ai/specs/wedged2/manifest.md"
  k=$(_decision_key blocked "ship/complete")
  _decision_open "$CB_HOME/tasks/wedged2" "$k" blocked "ship/complete"
  _decision_resolve "$CB_HOME/tasks/wedged2" "$k"
  run scripts/cerebro/cb-board
  ! grep -q 'wedged2 (blocked:' "$CB_VAULT/board.md"      # not a decision any more
  grep -q 'wedged2 (blocked at ship/complete, answered — gate not cleared)' "$CB_VAULT/board.md"
}

@test "needs-input renders above ready-for-review (cost order, now across the split)" {
  mk_code_task gated build/awaiting-approval
  export CB_SESSION_LIST_CMD="printf 'gated\n'"
  run scripts/cerebro/cb-board
  [ "$status" -eq 0 ]
  local ni rep
  ni="$(grep -n 'gated (needs-input' "$CB_VAULT/board.md" | cut -d: -f1)"
  rep="$(grep -n '📄 Reports to read' "$CB_VAULT/board.md" | cut -d: -f1)"
  [ -n "$ni" ] && [ -n "$rep" ]
  # the question is above the reading pile, which is now a count on one headline
  [ "$ni" -lt "$rep" ]
  grep -q '📄 Reports to read (1)' "$CB_VAULT/board.md"
  ! grep -q '^- done1 (ready-for-review)' "$CB_VAULT/board.md"
  # the gate itself is visible on the line
  grep -q 'gated (needs-input: build/awaiting-approval)' "$CB_VAULT/board.md"
}

# --- R6: paused tasks stay visible on the board (never silently dropped) ---

@test "a paused research task renders in a Paused section, not swallowed" {
  mkdir -p "$CB_HOME/tasks/waiting"
  printf 'paused: rate-limited until :30\n' > "$CB_HOME/tasks/waiting/status"
  export CB_WINDOW_LIST_CMD="printf 'waiting\n'"
  run scripts/cerebro/cb-board
  [ "$status" -eq 0 ]
  grep -q 'waiting' "$CB_VAULT/board.md"      # the paused slug appears somewhere
  grep -qi 'paused' "$CB_VAULT/board.md"      # under a Paused header
}

# --- T31: ℹ Auto-resumed FYI section from the events log ---

@test "auto-resume events render an FYI section with the attempt count" {
  mkdir -p "$CB_HOME/logs"
  printf '%s fix-b auto-resumed attempt 1/2 (spend-wedge)\n' "$(date -Is)" >> "$CB_HOME/logs/events"
  run scripts/cerebro/cb-board
  [ "$status" -eq 0 ]
  grep -q 'ℹ Auto-resumed (1)' "$CB_VAULT/board.md"
  grep -q 'fix-b.*attempt 1/2' "$CB_VAULT/board.md"
}

@test "no auto-resume events → FYI section omitted entirely" {
  run scripts/cerebro/cb-board
  [ "$status" -eq 0 ]
  ! grep -q 'Auto-resumed' "$CB_VAULT/board.md"
}

@test "auto-resume events older than the FYI window are dropped" {
  mkdir -p "$CB_HOME/logs"
  printf '%s fix-old auto-resumed attempt 1/2 (spend-wedge)\n' "$(date -Is -d '2 days ago')" >> "$CB_HOME/logs/events"
  printf '%s fix-new auto-resumed attempt 2/2 (spend-wedge)\n' "$(date -Is)" >> "$CB_HOME/logs/events"
  run scripts/cerebro/cb-board
  [ "$status" -eq 0 ]
  grep -q 'ℹ Auto-resumed (1)' "$CB_VAULT/board.md"
  grep -q 'fix-new' "$CB_VAULT/board.md"
  ! grep -q 'fix-old' "$CB_VAULT/board.md"
}

@test "done section lists a pr.state=MERGED task" {
  mk_code_task shipped ship/complete
  printf 'MERGED' > "$CB_HOME/tasks/shipped/pr.state"
  export CB_SESSION_LIST_CMD="printf ''"
  run scripts/cerebro/cb-board
  [ "$status" -eq 0 ]
  grep -q '✓ Done (1)' "$CB_VAULT/board.md"
  local done_line running_line
  running_line="$(grep -n '⏳ Running' "$CB_VAULT/board.md" | cut -d: -f1)"
  done_line="$(grep -n '✓ Done' "$CB_VAULT/board.md" | cut -d: -f1)"
  [ "$running_line" -lt "$done_line" ]
  # 2026-08-11: nothing failed here, and empty sections are now dropped — so
  # Failed is absent and the Done section runs to the end of the board.
  ! grep -q '✗ Failed' "$CB_VAULT/board.md"
  sed -n "${done_line},\$p" "$CB_VAULT/board.md" | grep -q '^- shipped$'
  # under the cap, so the whole list renders and nothing is elided
  ! grep -q 'older' "$CB_VAULT/board.md"
}

# --- 2026-08-11 board reduction: counts survive, item lists don't --------------
# The governing rule is NO SILENT TRUNCATION: a section may stop listing items,
# but the number it is not showing has to be on the board. A Done section that
# quietly showed 10 of 98 would be worse than the 100-line one it replaced.

@test "done: capped at the show limit, with the dropped count printed" {
  split_home
  for i in 1 2 3 4 5; do
    mkdir -p "$CB_HOME/tasks/d$i"; printf 'kind=code\n' > "$CB_HOME/tasks/d$i/meta"
    printf 'MERGED' > "$CB_HOME/tasks/d$i/pr.state"
    touch -d "$i hours ago" "$CB_HOME/tasks/d$i"   # d1 newest … d5 oldest
  done
  CB_BOARD_DONE_SHOW=2 run scripts/cerebro/cb-board
  [ "$status" -eq 0 ]
  grep -q '✓ Done (5) — 2 most recent' "$CB_VAULT/board.md"
  grep -q -- '- … and 3 older' "$CB_VAULT/board.md"
  # most recent BY TASK-DIR MTIME, not glob order — d1 is the newest
  grep -q '^- d1$' "$CB_VAULT/board.md"; grep -q '^- d2$' "$CB_VAULT/board.md"
  ! grep -q '^- d5$' "$CB_VAULT/board.md"
  # exactly the cap, plus the elision line
  local dl; dl="$(grep -n '✓ Done' "$CB_VAULT/board.md" | cut -d: -f1)"
  [ "$(sed -n "$((dl+1)),\$p" "$CB_VAULT/board.md" | grep -c '^- ')" -eq 3 ]
}

@test "done: at or under the cap the whole list renders and nothing is elided" {
  split_home
  for i in 1 2; do
    mkdir -p "$CB_HOME/tasks/d$i"; printf 'kind=code\n' > "$CB_HOME/tasks/d$i/meta"
    printf 'MERGED' > "$CB_HOME/tasks/d$i/pr.state"
  done
  CB_BOARD_DONE_SHOW=2 run scripts/cerebro/cb-board
  grep -q '✓ Done (2)$' "$CB_VAULT/board.md"
  ! grep -q 'most recent' "$CB_VAULT/board.md"
  ! grep -q 'older' "$CB_VAULT/board.md"
}

@test "failed: a count and a reason breakdown, no item list" {
  split_home
  for s in f1 f2 f3; do
    mkdir -p "$CB_HOME/tasks/$s"; printf -- '---\nstatus: failed\n---\n' > "$CB_HOME/tasks/$s/report.md"
  done
  printf 'DECLINED' > "$CB_HOME/tasks/f1/pr.state"
  run scripts/cerebro/cb-board
  [ "$status" -eq 0 ]
  grep -q '✗ Failed (3) — 1 PR(s) declined · 2 stopped before a PR' "$CB_VAULT/board.md"
  # the slugs are gone from the board, and the count is what replaces them
  for s in f1 f2 f3; do ! grep -q "^- $s\$" "$CB_VAULT/board.md"; done
  local fl; fl="$(grep -n '✗ Failed' "$CB_VAULT/board.md" | cut -d: -f1)"
  [ "$(sed -n "$((fl+1)),\$p" "$CB_VAULT/board.md" | grep -c '^- ')" -eq 0 ]
}

@test "reports: the pointer names the register as a SMALLER filtered view, not the same set" {
  split_home
  mkdir -p "$CB_HOME/tasks/r1"; printf -- '---\nstatus: complete\n---\n' > "$CB_HOME/tasks/r1/report.md"
  run scripts/cerebro/cb-board
  [ "$status" -eq 0 ]
  grep -q '📄 Reports to read (1)' "$CB_VAULT/board.md"
  grep -q 'cb-unlanded --blocking' "$CB_VAULT/board.md"
  # 101 of 259 board entries were absent from the register (2026-08-11): the
  # pointer must not read as "the same list, over there".
  grep -q 'smaller register' "$CB_VAULT/board.md"
  ! grep -q '^- r1 (ready-for-review)' "$CB_VAULT/board.md"
}

# --- R12 (step 12): "Needs you" projects the OPEN-DECISION SET, not last-state ---
# NB (2026-07-31): this case was written before cb-ask and the `declared` verb
# existed, so it staged "a decision the agent raised" with `_decision_open` —
# the only opener there was. `_decision_open` is now written by exactly one
# caller, cb-watch:45, and it is the watcher's HEURISTIC guess, not anything an
# agent raised; cb-ask's `declared` is the raised question. The anti-masking
# invariant is unchanged and still asserted here — it just names the right verb.
# cb-watch:60-67 already draws this same line for the resolve path.
@test "R12: Needs-you surfaces an open decision even after the task's state advanced (anti-masking)" {
  td="$CB_HOME/tasks/adv"; mkdir -p "$td"; printf 'kind=research\n' > "$td/meta"
  k=$(_decision_key needs-input "answer me"); _decision_declare "$td" "$k" needs-input "answer me"
  printf -- '---\nstatus: complete\n---\n' > "$td/report.md"   # current state = ready-for-review
  run scripts/cerebro/cb-board
  [ "$status" -eq 0 ]
  # the open decision is still under the decisions headline even though the task
  # advanced — and it is bracketed by the REPORTS headline, not by Running, so
  # the split can't let a question drift down into the reading pile
  needs_line="$(grep -n '⚠ Needs a decision' "$CB_VAULT/board.md" | cut -d: -f1)"
  rep_line="$(grep -n '📄 Reports to read' "$CB_VAULT/board.md" | cut -d: -f1)"
  gate_line="$(grep -n 'answer me' "$CB_VAULT/board.md" | head -1 | cut -d: -f1)"
  [ -n "$gate_line" ]
  [ "$gate_line" -gt "$needs_line" ] && [ "$gate_line" -lt "$rep_line" ]
}
@test "R12: a needs-input open decision is cost-ordered above a blocked one" {
  mkdir -p "$CB_HOME/tasks/ni" "$CB_HOME/tasks/bl"
  printf 'kind=research\n' > "$CB_HOME/tasks/ni/meta"; printf 'kind=research\n' > "$CB_HOME/tasks/bl/meta"
  _decision_open "$CB_HOME/tasks/ni" "$(_decision_key needs-input 'decide NI')" needs-input "decide NI"
  _decision_open "$CB_HOME/tasks/bl" "$(_decision_key blocked 'stuck BL')" blocked "stuck BL"
  run scripts/cerebro/cb-board
  ni_line="$(grep -n 'decide NI' "$CB_VAULT/board.md" | cut -d: -f1)"
  bl_line="$(grep -n 'stuck BL' "$CB_VAULT/board.md" | cut -d: -f1)"
  [ "$ni_line" -lt "$bl_line" ]
}
@test "R12: a resolved decision no longer surfaces on the board" {
  td="$CB_HOME/tasks/rz"; mkdir -p "$td"; printf 'kind=research\n' > "$td/meta"
  k=$(_decision_key needs-input "was open"); _decision_open "$td" "$k" needs-input "was open"; _decision_resolve "$td" "$k"
  run scripts/cerebro/cb-board
  run grep -q 'was open' "$CB_VAULT/board.md"; [ "$status" -ne 0 ]
}

# --- M6 T4: needs-relaunch bucket (exhausted-and-still-wedged code task) ---

@test "M6: needs-relaunch task renders on its own line as 'needs manual relaunch'" {
  CWT="$BATS_TEST_TMPDIR/wt"; mkdir -p "$CB_HOME/tasks/fix-b" "$CWT/.ai/specs/fix-b"
  printf 'kind=code\nworktree=%s\njira=EJA-9\nsession=fix-b\ntarget=ultron\n' "$CWT" > "$CB_HOME/tasks/fix-b/meta"
  printf -- '---\ncurrent_task: build/3-implement\n---\n' > "$CWT/.ai/specs/fix-b/manifest.md"
  touch -d '3 hours ago' "$CWT/.ai/specs/fix-b/manifest.md"
  printf '2' > "$CB_HOME/tasks/fix-b/remediation-count"
  local fixpanes; fixpanes="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)/fixtures/panes"
  CB_SESSION_LIST_CMD="printf 'fix-b\n'" CB_PANE_CMD="cat '$fixpanes/spend-wedge.txt'" \
    run scripts/cerebro/cb-board
  [ "$status" -eq 0 ]
  grep -q 'fix-b (needs manual relaunch)' "$CB_VAULT/board.md"
  # 2026-08-01: relaunch is not a decision (cb-watch:28 never logs one) and not
  # a report, so it carries its own count — and still sits in the attention area
  # above Running, which is what this test has always been guarding.
  grep -q '🔁 Needs relaunch (1)' "$CB_VAULT/board.md"
  local rl_line run_line
  rl_line="$(grep -n '🔁 Needs relaunch' "$CB_VAULT/board.md" | cut -d: -f1)"
  run_line="$(grep -n '⏳ Running' "$CB_VAULT/board.md" | cut -d: -f1)"
  [ "$rl_line" -lt "$run_line" ]
  # and it inflates neither of the two headline counts
  grep -q '⚠ Needs a decision (0)' "$CB_VAULT/board.md"
}

# --- 2026-07-31 board-accuracy: decision settlement (open_decisions_live) -----
# A folded-open decision must not outlive the question it asked. The verb is the
# discriminator: a watcher heuristic dies on any terminal evidence; a cb-ask
# `declared` question survives a finished report and dies only when work ships.

@test "settlement: a heuristic open decision is dropped once the task reports" {
  td="$CB_HOME/tasks/heur"; mkdir -p "$td"; printf 'kind=research\n' > "$td/meta"
  _decision_open "$td" "$(_decision_key blocked 'heuristic wedge guess')" blocked "heuristic wedge guess"
  printf -- '---\nstatus: complete\n---\n' > "$td/report.md"
  run scripts/cerebro/cb-board
  [ "$status" -eq 0 ]
  ! grep -q 'heuristic wedge guess' "$CB_VAULT/board.md"
}

@test "settlement: a DECLARED question survives a finished report (report never answers it)" {
  td="$CB_HOME/tasks/asked"; mkdir -p "$td"; printf 'kind=research\n' > "$td/meta"
  _decision_declare "$td" "$(_decision_key needs-input 'which carrier do I use')" needs-input "which carrier do I use"
  printf -- '---\nstatus: complete\n---\n' > "$td/report.md"
  run scripts/cerebro/cb-board
  [ "$status" -eq 0 ]
  grep -q 'which carrier do I use' "$CB_VAULT/board.md"
  # and it is inside the decisions section, not stranded in the reports pile —
  # this task is ready-for-review AND still asking, so it must land in both
  # counts, once each
  nl="$(grep -n '⚠ Needs a decision' "$CB_VAULT/board.md" | cut -d: -f1)"
  rl="$(grep -n '📄 Reports to read' "$CB_VAULT/board.md" | cut -d: -f1)"
  gl="$(grep -n 'which carrier do I use' "$CB_VAULT/board.md" | head -1 | cut -d: -f1)"
  [ "$gl" -gt "$nl" ] && [ "$gl" -lt "$rl" ]
  # once in each count, never twice in one
  [ "$(grep -c 'which carrier do I use' "$CB_VAULT/board.md")" -eq 1 ]
  # 2026-08-11: the reports side of "both counts" is now the count itself — the
  # task is still in it, it just no longer gets a line. Two here: `asked` plus
  # the shared setup()'s done1.
  grep -q '📄 Reports to read (2)' "$CB_VAULT/board.md"
}

@test "settlement: a DECLARED question is dropped once the work ships (merged PR)" {
  td="$CB_HOME/tasks/shipped-q"; mkdir -p "$td"; printf 'kind=research\n' > "$td/meta"
  _decision_declare "$td" "$(_decision_key needs-input 'ship it or not')" needs-input "ship it or not"
  printf 'MERGED' > "$td/pr.state"
  run scripts/cerebro/cb-board
  [ "$status" -eq 0 ]
  ! grep -q 'ship it or not' "$CB_VAULT/board.md"
}

@test "settlement: with no terminal evidence every open decision still surfaces" {
  td="$CB_HOME/tasks/liveq"; mkdir -p "$td"; printf 'kind=research\n' > "$td/meta"
  _decision_open "$td" "$(_decision_key blocked 'still stuck here')" blocked "still stuck here"
  _decision_declare "$td" "$(_decision_key needs-input 'still asking here')" needs-input "still asking here"
  run scripts/cerebro/cb-board
  [ "$status" -eq 0 ]
  grep -q 'still stuck here' "$CB_VAULT/board.md"
  grep -q 'still asking here' "$CB_VAULT/board.md"
}

# This one guards the `_seen` split specifically, so the fixture has to keep
# classify in the `blocked` arm — cb-board only consults the live-projection
# path when st is needs-input/blocked. A terminal report.md would NOT do it:
# classify_research reads report.md FIRST (classify.sh:241-246) and returns
# ready-for-review, so the branch would never run and the test would pass
# vacuously. A MERGED pr.state is terminal for _task_terminal while leaving the
# beacon to drive classify → blocked, which is the combination that exercises it.
# --- 2026-08-01: two attention counts, decisions above reports ---------------
# One summed "⚠ Needs you (159)" hid 11 real questions inside 144 unread
# reports. The counts are now separate and neither may absorb the other's
# members: decisions IS the R12 open-decision set (needs-input + blocked,
# cb-watch:28), reports IS ready-for-review, relaunch is in neither set.
# Rendering only — classification is untouched.

# a scratch CB_HOME so the shared setup() fixtures can't skew the arithmetic
split_home() {
  export CB_HOME="$BATS_TEST_TMPDIR/.cerebro-split"; export CB_VAULT="$BATS_TEST_TMPDIR/vault-split"
  mkdir -p "$CB_HOME/tasks" "$CB_VAULT"
}

@test "split: known counts render on two headlines, nothing dropped or double-counted" {
  split_home
  for s in rep1 rep2 rep3; do
    mkdir -p "$CB_HOME/tasks/$s"; printf -- '---\nstatus: complete\n---\n' > "$CB_HOME/tasks/$s/report.md"
  done
  for s in q1 q2; do
    mkdir -p "$CB_HOME/tasks/$s"; printf 'kind=research\n' > "$CB_HOME/tasks/$s/meta"
    _decision_declare "$CB_HOME/tasks/$s" "$(_decision_key needs-input "ask $s")" needs-input "ask $s"
  done
  mkdir -p "$CB_HOME/tasks/b1"; printf 'kind=research\n' > "$CB_HOME/tasks/b1/meta"
  _decision_open "$CB_HOME/tasks/b1" "$(_decision_key blocked 'wedged b1')" blocked "wedged b1"
  run scripts/cerebro/cb-board
  [ "$status" -eq 0 ]
  grep -q '⚠ Needs a decision (3)' "$CB_VAULT/board.md"    # 2 needs-input + 1 blocked
  grep -q '📄 Reports to read (3)' "$CB_VAULT/board.md"
  # the headline counts match the list items actually rendered beneath them
  local dec rep run_line
  dec="$(grep -n '⚠ Needs a decision' "$CB_VAULT/board.md" | cut -d: -f1)"
  rep="$(grep -n '📄 Reports to read' "$CB_VAULT/board.md" | cut -d: -f1)"
  run_line="$(grep -n '⏳ Running' "$CB_VAULT/board.md" | cut -d: -f1)"
  [ "$(sed -n "$((dec+1)),$((rep-1))p" "$CB_VAULT/board.md" | grep -c '^- ')" -eq 3 ]
  # 2026-08-11: Reports carries its members in the count, not in item lines — so
  # the assertion is that it renders NONE, and the (3) above is the whole record.
  [ "$(sed -n "$((rep+1)),$((run_line-1))p" "$CB_VAULT/board.md" | grep -c '^- ')" -eq 0 ]
  # and no report leaked into the decisions section
  ! sed -n "$((dec+1)),$((rep-1))p" "$CB_VAULT/board.md" | grep -q 'ready-for-review'
}

@test "split: decisions + reports + relaunch equals the old summed Needs-you total" {
  split_home
  mkdir -p "$CB_HOME/tasks/rep1"; printf -- '---\nstatus: complete\n---\n' > "$CB_HOME/tasks/rep1/report.md"
  mkdir -p "$CB_HOME/tasks/q1"; printf 'kind=research\n' > "$CB_HOME/tasks/q1/meta"
  _decision_declare "$CB_HOME/tasks/q1" "$(_decision_key needs-input 'ask q1')" needs-input "ask q1"
  CWT="$BATS_TEST_TMPDIR/wt-sum"; mkdir -p "$CB_HOME/tasks/fix-s" "$CWT/.ai/specs/fix-s"
  printf 'kind=code\nworktree=%s\njira=EJA-9\nsession=fix-s\ntarget=ultron\n' "$CWT" > "$CB_HOME/tasks/fix-s/meta"
  printf -- '---\ncurrent_task: build/3-implement\n---\n' > "$CWT/.ai/specs/fix-s/manifest.md"
  touch -d '3 hours ago' "$CWT/.ai/specs/fix-s/manifest.md"
  printf '2' > "$CB_HOME/tasks/fix-s/remediation-count"
  local fixpanes; fixpanes="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)/fixtures/panes"
  CB_SESSION_LIST_CMD="printf 'fix-s\n'" CB_PANE_CMD="cat '$fixpanes/spend-wedge.txt'" \
    run scripts/cerebro/cb-board
  [ "$status" -eq 0 ]
  local d r l
  d="$(grep -oP '⚠ Needs a decision \(\K[0-9]+' "$CB_VAULT/board.md")"
  r="$(grep -oP '📄 Reports to read \(\K[0-9]+' "$CB_VAULT/board.md")"
  l="$(grep -oP '🔁 Needs relaunch \(\K[0-9]+' "$CB_VAULT/board.md")"
  [ "$d" -eq 1 ] && [ "$r" -eq 1 ] && [ "$l" -eq 1 ]
  [ "$(( d + r + l ))" -eq 3 ]   # what "⚠ Needs you (3)" used to print
}

@test "split: a blocked decision counts as a decision, never as a report" {
  split_home
  mkdir -p "$CB_HOME/tasks/b1"; printf 'kind=research\n' > "$CB_HOME/tasks/b1/meta"
  _decision_open "$CB_HOME/tasks/b1" "$(_decision_key blocked 'need creds')" blocked "need creds"
  run scripts/cerebro/cb-board
  [ "$status" -eq 0 ]
  grep -q '⚠ Needs a decision (1)' "$CB_VAULT/board.md"
  # 2026-08-11: zero reports means the Reports section is dropped entirely, which
  # is a stronger form of the same assertion — it is not counted as a report
  # anywhere, because there is no reports section at all.
  ! grep -q '📄 Reports to read' "$CB_VAULT/board.md"
  local dec
  dec="$(grep -n '⚠ Needs a decision' "$CB_VAULT/board.md" | cut -d: -f1)"
  [ "$(grep -n 'need creds' "$CB_VAULT/board.md" | cut -d: -f1)" -gt "$dec" ]
}

@test "settlement: a settled decision is not re-added by the live-projection path" {
  td="$CB_HOME/tasks/relive"; mkdir -p "$td"
  printf 'blocked: upstream 500s\n' > "$td/status"     # classify -> blocked (live)
  _decision_open "$td" "$(_decision_key blocked 'upstream 500s')" blocked "upstream 500s"
  printf 'MERGED' > "$td/pr.state"                     # hard terminal -> settles it
  export CB_WINDOW_LIST_CMD="printf 'relive\n'"
  run scripts/cerebro/cb-board
  [ "$status" -eq 0 ]
  ! grep -q 'upstream 500s' "$CB_VAULT/board.md"
}

# --- who is working what (2026-08-05) ----------------------------------------
# The board is where Kyle scans that, so the persisted X-Man name rides the live
# buckets. SUFFIXED after the state parenthetical: the decision lines are
# asserted byte-exact in board-markers.bats and are deliberately untouched.
@test "a running task renders its persisted X-Man name" {
  printf 'Storm\n' > "$CB_HOME/tasks/run1/xman"
  run scripts/cerebro/cb-board
  grep -q '^- run1 · 🦸 Storm$' "$CB_VAULT/board.md"
}
# 2026-08-11, a DELIBERATE LOSS, pinned here so it can't happen by accident:
# collapsing Reports to a count removes the only surface showing who wrote a
# report Kyle has not read. The name is still on disk at tasks/<slug>/xman and
# cb-unlanded can print it. Running and paused lines still carry it (above).
@test "a ready-for-review task's X-Man name is no longer on the board — it is in the count" {
  printf 'Magik\n' > "$CB_HOME/tasks/done1/xman"
  run scripts/cerebro/cb-board
  grep -q '📄 Reports to read (1)' "$CB_VAULT/board.md"
  ! grep -q 'Magik' "$CB_VAULT/board.md"
  [ "$(cat "$CB_HOME/tasks/done1/xman")" = Magik ]   # still recoverable, not deleted
}
@test "a task with no persisted name renders exactly as before (no invented name)" {
  # Tasks that ran before names were persisted had a RANDOM name announced in chat
  # and recorded nowhere. Deriving one now would contradict it, so the board shows
  # none — and rendering the board must not write into the task dirs either.
  run scripts/cerebro/cb-board
  grep -q '^- run1$' "$CB_VAULT/board.md"
  ! grep -q '🦸' "$CB_VAULT/board.md"
  [ ! -e "$CB_HOME/tasks/run1/xman" ]
}
