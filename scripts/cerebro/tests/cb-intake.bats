#!/usr/bin/env bats
# cb-intake (T32): hourly intake — queued dev items, atomic claim (flock),
# focus/cap gates. The status flip is the ONE sanctioned bash write to the
# vault; the actual dispatch stays LLM work (dispatch-request line).

setup() {
  export CB_HOME="$BATS_TEST_TMPDIR/.cerebro"; mkdir -p "$CB_HOME/tasks" "$CB_HOME/locks" "$CB_HOME/logs"
  export CB_VAULT="$BATS_TEST_TMPDIR/vault"
  ITEMS="$CB_VAULT/00 Inbox"; mkdir -p "$ITEMS"
  export CB_REGISTRY="$BATS_TEST_TMPDIR/projects.md"
  printf -- '- project: ultron\n  repo: ultron\n  base: main\n  checkout: %s\n  delivery: bitbucket-pr\n- project: friday\n  repo: friday\n  checkout: %s\n  delivery: research-only\n' "$BATS_TEST_TMPDIR" "$BATS_TEST_TMPDIR" > "$CB_REGISTRY"
  # plenty of RAM, no live agents
  printf 'MemAvailable:   33554432 kB\n' > "$BATS_TEST_TMPDIR/meminfo"
  export CB_FREE_CMD="cat '$BATS_TEST_TMPDIR/meminfo'"
  export CB_SESSION_LIST_CMD="printf ''"
  export CB_WINDOW_LIST_CMD="printf ''"
  export CB_TMUX_BIN="$BATS_TEST_TMPDIR/faketmux"
  cat > "$CB_TMUX_BIN" <<'EOF'
#!/usr/bin/env bash
echo "tmux $*" >> "$CB_TMUX_LOG"
EOF
  chmod +x "$CB_TMUX_BIN"; export CB_TMUX_LOG="$BATS_TEST_TMPDIR/tmux.log"
  export CB_SEND_DELAY=0   # dispatch-request Enter-splits (7/13 hotfix); no pause under the mock
  export CB_AGENT_CAP=3    # pin the cap the slot-count tests assume (runtime default drifted 3→6, 7/17)
}

mk_item() { # mk_item <slug> <status> <repo>
  printf -- '---\nslug: %s\nstatus: %s\nrepo: %s\ndomain: forms\n---\n\n# %s\n\nGoal text.\n' \
    "$1" "$2" "$3" "$1" > "$ITEMS/$1.md"
}

@test "queued deliverable item → status flipped + dispatch-request + FYI event" {
  mk_item fix-q queued ultron
  run scripts/cerebro/cb-intake --tick
  [ "$status" -eq 0 ]
  grep -q '^status: active' "$ITEMS/fix-q.md"
  ! grep -q '^status: queued' "$ITEMS/fix-q.md"
  grep -q 'send-keys -t Cerebro dispatch-request fix-q' "$CB_TMUX_LOG"
  grep -q 'fix-q intake-claimed' "$CB_HOME/logs/events"
}

mk_sev() { # mk_sev <slug> <status> <repo> <severity>
  printf -- '---\nslug: %s\nstatus: %s\nrepo: %s\ndomain: forms\nseverity: %s\n---\n\n# %s\n' \
    "$1" "$2" "$3" "$4" "$1" > "$ITEMS/$1.md"
}

@test "severity leads the claim order — Blocker before an alphabetically-earlier Medium (1 slot)" {
  mk_sev aaa-medium  queued ultron Medium    # sorts FIRST by filename
  mk_sev mmm-high    queued ultron High
  mk_sev zzz-blocker queued ultron Blocker   # sorts LAST by filename
  export CB_WINDOW_LIST_CMD="printf 'r1\nr2\n'"   # 2 live, cap 3 → 1 slot
  run scripts/cerebro/cb-intake --tick
  [ "$status" -eq 0 ]
  grep -q '^status: active' "$ITEMS/zzz-blocker.md"   # the Blocker claims the slot
  grep -q '^status: queued' "$ITEMS/aaa-medium.md"    # despite sorting first alphabetically
  grep -q '^status: queued' "$ITEMS/mmm-high.md"
  grep -q 'dispatch-request zzz-blocker' "$CB_TMUX_LOG"
}

@test "severity fills slots Blocker→High→Medium (2 slots)" {
  mk_sev aaa-medium  queued ultron Medium
  mk_sev mmm-high    queued ultron High
  mk_sev zzz-blocker queued ultron Blocker
  export CB_WINDOW_LIST_CMD="printf 'r1\n'"   # 1 live, cap 3 → 2 slots
  run scripts/cerebro/cb-intake --tick
  [ "$status" -eq 0 ]
  grep -q '^status: active' "$ITEMS/zzz-blocker.md"   # 1st
  grep -q '^status: active' "$ITEMS/mmm-high.md"      # 2nd
  grep -q '^status: queued' "$ITEMS/aaa-medium.md"    # Medium waits
}

@test "unranked (no severity) item ranks after a ranked one — even when it sorts first alphabetically" {
  mk_item aaa-plain queued ultron             # no severity, sorts FIRST alphabetically
  mk_sev  zzz-high  queued ultron High        # ranked, sorts LAST alphabetically
  export CB_WINDOW_LIST_CMD="printf 'r1\nr2\n'"   # 1 slot
  run scripts/cerebro/cb-intake --tick
  [ "$status" -eq 0 ]
  grep -q '^status: active' "$ITEMS/zzz-high.md"    # ranked High claims the slot
  grep -q '^status: queued' "$ITEMS/aaa-plain.md"   # unranked waits, despite sorting first
}

@test "two concurrent ticks → exactly one flip (flock)" {
  mk_item fix-race queued ultron
  scripts/cerebro/cb-intake --tick & scripts/cerebro/cb-intake --tick & wait
  [ "$(grep -c 'dispatch-request fix-race' "$CB_TMUX_LOG")" = "1" ]
  [ "$(grep -c '^status: active' "$ITEMS/fix-race.md")" = "1" ]
}

# M5#6 — the budget race. `live_agents` / `slots` / `memcap_ok` used to be
# computed BEFORE `flock 9`, so two overlapping ticks each read the same pre-lock
# state, each concluded it had a free slot, and together claimed past
# CB_AGENT_CAP. The in-lock re-check only tests `status: queued`, which bounds
# per-ITEM double-claim (the test above) but not the BUDGET.
#
# The stub models the causal chain the cap protects: a claimed item is a live
# agent, so the window list is derived from how many items are `active`.
#
_live_from_active_stub() {  # one line per active item; no synchronisation
  cat > "$BATS_TEST_TMPDIR/livecount" <<EOF
#!/usr/bin/env bash
grep -l '^status: active' "$ITEMS"/*.md 2>/dev/null | sed 's|.*/|agent-|'
EOF
  chmod +x "$BATS_TEST_TMPDIR/livecount"
  export CB_WINDOW_LIST_CMD="$BATS_TEST_TMPDIR/livecount"
}

# Same derivation, plus a BARRIER — that is what makes the race deterministic
# rather than a timing coin-flip. A plain sleep is not enough: launched together,
# the two ticks still reached the compute stage ~2.2s apart (each runs a reap
# sweep and two promote passes first, and they contend), so one finished before
# the other computed and the test passed against the UNFIXED code. The barrier
# forces the exact interleaving the defect needs — each tick announces arrival in
# the compute stage and waits for the other.
#   - budget OUTSIDE the lock: both ticks rendezvous, both read 0 active, both
#     conclude they hold the only slot → 2 claims against a cap of 1.
#   - budget INSIDE the lock: the second tick is still blocked on `flock` and can
#     never arrive, so the first waits out the ceiling. That timeout IS the proof
#     of mutual exclusion — the second tick then computes fresh against the
#     first's claim, sees 1 active, and stands down.
# The ceiling has to clear the observed ~2.2s startup skew with margin; the fixed
# path pays it once, which is why only this test uses the barrier stub.
# Order matters inside the stub: READ the active set, THEN rendezvous, THEN
# report. Announcing arrival first is not enough — with the barrier ahead of the
# read, the first tick could still claim before the second tick's read completed,
# so the second read saw 1 active and the race evaporated (observed: arrivals
# 11ms apart, still only one claim). Reading first pins both ticks to the same
# pre-claim snapshot, which is precisely the stale-budget premise of the defect.
_live_barrier_stub() {
  cat > "$BATS_TEST_TMPDIR/livecount" <<EOF
#!/usr/bin/env bash
seen="\$(grep -l '^status: active' "$ITEMS"/*.md 2>/dev/null | sed 's|.*/|agent-|')"
echo arrived >> "$BATS_TEST_TMPDIR/barrier"
for _ in \$(seq 120); do                     # ~6s ceiling, then proceed alone
  [ "\$(wc -l < "$BATS_TEST_TMPDIR/barrier")" -ge 2 ] && break
  sleep 0.05
done
[ -n "\$seen" ] && printf '%s\n' "\$seen"
exit 0
EOF
  chmod +x "$BATS_TEST_TMPDIR/livecount"
  : > "$BATS_TEST_TMPDIR/barrier"
  export CB_WINDOW_LIST_CMD="$BATS_TEST_TMPDIR/livecount"
}

@test "M5#6: two concurrent ticks cannot claim past CB_AGENT_CAP (budget inside the lock)" {
  mk_item race-a queued ultron
  mk_item race-b queued ultron
  export CB_AGENT_CAP=1          # exactly one slot for the whole fleet
  # CB_PROMOTE=0 is not a contrivance — it is what UNMASKS the defect. In the
  # default config `promote_drafting` (lib/queue.sh:199) opens fd 8 on
  # locks/promote-drafting and never releases it, so the lock is held for the
  # whole process and a second tick blocks there until the first EXITS. That
  # incidentally serialises the two ticks end-to-end and hides the budget race.
  # `CB_PROMOTE=0` returns at queue.sh:196, BEFORE that lock is taken (a
  # documented, supported config) — and then the ticks genuinely overlap. Cap
  # safety must not rest on an unrelated lock's accidental scope.
  export CB_PROMOTE=0
  _live_barrier_stub
  scripts/cerebro/cb-intake --tick & scripts/cerebro/cb-intake --tick & wait
  # the cap is 1 — across BOTH ticks, exactly one item may be claimed
  claimed="$(grep -l '^status: active' "$ITEMS"/race-*.md 2>/dev/null | wc -l)"
  [ "$claimed" -eq 1 ]
  [ "$(grep -c 'dispatch-request race-' "$CB_TMUX_LOG")" = "1" ]
  # the loser recorded WHY it claimed nothing, rather than silently passing
  grep -q 'at capacity' "$CB_HOME/logs/events"
}

@test "M5#6: the second tick sees the first tick's claim as consumed capacity" {
  mk_item solo-a queued ultron
  export CB_AGENT_CAP=1
  _live_from_active_stub
  run scripts/cerebro/cb-intake --tick          # tick 1 claims the only slot
  [ "$status" -eq 0 ]
  grep -q '^status: active' "$ITEMS/solo-a.md"
  mk_item solo-b queued ultron
  run scripts/cerebro/cb-intake --tick          # tick 2: live=1, cap=1 → no slot
  [ "$status" -eq 0 ]
  grep -q '^status: queued' "$ITEMS/solo-b.md"
  grep -q 'at capacity' "$CB_HOME/logs/events"
}

# M5#2 — the claim flip used to happen before an UNGUARDED send. Under
# `set -euo pipefail` a failing `tmux send-keys` aborted the tick outright,
# leaving the item `status: active` but never dispatched; every later tick then
# skipped it because it was no longer `queued`. Stranded, silently, forever.
_failing_tmux() {  # a tmux stub that fails on the Nth send-keys call ("" = all)
  cat > "$CB_TMUX_BIN" <<EOF
#!/usr/bin/env bash
echo "tmux \$*" >> "\$CB_TMUX_LOG"
n=\$(( \$(cat "$BATS_TEST_TMPDIR/sendn" 2>/dev/null || echo 0) + 1 ))
echo "\$n" > "$BATS_TEST_TMPDIR/sendn"
case "\${1:-}" in send-keys) [ -z "$1" ] || [ "\$n" = "$1" ] && exit 1;; esac
exit 0
EOF
  chmod +x "$CB_TMUX_BIN"
}

@test "M5#2: a failed dispatch send rolls the claim back to queued" {
  mk_item strand-a queued ultron
  _failing_tmux 1                     # the FIRST send-keys fails — nothing was delivered
  run scripts/cerebro/cb-intake --tick
  [ "$status" -eq 0 ]                 # the tick survives; it does not die under errexit
  grep -q '^status: queued' "$ITEMS/strand-a.md"     # rolled back — reclaimable next tick
  ! grep -q '^status: active' "$ITEMS/strand-a.md"
  grep -q 'strand-a dispatch-send-failed (claim rolled back to queued)' "$CB_HOME/logs/events"
  ! grep -q 'strand-a intake-claimed' "$CB_HOME/logs/events"
}

@test "M5#2: a rolled-back item is claimable again on the next tick" {
  mk_item strand-b queued ultron
  _failing_tmux 1
  run scripts/cerebro/cb-intake --tick
  grep -q '^status: queued' "$ITEMS/strand-b.md"
  # tmux healthy again — the item must not have been stranded out of the queue
  printf '#!/usr/bin/env bash\necho "tmux $*" >> "$CB_TMUX_LOG"\n' > "$CB_TMUX_BIN"
  chmod +x "$CB_TMUX_BIN"
  run scripts/cerebro/cb-intake --tick
  [ "$status" -eq 0 ]
  grep -q '^status: active' "$ITEMS/strand-b.md"
  grep -q 'dispatch-request strand-b' "$CB_TMUX_LOG"
}

@test "M5#2: a failed Enter after the text landed stays active — never re-queued" {
  # The text IS in the coordinator composer and may still be submitted. Rolling
  # back here would re-queue an item whose dispatch can still fire = the exact
  # double-dispatch this gate exists to make impossible. Hold `active`, page it.
  mk_item strand-c queued ultron
  _failing_tmux 2                     # send-keys #1 (the text) ok, #2 (Enter) fails
  run scripts/cerebro/cb-intake --tick
  [ "$status" -eq 0 ]
  grep -q '^status: active' "$ITEMS/strand-c.md"
  ! grep -q '^status: queued' "$ITEMS/strand-c.md"
  grep -q 'strand-c dispatch-send-UNCONFIRMED' "$CB_HOME/logs/events"
}

@test "M5#2: a send failure stops the tick — it does not claim further items" {
  mk_item strand-d queued ultron
  mk_item strand-e queued ultron
  export CB_MAX_CLAIM_PER_TICK=2
  _failing_tmux ""                    # every send fails
  run scripts/cerebro/cb-intake --tick
  [ "$status" -eq 0 ]
  grep -q '^status: queued' "$ITEMS/strand-d.md"
  grep -q '^status: queued' "$ITEMS/strand-e.md"
  # only ONE attempt — a dead coordinator is not retried down the whole queue
  [ "$(grep -c 'dispatch-send-failed' "$CB_HOME/logs/events")" = "1" ]
}

# R5 — serialization at claim time, inside the same critical section as the
# budget. Intake has no human to read a warning, so it holds an item only on a
# DECLARED file overlap; a same-subsystem hit would stall the queue on a
# judgement call nobody is there to make, and cb-start surfaces that to a person.
_mk_live_worktree() {   # _mk_live_worktree <slug> <file>...
  local slug="$1"; shift; local wt="$BATS_TEST_TMPDIR/wt-$slug" f
  mkdir -p "$wt"; git -C "$wt" init -q -b main
  git -C "$wt" config user.email t@t; git -C "$wt" config user.name t
  echo seed > "$wt/seed"; git -C "$wt" add seed; git -C "$wt" commit -qm seed
  git -C "$wt" update-ref refs/remotes/origin/main HEAD
  for f in "$@"; do mkdir -p "$wt/$(dirname "$f")"; echo c > "$wt/$f"; done
  git -C "$wt" add -A; git -C "$wt" commit -qm work
  mkdir -p "$CB_HOME/tasks/$slug"
  printf 'kind=code\nworktree=%s\njira=\nsession=%s\ntarget=ultron\n' "$wt" "$slug" > "$CB_HOME/tasks/$slug/meta"
  printf -- '---\nslug: %s\nstatus: active\nrepo: ultron\ndomain: forms\n---\n' "$slug" > "$ITEMS/$slug.md"
  export CB_SESSION_LIST_CMD="printf '$slug\n'"
}

@test "R5: a queued item whose declared files a live conductor holds stays queued" {
  _mk_live_worktree busy src/forms/Stamp.cs
  printf -- '---\nslug: coll\nstatus: queued\nrepo: ultron\ndomain: forms\nfiles: src/forms/Stamp.cs\n---\n' > "$ITEMS/coll.md"
  export CB_AGENT_CAP=9
  run scripts/cerebro/cb-intake --tick
  [ "$status" -eq 0 ]
  grep -q '^status: queued' "$ITEMS/coll.md"          # deferred, NOT claimed
  ! grep -q 'dispatch-request coll' "$CB_TMUX_LOG"
  grep -q 'coll intake-deferred (R5' "$CB_HOME/logs/events"
  # the event names WHO holds it and WHICH file — a defer that never un-defers
  # is otherwise a mystery Kyle has to re-derive by hand
  grep -q 'busy' "$CB_HOME/logs/events"
  grep -q 'src/forms/Stamp.cs' "$CB_HOME/logs/events"
}

@test "R5: a deferred item is claimed on a later tick once the conductor is gone" {
  _mk_live_worktree busy src/forms/Stamp.cs
  printf -- '---\nslug: coll2\nstatus: queued\nrepo: ultron\ndomain: forms\nfiles: src/forms/Stamp.cs\n---\n' > "$ITEMS/coll2.md"
  export CB_AGENT_CAP=9
  run scripts/cerebro/cb-intake --tick
  grep -q '^status: queued' "$ITEMS/coll2.md"
  export CB_SESSION_LIST_CMD="printf ''"              # the other conductor exits
  run scripts/cerebro/cb-intake --tick
  [ "$status" -eq 0 ]
  grep -q '^status: active' "$ITEMS/coll2.md"
  grep -q 'dispatch-request coll2' "$CB_TMUX_LOG"
}

@test "R5: same subsystem but no declared overlap does NOT hold the queue" {
  _mk_live_worktree busy src/forms/Other.cs
  printf -- '---\nslug: near\nstatus: queued\nrepo: ultron\ndomain: forms\n---\n' > "$ITEMS/near.md"
  export CB_AGENT_CAP=9
  run scripts/cerebro/cb-intake --tick
  [ "$status" -eq 0 ]
  grep -q '^status: active' "$ITEMS/near.md"          # a warn must never stall intake
  grep -q 'dispatch-request near' "$CB_TMUX_LOG"
}

@test "mode=focus suspends intake silently" {
  mk_item fix-f queued ultron
  printf 'focus' > "$CB_HOME/mode"
  run scripts/cerebro/cb-intake --tick
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  grep -q '^status: queued' "$ITEMS/fix-f.md"
  [ ! -s "$CB_TMUX_LOG" ]
}

@test "agent cap reached → queued survives + capacity event" {
  mk_item fix-c queued ultron
  export CB_WINDOW_LIST_CMD="printf 'r1\nr2\nr3\n'"   # 3 research agents ≥ cap 3
  run scripts/cerebro/cb-intake --tick
  [ "$status" -eq 0 ]
  grep -q '^status: queued' "$ITEMS/fix-c.md"
  grep -q 'at capacity' "$CB_HOME/logs/events"
  grep -q '1 queued' "$CB_HOME/logs/events"
}

@test "memcap failure (low RAM) → queued survives + capacity event" {
  mk_item fix-m queued ultron
  printf 'MemAvailable:   1048576 kB\n' > "$BATS_TEST_TMPDIR/meminfo"   # 1 GB
  run scripts/cerebro/cb-intake --tick
  [ "$status" -eq 0 ]
  grep -q '^status: queued' "$ITEMS/fix-m.md"
  grep -q 'at capacity' "$CB_HOME/logs/events"
}

@test "research-only repo and no-repo items are not claimed" {
  mk_item probe-r queued friday
  printf -- '---\nslug: norepo\nstatus: queued\n---\n' > "$ITEMS/norepo.md"
  run scripts/cerebro/cb-intake --tick
  [ "$status" -eq 0 ]
  grep -q '^status: queued' "$ITEMS/probe-r.md"
  grep -q '^status: queued' "$ITEMS/norepo.md"
  [ ! -s "$CB_TMUX_LOG" ]
}

@test "claims only up to the free capacity slots" {
  mk_item fix-1 queued ultron
  mk_item fix-2 queued ultron
  mk_item fix-3 queued ultron
  export CB_WINDOW_LIST_CMD="printf 'r1\nr2\n'"   # 2 live, cap 3 → 1 slot
  run scripts/cerebro/cb-intake --tick
  [ "$status" -eq 0 ]
  [ "$(grep -l '^status: active' "$ITEMS"/fix-*.md | wc -l)" = "1" ]
  [ "$(grep -c 'dispatch-request' "$CB_TMUX_LOG")" = "1" ]
}

@test "a queued item with a malformed slug is skipped, not claimed" {
  printf -- '---\nslug: bad;slug\nstatus: queued\nrepo: ultron\ndomain: forms\n---\n' > "$ITEMS/badslug.md"
  mk_item fix-ok queued ultron
  run scripts/cerebro/cb-intake --tick
  [ "$status" -eq 0 ]
  grep -q '^status: queued' "$ITEMS/badslug.md"          # not claimed
  grep -q 'intake-skipped (invalid slug)' "$CB_HOME/logs/events"
  grep -q '^status: active' "$ITEMS/fix-ok.md"           # the good one still processed
}

@test "non-queued statuses untouched" {
  mk_item fix-a active ultron
  mk_item fix-d drafting ultron
  run scripts/cerebro/cb-intake --tick
  [ ! -s "$CB_TMUX_LOG" ]
  grep -q '^status: active' "$ITEMS/fix-a.md"
  grep -q '^status: drafting' "$ITEMS/fix-d.md"
}

# --- task_type routing (2026-07-17): ops/research items bypass the
# deliverable-repo gate (claim on queued + valid slug alone); code (default)
# still requires a deliverable registry row. The dispatch-request line is
# type-agnostic — the dispatch skill reads task_type and picks the cb-start mode.

mk_ops() { # mk_ops <slug> <status>
  printf -- '---\nslug: %s\nstatus: %s\ntask_type: ops\ndomain: tooling\n---\n\n# %s\n' "$1" "$2" "$1" > "$ITEMS/$1.md"
}

@test "queued task_type:ops item is claimed without a deliverable repo" {
  mk_ops sweep-q queued
  run scripts/cerebro/cb-intake --tick
  [ "$status" -eq 0 ]
  grep -q '^status: active' "$ITEMS/sweep-q.md"
  grep -q 'dispatch-request sweep-q' "$CB_TMUX_LOG"
  grep -q 'sweep-q intake-claimed' "$CB_HOME/logs/events"
}

@test "queued task_type:research item is claimed without a deliverable repo" {
  printf -- '---\nslug: probe-q\nstatus: queued\ntask_type: research\n---\n' > "$ITEMS/probe-q.md"
  run scripts/cerebro/cb-intake --tick
  [ "$status" -eq 0 ]
  grep -q '^status: active' "$ITEMS/probe-q.md"
  grep -q 'dispatch-request probe-q' "$CB_TMUX_LOG"
}

@test "no-task_type no-deliverable-repo item still NOT claimed (default code gate holds)" {
  printf -- '---\nslug: norepo2\nstatus: queued\n---\n' > "$ITEMS/norepo2.md"
  run scripts/cerebro/cb-intake --tick
  [ "$status" -eq 0 ]
  grep -q '^status: queued' "$ITEMS/norepo2.md"
}

@test "task_type:code with a non-deliverable repo is NOT claimed" {
  printf -- '---\nslug: codef\nstatus: queued\ntask_type: code\nrepo: friday\n---\n' > "$ITEMS/codef.md"
  run scripts/cerebro/cb-intake --tick
  [ "$status" -eq 0 ]
  grep -q '^status: queued' "$ITEMS/codef.md"
}

@test "a queued item carrying hold: is NOT claimed" {
  printf -- '---\nslug: heldx\nstatus: queued\nrepo: ultron\ndomain: forms\nhold: waiting on a product call\n---\n' > "$ITEMS/heldx.md"
  run scripts/cerebro/cb-intake --tick
  [ "$status" -eq 0 ]
  grep -q '^status: queued' "$ITEMS/heldx.md"                        # left alone, never flipped
  ! grep -q 'dispatch-request heldx' "$CB_TMUX_LOG" 2>/dev/null      # and never dispatched
}

@test "the hold skip is logged so a held item is visible, not silently dropped" {
  printf -- '---\nslug: heldy\nstatus: queued\nrepo: ultron\ndomain: forms\nhold: blocked on EJA-1\n---\n' > "$ITEMS/heldy.md"
  run scripts/cerebro/cb-intake --tick
  grep -q 'intake skipped heldy (hold: blocked on EJA-1)' "$CB_HOME/logs/events"
}

@test "an EMPTY hold: does not block a claim (only a written reason gates)" {
  printf -- '---\nslug: nohold\nstatus: queued\nrepo: ultron\ndomain: forms\nhold:\n---\n' > "$ITEMS/nohold.md"
  run scripts/cerebro/cb-intake --tick
  grep -q '^status: active' "$ITEMS/nohold.md"
  grep -q 'send-keys -t Cerebro dispatch-request nohold' "$CB_TMUX_LOG"
}

@test "an unknown task_type is skipped (not claimed)" {
  printf -- '---\nslug: weird\nstatus: queued\ntask_type: banana\n---\n' > "$ITEMS/weird.md"
  run scripts/cerebro/cb-intake --tick
  [ "$status" -eq 0 ]
  grep -q '^status: queued' "$ITEMS/weird.md"
}

@test "ops item respects the agent cap (counts against slots)" {
  mk_ops sweep-cap queued
  export CB_WINDOW_LIST_CMD="printf 'r1\nr2\nr3\n'"   # 3 ≥ cap 3
  run scripts/cerebro/cb-intake --tick
  [ "$status" -eq 0 ]
  grep -q '^status: queued' "$ITEMS/sweep-cap.md"
  grep -q 'at capacity' "$CB_HOME/logs/events"
}

@test "ops item with a malformed slug is skipped, not claimed" {
  printf -- '---\nslug: bad;op\nstatus: queued\ntask_type: ops\n---\n' > "$ITEMS/badop.md"
  run scripts/cerebro/cb-intake --tick
  [ "$status" -eq 0 ]
  grep -q '^status: queued' "$ITEMS/badop.md"
  grep -q 'intake-skipped (invalid slug)' "$CB_HOME/logs/events"
}

@test "registry preflight: a MISSING registry is fatal, not a silent no-op" {
  # 2026-07-30 regression: projects.md was deleted by a commit-all from the Windows
  # clone; every code item then failed the deliverable gate and the tick reported
  # "nothing claimed" — indistinguishable from an empty queue.
  mk_item eja-9001 queued ultron
  rm -f "$CB_REGISTRY"
  run scripts/cerebro/cb-intake --tick
  [ "$status" -eq 3 ]
  [[ "$output" == *"registry not found"* ]]
  grep -q 'REGISTRY-MISSING' "$CB_HOME/logs/events"
  grep -q '^status: queued' "$ITEMS/eja-9001.md"      # item untouched, not claimed
}

@test "registry preflight: a registry with no deliverable ultron row is fatal" {
  mk_item eja-9002 queued ultron
  printf -- '- project: friday\n  repo: friday\n  delivery: research-only\n' > "$CB_REGISTRY"
  run scripts/cerebro/cb-intake --tick
  [ "$status" -eq 3 ]
  grep -q 'REGISTRY-UNRESOLVABLE' "$CB_HOME/logs/events"
  grep -q '^status: queued' "$ITEMS/eja-9002.md"
}

# --- Job A3: the strand janitor, end-to-end through the tick -----------------

@test "a claim writes the strand marker, carrying the item path" {
  mk_item mark-me queued ultron
  run scripts/cerebro/cb-intake --tick
  [ "$status" -eq 0 ]
  [ -f "$CB_HOME/claims/mark-me" ]
  grep -q "^item=$ITEMS/mark-me.md" "$CB_HOME/claims/mark-me"
  grep -q '^refires=0' "$CB_HOME/claims/mark-me"
}

@test "a rolled-back claim (send failed) takes its marker with it" {
  mk_item roll-back queued ultron
  cat > "$CB_TMUX_BIN" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
  chmod +x "$CB_TMUX_BIN"
  run scripts/cerebro/cb-intake --tick
  [ "$status" -eq 0 ]
  grep -q '^status: queued' "$ITEMS/roll-back.md"
  [ ! -f "$CB_HOME/claims/roll-back" ]
}

@test "the UNCONFIRMED path KEEPS the marker — that item is the textbook strand" {
  mk_item unconf queued ultron
  cat > "$CB_TMUX_BIN" <<'EOF'
#!/usr/bin/env bash
echo "tmux $*" >> "$CB_TMUX_LOG"
[ "${!#}" = "Enter" ] && exit 1 || exit 0
EOF
  chmod +x "$CB_TMUX_BIN"
  run scripts/cerebro/cb-intake --tick
  [ "$status" -eq 0 ]
  grep -q '^status: active' "$ITEMS/unconf.md"
  grep -q 'dispatch-send-UNCONFIRMED' "$CB_HOME/logs/events"
  [ -f "$CB_HOME/claims/unconf" ]
}

@test "the full strand cycle: swallowed dispatch -> re-fire -> revert -> re-claimable" {
  # the send SUCCEEDS every time (send-keys always does) but nothing ever spawns —
  # exactly the failure the M5#2 exit-code guard cannot see.
  export CB_STRAND_GRACE_SECS=0
  mk_item strandy queued ultron

  scripts/cerebro/cb-intake --tick                     # tick 1: claim
  grep -q '^status: active' "$ITEMS/strandy.md"
  [ -f "$CB_HOME/claims/strandy" ]

  : > "$CB_TMUX_LOG"
  scripts/cerebro/cb-intake --tick                     # tick 2: re-fire
  grep -q '^status: active' "$ITEMS/strandy.md"
  grep -q 'dispatch-request strandy' "$CB_TMUX_LOG"
  grep -q 'strandy strand-refired' "$CB_HOME/logs/events"

  run scripts/cerebro/cb-intake --tick                 # tick 3: revert + re-claim
  [ "$status" -eq 0 ]
  [[ "$output" == *"recovered 1 stranded dispatch"* ]]
  grep -q 'strandy strand-reverted' "$CB_HOME/logs/events"
  # recovery runs BEFORE the claim loop, so the same tick re-claims it
  grep -q '^status: active' "$ITEMS/strandy.md"
  [ "$(grep -c 'strandy intake-claimed' "$CB_HOME/logs/events")" -eq 2 ]
}

@test "a mid-spawn item survives the tick even with the grace window at zero" {
  export CB_STRAND_GRACE_SECS=0
  mk_item inflight queued ultron
  scripts/cerebro/cb-intake --tick                     # tick 1: claim
  mkdir -p "$CB_HOME/tasks/inflight"                   # cb-start is creating the worktree
  : > "$CB_TMUX_LOG"
  run scripts/cerebro/cb-intake --tick                 # tick 2
  [ "$status" -eq 0 ]
  grep -q '^status: active' "$ITEMS/inflight.md"
  ! grep -q 'dispatch-request inflight' "$CB_TMUX_LOG"
  ! grep -q 'inflight strand' "$CB_HOME/logs/events"
}

# --- timing: the hourly/overnight split (2026-08-15). `timing: overnight` items
# belong to the night shift's P7 drain, so the hourly tick must not see them as
# eligible at all. The two claimers are disjoint by construction: P7 takes exactly
# `status: queued` + `timing: overnight`, intake skips exactly that. Design:
# 99 Meta/specs/2026-08-15-nightshift-on-the-inbox-queue-design.md.
# `slug:` is on every fixture on purpose — queue.sh:284 vetoes promote_inbox on a
# file carrying slug: + a lifecycle status:, so without it promote_inbox re-mints
# the fixture as a drafting copy mid-tick.

mk_timing() { # mk_timing <slug> <status> <repo> <timing>
  printf -- '---\nslug: %s\nstatus: %s\nrepo: %s\ndomain: forms\ntiming: %s\n---\n\n# %s\n' \
    "$1" "$2" "$3" "$4" "$1" > "$ITEMS/$1.md"
}

@test "timing absent → claimed as today (the default clock is the hourly tick)" {
  mk_item no-timing queued ultron
  run scripts/cerebro/cb-intake --tick
  [ "$status" -eq 0 ]
  grep -q '^status: active' "$ITEMS/no-timing.md"
  grep -q 'dispatch-request no-timing' "$CB_TMUX_LOG"
  grep -q 'no-timing intake-claimed' "$CB_HOME/logs/events"
}

@test "timing: overnight is NOT claimed by the hourly tick" {
  mk_timing night-a queued ultron overnight
  run scripts/cerebro/cb-intake --tick
  [ "$status" -eq 0 ]
  grep -q '^status: queued' "$ITEMS/night-a.md"                        # left for P7
  ! grep -q '^status: active' "$ITEMS/night-a.md"
  ! grep -q 'dispatch-request night-a' "$CB_TMUX_LOG" 2>/dev/null
}

@test "an overnight item does not consume a slot — the plain item still claims it" {
  mk_timing aaa-night queued ultron overnight   # sorts FIRST alphabetically
  mk_item   zzz-plain queued ultron             # sorts LAST
  export CB_WINDOW_LIST_CMD="printf 'r1\nr2\n'" # 2 live, cap 3 → 1 slot
  export CB_MAX_CLAIM_PER_TICK=1                # don't read the operator's ~/.cerebro
  run scripts/cerebro/cb-intake --tick
  [ "$status" -eq 0 ]
  grep -q '^status: active' "$ITEMS/zzz-plain.md"
  grep -q '^status: queued' "$ITEMS/aaa-night.md"
  [ "$(grep -c 'dispatch-request' "$CB_TMUX_LOG")" = "1" ]
}

@test "an overnight item is filtered in the ELIGIBILITY scan, not at slot accounting" {
  # The discriminator for where the skip lives. The only queued item is overnight
  # and capacity is exhausted. Filtered in the scan, `queued` is empty and the tick
  # exits at cb-intake:130 before ever taking the lock or computing the budget — so
  # no capacity event is written. A skip pushed down into the claim loop would leave
  # the item in `queued`, reach the budget, and log `intake at capacity (1 queued…)`.
  mk_timing night-b queued ultron overnight
  export CB_WINDOW_LIST_CMD="printf 'r1\nr2\nr3\n'"   # 3 live ≥ cap 3 → 0 slots
  run scripts/cerebro/cb-intake --tick
  [ "$status" -eq 0 ]
  grep -q '^status: queued' "$ITEMS/night-b.md"
  ! grep -q 'at capacity' "$CB_HOME/logs/events" 2>/dev/null
}

@test "only an EXACT timing: overnight skips — no substring or prefix match" {
  mk_timing hourly-x    queued ultron hourly
  mk_timing overnight-x queued ultron overnight-batch   # prefix of the sentinel
  export CB_MAX_CLAIM_PER_TICK=2
  run scripts/cerebro/cb-intake --tick
  [ "$status" -eq 0 ]
  grep -q '^status: active' "$ITEMS/hourly-x.md"
  grep -q '^status: active' "$ITEMS/overnight-x.md"
  grep -q 'dispatch-request hourly-x' "$CB_TMUX_LOG"
  grep -q 'dispatch-request overnight-x' "$CB_TMUX_LOG"
}

@test "an inline YAML comment on timing: does not split the two readers" {
  # Regression, found in review 2026-08-15. `_fm` trims whitespace only, so
  # `timing: overnight   # why` yields the literal `overnight   # why`. Compared
  # raw, the exact-match test fails here while P7 and Dataview — both
  # YAML-semantic — still read `overnight`, so BOTH drains claim the item and the
  # hourly tick fires a dispatch-request an overnight item must never get. The
  # write contract in night-shift/SKILL.md and the inbox-stub template each used to
  # instruct exactly this shape.
  printf -- '---\nslug: cmt-x\nstatus: queued\nrepo: ultron\ndomain: forms\ntiming: overnight   # what makes cb-intake skip it\n---\n\n# cmt-x\n' \
    > "$ITEMS/cmt-x.md"
  run scripts/cerebro/cb-intake --tick
  [ "$status" -eq 0 ]
  grep -q '^status: queued' "$ITEMS/cmt-x.md"
  ! grep -q 'dispatch-request cmt-x' "$CB_TMUX_LOG" 2>/dev/null
}

@test "a trailing-comment timing: that is NOT overnight still claims" {
  # The strip must not turn every commented timing: into a skip.
  printf -- '---\nslug: cmt-h\nstatus: queued\nrepo: ultron\ndomain: forms\ntiming: hourly   # the default, stated explicitly\n---\n\n# cmt-h\n' \
    > "$ITEMS/cmt-h.md"
  run scripts/cerebro/cb-intake --tick
  [ "$status" -eq 0 ]
  grep -q '^status: active' "$ITEMS/cmt-h.md"
  grep -q 'dispatch-request cmt-h' "$CB_TMUX_LOG"
}
