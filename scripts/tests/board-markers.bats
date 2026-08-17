# Board verify-markers — the one part of a `⚠ Needs a decision` line that the
# board establishes for itself rather than repeating back what the task wrote
# about itself. Two properties are load-bearing and neither is obvious from the
# rendered output, so they are pinned here:
#   1. a marker is only ever rendered on POSITIVE evidence — unknown liveness, an
#      unparseable timestamp and an unlogged originating verb each render silence;
#   2. the liveness memo is OPT-IN. With no epoch open it must observe every
#      change, because cb-watch --loop is a single process that lives for days
#      and a memo that outlived one render there would freeze the board's idea of
#      what is alive — the exact pathology these markers exist to detect.
setup() {
  load ../lib/classify.sh
  export CB_HOME="$BATS_TEST_TMPDIR/.cerebro"; export CB_VAULT="$BATS_TEST_TMPDIR/vault"
  mkdir -p "$CB_HOME/tasks" "$CB_VAULT"
  # never touch the real tmux or the real process table from a test
  export CB_WINDOW_LIST_CMD="printf ''" CB_SESSION_LIST_CMD="printf ''"
  export CB_WINDOW_PID_CMD=true CB_SESSION_PID_CMD=true CB_PANE_CMD=true
  export CB_PS_CMD=true
  # cb_liveness_epoch_begin mktemps under ${TMPDIR:-/tmp}. Scoping TMPDIR to this
  # test's own dir means any "did an epoch dir leak?" assertion sees only dirs
  # this test created, instead of counting a /tmp shared with the whole box.
  export TMPDIR="$BATS_TEST_TMPDIR"
}
teardown() {
  declare -F cb_liveness_epoch_end >/dev/null 2>&1 && cb_liveness_epoch_end
  return 0
}

iso_ago() { date -u -d "@$(( $(date +%s) - $1 ))" +%Y-%m-%dT%H:%M:%S+00:00; }
DAY=86400

mk_research() { # mk_research <slug>
  mkdir -p "$CB_HOME/tasks/$1"; printf 'kind=research\n' > "$CB_HOME/tasks/$1/meta"
}
mk_code() {     # mk_code <slug>
  mkdir -p "$CB_HOME/tasks/$1"
  printf 'kind=code\nworktree=%s\njira=EJA-1\nsession=%s\n' "$BATS_TEST_TMPDIR/wt-$1" "$1" > "$CB_HOME/tasks/$1/meta"
}

# --- cb_decision_markers, one marker at a time --------------------------------

@test "markers: gone session + a declared key reads as asked-and-exited" {
  local td="$CB_HOME/tasks/asked"; mk_research asked
  printf '%s declared 1001 needs-input a question\n' "$(iso_ago 60)" > "$td/decisions"
  run cb_decision_markers "$td" 1001 "$(iso_ago 60)"
  [ "$status" -eq 0 ]
  [ "$output" = "📨 asked & exited" ]
}

@test "markers: gone session + a heuristic open key reads as a corpse" {
  local td="$CB_HOME/tasks/corpse"; mk_research corpse
  printf '%s open 1002 blocked a guess\n' "$(iso_ago 60)" > "$td/decisions"
  run cb_decision_markers "$td" 1002 "$(iso_ago 60)"
  [ "$output" = "⚰ no session" ]
}

@test "markers: a declared key beats an open key for the SAME key (fold order)" {
  local td="$CB_HOME/tasks/both"; mk_research both
  printf '%s open 1003 needs-input guess\n%s declared 1003 needs-input the real question\n' \
    "$(iso_ago 120)" "$(iso_ago 60)" > "$td/decisions"
  run cb_decision_markers "$td" 1003 ""
  [ "$output" = "📨 asked & exited" ]
}

# R1 (Architect ruling 2026-08-03). cb-board's live-projection path keys off
# _decision_for, whose key was never written to the log, so there is no verb to
# read. The verb is the ENTIRE discriminator between "the worker asked and
# exited" and "corpse" — with none, there is nothing to discriminate on, and
# guessing corpse slanders a task that asked politely. Rendering both glyphs for
# one dead session is what this ruling removed.
@test "markers: gone session + an UNLOGGED key renders no liveness marker at all" {
  local td="$CB_HOME/tasks/unlogged"; mk_research unlogged
  printf '%s declared 1004 needs-input logged one\n' "$(iso_ago 60)" > "$td/decisions"
  run cb_decision_markers "$td" 9999999 ""
  [ "$output" = "" ]
}

@test "markers: no decisions log at all renders no liveness marker" {
  local td="$CB_HOME/tasks/nolog"; mk_research nolog
  run cb_decision_markers "$td" 1005 ""
  [ "$output" = "" ]
}

@test "markers: a live session renders nothing, whatever the verb" {
  local td="$CB_HOME/tasks/live1"; mk_research live1
  printf '%s open 1006 blocked guess\n' "$(iso_ago 60)" > "$td/decisions"
  export CB_WINDOW_LIST_CMD="printf 'live1\n'"
  run cb_decision_markers "$td" 1006 "$(iso_ago 60)"
  [ "$output" = "" ]
}

# fail-safe: `unavailable` is "cannot tell", and cannot-tell never renders.
@test "markers: unavailable liveness (no tmux binary) renders no liveness marker" {
  local td="$CB_HOME/tasks/unavail"; mk_research unavail
  printf '%s open 1007 blocked guess\n' "$(iso_ago 60)" > "$td/decisions"
  export CB_WINDOW_LIST_CMD="exit 127"
  run cb_decision_markers "$td" 1007 ""
  [ "$output" = "" ]
}

@test "markers: age marker fires past the threshold, in whole floored days" {
  local td="$CB_HOME/tasks/aged"; mk_research aged
  printf '%s open 1008 blocked old\n' "$(iso_ago $(( 12 * DAY + 3600 )))" > "$td/decisions"
  run cb_decision_markers "$td" 1008 "$(iso_ago $(( 12 * DAY + 3600 )))"
  [ "$output" = "⚰ no session ⏳ 12d" ]
}

@test "markers: a decision younger than the threshold carries no age marker" {
  local td="$CB_HOME/tasks/fresh"; mk_research fresh
  printf '%s open 1009 blocked new\n' "$(iso_ago 3600)" > "$td/decisions"
  run cb_decision_markers "$td" 1009 "$(iso_ago 3600)"
  [ "$output" = "⚰ no session" ]
}

@test "markers: CB_DECISION_AGE_WARN_SECS moves the threshold" {
  local td="$CB_HOME/tasks/tunable"; mk_research tunable
  local ts; ts="$(iso_ago $(( 2 * DAY + 3600 )))"
  printf '%s open 1010 blocked two days\n' "$ts" > "$td/decisions"
  run cb_decision_markers "$td" 1010 "$ts"          # default 3d — silent
  [ "$output" = "⚰ no session" ]
  CB_DECISION_AGE_WARN_SECS=86400 run cb_decision_markers "$td" 1010 "$ts"
  [ "$output" = "⚰ no session ⏳ 2d" ]
}

@test "markers: an empty or unparseable timestamp renders no age marker" {
  local td="$CB_HOME/tasks/badts"; mk_research badts
  printf '%s open 1011 blocked x\n' "$(iso_ago 60)" > "$td/decisions"
  run cb_decision_markers "$td" 1011 ""
  [ "$output" = "⚰ no session" ]
  run cb_decision_markers "$td" 1011 "not-a-timestamp"
  [ "$output" = "⚰ no session" ]
}

@test "markers: pr.state renders when it is not MERGED, and never when it is" {
  local td="$CB_HOME/tasks/prs"; mk_research prs
  printf '%s declared 1012 needs-input q\n' "$(iso_ago 60)" > "$td/decisions"
  printf 'OPEN\n' > "$td/pr.state"
  run cb_decision_markers "$td" 1012 ""
  [ "$output" = "📨 asked & exited 🔀 pr OPEN" ]
  printf 'DECLINED\n' > "$td/pr.state"
  run cb_decision_markers "$td" 1012 ""
  [ "$output" = "📨 asked & exited 🔀 pr DECLINED" ]
  printf 'MERGED\n' > "$td/pr.state"
  run cb_decision_markers "$td" 1012 ""
  [ "$output" = "📨 asked & exited" ]
  rm "$td/pr.state"
  run cb_decision_markers "$td" 1012 ""
  [ "$output" = "📨 asked & exited" ]
}

@test "markers: all three render in order — liveness, age, PR" {
  local td="$CB_HOME/tasks/all3"; mk_research all3
  local ts; ts="$(iso_ago $(( 13 * DAY + 3600 )))"
  printf '%s open 1013 blocked old\n' "$ts" > "$td/decisions"
  printf 'OPEN' > "$td/pr.state"
  run cb_decision_markers "$td" 1013 "$ts"
  [ "$output" = "⚰ no session ⏳ 13d 🔀 pr OPEN" ]
}

@test "markers: a code task resolves liveness on its session meta field, not the slug" {
  local td="$CB_HOME/tasks/codetask"; mk_code codetask
  printf 'kind=code\nworktree=%s\njira=EJA-1\nsession=other-name\n' "$BATS_TEST_TMPDIR/wt" > "$td/meta"
  printf '%s declared 1014 needs-input q\n' "$(iso_ago 60)" > "$td/decisions"
  export CB_SESSION_LIST_CMD="printf 'other-name\n'"   # the SESSION is alive, the slug is not a session
  run cb_decision_markers "$td" 1014 ""
  [ "$output" = "" ]
  export CB_SESSION_LIST_CMD="printf 'codetask\n'"     # slug present, session absent -> gone
  run cb_decision_markers "$td" 1014 ""
  [ "$output" = "📨 asked & exited" ]
}

@test "markers: a code task with no session meta falls back to the slug" {
  local td="$CB_HOME/tasks/noslug"; mk_code noslug
  printf 'kind=code\nworktree=%s\njira=EJA-1\n' "$BATS_TEST_TMPDIR/wt" > "$td/meta"
  printf '%s declared 1015 needs-input q\n' "$(iso_ago 60)" > "$td/decisions"
  export CB_SESSION_LIST_CMD="printf 'noslug\n'"
  run cb_decision_markers "$td" 1015 ""
  [ "$output" = "" ]
}

# --- _decision_verb / cb_decision_open_ts -------------------------------------

@test "_decision_verb folds declared over open, and resolution does not erase the verb" {
  local td="$CB_HOME/tasks/verbs"; mk_research verbs
  { printf '%s open 2001 blocked g\n'          "$(iso_ago 300)"
    printf '%s declared 2001 needs-input q\n'  "$(iso_ago 200)"
    printf '%s open 2002 blocked g\n'          "$(iso_ago 300)"
    printf '%s declared 2003 needs-input q\n'  "$(iso_ago 300)"
    printf '%s resolved 2003\n'                "$(iso_ago 100)"; } > "$td/decisions"
  run _decision_verb "$td" 2001; [ "$output" = declared ]
  run _decision_verb "$td" 2002; [ "$output" = open ]
  run _decision_verb "$td" 2003; [ "$output" = declared ]
  run _decision_verb "$td" 2009; [ "$output" = "" ]
}

@test "cb_decision_open_ts returns the LAST opener's timestamp, empty for an unknown key" {
  local td="$CB_HOME/tasks/ts"; mk_research ts
  local old new; old="$(iso_ago 900)"; new="$(iso_ago 300)"
  { printf '%s open 3001 blocked g\n' "$old"; printf '%s declared 3001 needs-input q\n' "$new"; } > "$td/decisions"
  run cb_decision_open_ts "$td" 3001; [ "$output" = "$new" ]
  run cb_decision_open_ts "$td" 3009; [ "$output" = "" ]
  run cb_decision_open_ts "$CB_HOME/tasks/nonexistent" 3001; [ "$output" = "" ]
}

# --- the 2026-08-02 acceptance snapshot, as fixtures --------------------------
# It cannot be replayed live: the snapshot's two LIVE rows are dead today, and
# the ages have moved on. Encoded as fixtures so the rows keep asserting.

@test "snapshot: the three 12-day rca-* items each mark corpse + age" {
  local ts; ts="$(iso_ago $(( 12 * DAY + 3600 )))"
  for s in rca-eja-3169 rca-eja-3819 rca-eja-3836; do
    mk_research "$s"
    printf '%s open 4000 blocked stale RCA finding\n' "$ts" > "$CB_HOME/tasks/$s/decisions"
  done
  run scripts/cerebro/cb-board
  [ "$status" -eq 0 ]
  grep -q '^- rca-eja-3169 ⚰ no session ⏳ 12d (blocked: stale RCA finding)$' "$CB_VAULT/board.md"
  grep -q '^- rca-eja-3819 ⚰ no session ⏳ 12d (blocked: stale RCA finding)$' "$CB_VAULT/board.md"
  grep -q '^- rca-eja-3836 ⚰ no session ⏳ 12d (blocked: stale RCA finding)$' "$CB_VAULT/board.md"
}

@test "snapshot: eja-3121 carries the open-PR marker" {
  mk_code eja-3121-company-name-typeahead-lag
  local td="$CB_HOME/tasks/eja-3121-company-name-typeahead-lag"
  printf 'OPEN' > "$td/pr.state"
  printf '%s declared 4001 needs-input who signs off on the shared-layer change\n' "$(iso_ago 3600)" > "$td/decisions"
  run scripts/cerebro/cb-board
  [ "$status" -eq 0 ]
  grep -q 'eja-3121-company-name-typeahead-lag 📨 asked & exited 🔀 pr OPEN (needs-input:' "$CB_VAULT/board.md"
}

@test "snapshot: a declared key on a gone session marks asked-and-exited, NOT a corpse" {
  mk_code eja-3881
  printf '%s declared 4002 needs-input two documents were conflated\n' "$(iso_ago 3600)" \
    > "$CB_HOME/tasks/eja-3881/decisions"
  run scripts/cerebro/cb-board
  [ "$status" -eq 0 ]
  grep -q 'eja-3881 📨 asked & exited (needs-input:' "$CB_VAULT/board.md"
  ! grep -q '⚰' "$CB_VAULT/board.md"
}

# --- the negative case: a live agent with a fresh question renders clean ------

@test "a live session with a fresh decision renders a line with no markers at all" {
  mk_code alive-task
  printf '%s declared 4003 needs-input ship/complete\n' "$(iso_ago 60)" \
    > "$CB_HOME/tasks/alive-task/decisions"
  export CB_SESSION_LIST_CMD="printf 'alive-task\n'"
  run scripts/cerebro/cb-board
  [ "$status" -eq 0 ]
  grep -q '^- alive-task (needs-input: ship/complete)$' "$CB_VAULT/board.md"
  # no marker on ANY rendered item line (⏳ alone would match the Running header)
  ! grep -qE '^- .*(📨|⚰|⏳|🔀)' "$CB_VAULT/board.md"
}

@test "fail-safe: an unavailable tmux renders the board with no liveness markers" {
  mk_research unavailable-task
  printf '%s open 4004 blocked something\n' "$(iso_ago $(( 9 * DAY )))" \
    > "$CB_HOME/tasks/unavailable-task/decisions"
  export CB_WINDOW_LIST_CMD="exit 127"
  run scripts/cerebro/cb-board
  [ "$status" -eq 0 ]
  ! grep -qE '📨|⚰' "$CB_VAULT/board.md"
  grep -q 'unavailable-task ⏳ 9d (blocked: something)' "$CB_VAULT/board.md"   # age is independent evidence
}

@test "an empty marker string leaves the decision line byte-identical to the old shape" {
  mk_research plain
  printf '%s open 4005 blocked waiting on Kyle\n' "$(iso_ago 60)" > "$CB_HOME/tasks/plain/decisions"
  export CB_WINDOW_LIST_CMD="printf 'plain\n'"
  run scripts/cerebro/cb-board
  [ "$status" -eq 0 ]
  grep -q '^- plain (blocked: waiting on Kyle)$' "$CB_VAULT/board.md"   # no double space, no trailing space
}

# --- the epoch memo -----------------------------------------------------------
# The rest of the suite cannot catch a memo that is accidentally always-on: no
# other test opens an epoch, and every bats process is short-lived. These two
# cases are the whole guard.

@test "memo: inside an epoch a changed session list is NOT observed" {
  export CB_SESSION_LIST_CMD="printf 'S\n'"
  cb_liveness_epoch_begin
  [ "$(cb_session_alive S)" = alive ]
  export CB_SESSION_LIST_CMD="printf ''"
  [ "$(cb_session_alive S)" = alive ]      # memoized — the epoch is one sample
  cb_liveness_epoch_end
}

@test "memo: with NO epoch open a changed session list IS observed" {
  export CB_SESSION_LIST_CMD="printf 'S\n'"
  [ "$(cb_session_alive S)" = alive ]
  export CB_SESSION_LIST_CMD="printf ''"
  [ "$(cb_session_alive S)" = gone ]       # opt-in: cb-watch --loop must never freeze
}

@test "memo: closing an epoch drops the cache, so the next epoch re-samples" {
  export CB_WINDOW_LIST_CMD="printf 'W\n'"
  cb_liveness_epoch_begin
  [ "$(cb_window_alive W)" = alive ]
  cb_liveness_epoch_end
  export CB_WINDOW_LIST_CMD="printf ''"
  cb_liveness_epoch_begin
  [ "$(cb_window_alive W)" = gone ]
  cb_liveness_epoch_end
}

# The cached value survives a fork: every real caller invokes these inside a
# command substitution, so an in-memory memo would write into the subshell and
# lose it. That is why the store is a directory.
@test "memo: a value cached inside a command substitution is visible to the next one" {
  export CB_PS_CMD="printf '1 0 claude\n'"
  cb_liveness_epoch_begin
  [ "$(cb_ps_table)" = "1 0 claude" ]
  export CB_PS_CMD="printf '2 0 bash\n'"
  [ "$(cb_ps_table)" = "1 0 claude" ]
  cb_liveness_epoch_end
}

# An empty result is a HIT, not a miss. cb_ps_table's documented degraded output
# is the empty string, and a truthiness test would silently re-shell there.
@test "memo: an empty cached result is a hit, not a re-probe" {
  export CB_PS_CMD="true"
  cb_liveness_epoch_begin
  [ "$(cb_ps_table)" = "" ]
  export CB_PS_CMD="printf '9 0 claude\n'"
  [ "$(cb_ps_table)" = "" ]
  cb_liveness_epoch_end
}

@test "memo: closing an epoch removes its scratch dir" {
  cb_liveness_epoch_begin
  [ -d "$_CB_LIVE_EPOCH" ]
  local dir="$_CB_LIVE_EPOCH"
  cb_liveness_epoch_end
  [ ! -d "$dir" ]
  [ -z "$_CB_LIVE_EPOCH" ]
}

# The next two together cover "an aborted render leaves no epoch dir behind".
#
# They replace one earlier test that drove cb-board onto its abort path with a
# `kill -TERM $$` smuggled through the mocked CB_WINDOW_LIST_CMD. That test was
# FLAKY — measured 1 failure in 5 full-suite runs against 0 in 20 isolated runs,
# always on its own `[ "$status" -ne 0 ]` guard, because the signal did not
# reliably land under load and the render exited 0. The guard was right to be
# there (without it the leak check passes vacuously), so the race is what had to
# go: this suite is the gate on board accuracy, and a test that fails one run in
# five is worse than the leak it watches for. Deliberately NOT fixed with a retry
# or a sleep — that hides a race rather than removing it.
@test "memo: an abnormal exit runs the trap and removes the epoch dir" {
  # No signal: `exit 3` reaches the EXIT trap by the same path a `set -e` abort
  # mid-loop does, and it gets there every single time.
  # `|| true` on the substitution, not on the inner script: the child must really
  # exit 3 so the trap fires, while bats' errexit must not kill the test for it.
  local dir status3=0
  dir="$(bash -c '
    source scripts/cerebro/lib/classify.sh
    trap cb_liveness_epoch_end EXIT
    cb_liveness_epoch_begin
    printf "%s" "$_CB_LIVE_EPOCH"
    exit 3
  ')" || status3=$?
  [ "$status3" -eq 3 ]   # the child really took the abnormal path
  [ -n "$dir" ]
  [ ! -d "$dir" ]
}

@test "cb-board arms the epoch trap, and a normal render leaks nothing" {
  # A grep is a weak assertion on its own. It is acceptable HERE and only here:
  # the test above proves the trap's behaviour deterministically, so this one has
  # the narrower job of pinning that cb-board is actually wired to it — the one
  # thing a behavioural test of the library cannot see from outside the script.
  grep -q 'trap cb_liveness_epoch_end EXIT' scripts/cerebro/cb-board
  mk_research plain
  printf 'running\n' > "$CB_HOME/tasks/plain/status"
  run scripts/cerebro/cb-board
  [ "$status" -eq 0 ]
  # TMPDIR is scoped to this test (see setup), so this counts only our own dirs.
  [ "$(ls -d "$TMPDIR"/cb-liveness.* 2>/dev/null | wc -l)" -eq 0 ]
}
