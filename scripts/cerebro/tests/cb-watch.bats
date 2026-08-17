setup() {
  load ../lib/classify.sh   # R12: decision-log helpers for arranging test state
  # HOME is overridden to a throwaway dir as defense-in-depth: cb-watch now
  # wires cb-board into tick(), and cb-board's own default (CB_VAULT unset)
  # falls back to "$HOME/vault" — never let a test touch the real vault.
  export HOME="$BATS_TEST_TMPDIR/home"; mkdir -p "$HOME"
  # Same reasoning, for the landing arm: cb-land resolves its vault from
  # VAULT_DIR first and only falls back to $HOME/vault, so an ambient VAULT_DIR
  # (systemd Environment=, a shell that exported it) would walk straight past
  # the HOME override and into the real vault. Point it at a path that must not
  # exist — cb-land refuses on a missing vault, which is the intended no-op here.
  export VAULT_DIR="$BATS_TEST_TMPDIR/no-vault"
  export CB_HOME="$BATS_TEST_TMPDIR/.cerebro"; mkdir -p "$CB_HOME/tasks/t1" "$CB_HOME/beacons" "$CB_HOME/logs"
  printf running > "$CB_HOME/tasks/t1/status"
}
@test "emits an event on state change, none on repeat" {
  printf -- '---\nstatus: complete\n---\n' > "$CB_HOME/tasks/t1/report.md"
  run scripts/cerebro/cb-watch --tick
  [[ "$(cat "$CB_HOME/logs/events")" == *"t1 ready-for-review"* ]]
  : > "$CB_HOME/logs/events"                      # clear
  run scripts/cerebro/cb-watch --tick             # second tick, unchanged
  [ ! -s "$CB_HOME/logs/events" ]                 # no new event (dedup)
  # t1's terminal report reaches the landing arm with the REAL cb-land (no
  # CB_LAND_CMD stub here). Its `-d "$VAULT"` refusal is the only thing standing
  # between this suite and a shadow vault tree under a bats tmpdir — assert it
  # rather than trust it. NB `$HOME/vault` itself is NOT the check: cb-board
  # creates that dir on its own default every tick, and always has. What must
  # not appear is a landing — an `00 Inbox/` under either vault path.
  [ ! -d "$VAULT_DIR" ]
  [ ! -d "$HOME/vault/00 Inbox" ]
}

@test "tick creates $CB_HOME/logs on a fresh CB_HOME (no pre-existing logs dir)" {
  export CB_HOME="$BATS_TEST_TMPDIR/.cerebro-fresh"
  mkdir -p "$CB_HOME/tasks/t2" "$CB_HOME/beacons"
  printf running > "$CB_HOME/tasks/t2/status"
  printf -- '---\nstatus: complete\n---\n' > "$CB_HOME/tasks/t2/report.md"
  [ ! -d "$CB_HOME/logs" ]
  run scripts/cerebro/cb-watch --tick
  [ "$status" -eq 0 ]
  [ -f "$CB_HOME/logs/events" ]
}

# --- T21: code states through the dispatcher + (slug,state,current_task) dedup ---

setup_code_task() { # a code task gated at $1 (current_task), session alive
  CTD="$CB_HOME/tasks/fix-w"; mkdir -p "$CTD"
  CWT="$BATS_TEST_TMPDIR/worktree"; mkdir -p "$CWT/.ai/specs/fix-w"
  printf 'kind=code\nworktree=%s\njira=EJA-99\nsession=fix-w\n' "$CWT" > "$CTD/meta"
  printf -- '---\nname: fix-w\njira: EJA-99\ncurrent_task: %s\n---\n' "$1" > "$CWT/.ai/specs/fix-w/manifest.md"
  export CB_SESSION_LIST_CMD="printf 'fix-w\n'"
}

@test "two ticks over an unchanged awaiting-approval manifest → one event (hash dedup)" {
  setup_code_task "build/awaiting-approval"
  run scripts/cerebro/cb-watch --tick
  [ "$status" -eq 0 ]
  grep -q 'fix-w needs-input' "$CB_HOME/logs/events"
  [ "$(grep -c 'fix-w' "$CB_HOME/logs/events")" = "1" ]
  run scripts/cerebro/cb-watch --tick
  [ "$(grep -c 'fix-w' "$CB_HOME/logs/events")" = "1" ]   # still one — same (state, gate)
}

@test "same state, different gate (build → review pause) → second event" {
  setup_code_task "build/awaiting-approval"
  run scripts/cerebro/cb-watch --tick
  printf -- '---\nname: fix-w\njira: EJA-99\ncurrent_task: review/awaiting-approval\n---\n' > "$CWT/.ai/specs/fix-w/manifest.md"
  run scripts/cerebro/cb-watch --tick
  [ "$(grep -c 'fix-w needs-input' "$CB_HOME/logs/events")" = "2" ]
  grep -q 'review/awaiting-approval' "$CB_HOME/logs/events"
}

# --- T39: per-hash cooldown so running↔needs-input flapping can't spam ---

@test "state flapping within the cooldown suppresses the repeat event" {
  setup_code_task "build/awaiting-approval"
  run scripts/cerebro/cb-watch --tick        # event 1: needs-input
  printf -- '---\nname: fix-w\njira: EJA-99\ncurrent_task: build/3-implement\n---\n' > "$CWT/.ai/specs/fix-w/manifest.md"
  run scripts/cerebro/cb-watch --tick        # event 2: running
  printf -- '---\nname: fix-w\njira: EJA-99\ncurrent_task: build/awaiting-approval\n---\n' > "$CWT/.ai/specs/fix-w/manifest.md"
  run scripts/cerebro/cb-watch --tick        # flap back — suppressed
  [ "$(grep -c 'fix-w needs-input' "$CB_HOME/logs/events")" = "1" ]
  # state beacon still tracks reality even when the event is suppressed
  [ "$(cat "$CB_HOME/beacons/fix-w.state")" = "needs-input" ]
}

@test "R18: the same content key never re-escalates, no matter the elapsed time (content-keyed, not a timer)" {
  # R12/R18 supersedes the old time-based flap cooldown: dedup is on the exact
  # (state,gate) content, never on a window. A decision that recurs — even much
  # later — does NOT re-log the same event; only a genuinely new key does.
  setup_code_task "build/awaiting-approval"
  run scripts/cerebro/cb-watch --tick                       # needs-input(build) — event 1
  printf -- '---\nname: fix-w\njira: EJA-99\ncurrent_task: build/3-implement\n---\n' > "$CWT/.ai/specs/fix-w/manifest.md"
  run scripts/cerebro/cb-watch --tick                       # running — different key
  # simulate a long elapsed time so ANY time-window would have re-opened: age the
  # old cooldown hashlog past its window (this is what the pre-R18 code keyed on;
  # under R18's content seen-set it's irrelevant, so the recurrence stays deduped)
  [ -f "$CB_HOME/beacons/fix-w.hashlog" ] && awk '{print $1 - 7200, $2}' "$CB_HOME/beacons/fix-w.hashlog" > "$CB_HOME/beacons/fix-w.hashlog.t" && mv "$CB_HOME/beacons/fix-w.hashlog.t" "$CB_HOME/beacons/fix-w.hashlog"
  printf -- '---\nname: fix-w\njira: EJA-99\ncurrent_task: build/awaiting-approval\n---\n' > "$CWT/.ai/specs/fix-w/manifest.md"
  run scripts/cerebro/cb-watch --tick                       # same needs-input(build) key recurs
  [ "$(grep -c 'fix-w needs-input' "$CB_HOME/logs/events")" = "1" ]   # STILL one — content-keyed
}

@test "tick renders board.md at the configured CB_VAULT, not the HOME/vault default" {
  # NB: this locks the end-to-end rendering behavior (tick -> cb-board ->
  # board.md at the right path), not cb-watch's internal `export CB_HOME
  # CB_VAULT` line specifically — CB_HOME/CB_VAULT are already exported by
  # setup()/this test, so the cb-board child inherits them transitively via
  # the process environment regardless of that line.
  local override_vault="$BATS_TEST_TMPDIR/vault-override"
  mkdir -p "$override_vault"
  export CB_VAULT="$override_vault"
  run scripts/cerebro/cb-watch --tick
  [ "$status" -eq 0 ]
  [ -f "$override_vault/board.md" ]               # landed at the overridden CB_VAULT
  [ ! -f "$HOME/vault/board.md" ]                 # never fell back to the ($HOME/vault) default
}

# --- #3: fast tick cadence (audit finding #3) — the 120s default quantized the
#     90s grace so a needs-input gate took 2-4 min to reach the coordinator.
#     cb-watch spends no coordinator turn per tick, so a ~30s default is
#     near-free and lets the grace mean what it says. ---

@test "cb-watch --loop default tick cadence is ~30s (not the old 120)" {
  # shim `sleep` onto PATH: record the interval cb-watch sleeps, then fail so
  # set -e breaks the otherwise-infinite loop after the first tick.
  local shim="$BATS_TEST_TMPDIR/bin"; mkdir -p "$shim"
  cat > "$shim/sleep" <<EOF
#!/usr/bin/env bash
printf '%s' "\$1" > "$BATS_TEST_TMPDIR/slept"
exit 1
EOF
  chmod +x "$shim/sleep"
  unset CB_TICK_SECS 2>/dev/null || true
  run env PATH="$shim:$PATH" timeout 5 scripts/cerebro/cb-watch --loop
  [ "$(cat "$BATS_TEST_TMPDIR/slept")" -le 45 ]   # dropped well below 120; ~30
}

# --- #2: watcher singleton lock (audit finding #2) ---

@test "second --loop refuses while the lock is held" {
  lock="$CB_HOME/locks/cb-watch.lock"; mkdir -p "$(dirname "$lock")"
  flock -n "$lock" sleep 30 &                     # background holder keeps the lock
  holder=$!
  sleep 0.2
  run timeout 5 scripts/cerebro/cb-watch --loop   # second watcher must bail, not loop
  kill "$holder" 2>/dev/null || true
  [ "$status" -eq 1 ]
  [[ "$output" == *"refusing to start a second watcher"* ]]
}

@test "--tick takes no lock (single pass runs even while a loop lock is held)" {
  lock="$CB_HOME/locks/cb-watch.lock"; mkdir -p "$(dirname "$lock")"
  flock -n "$lock" sleep 30 &
  holder=$!
  sleep 0.2
  run scripts/cerebro/cb-watch --tick             # --tick unaffected by the loop lock
  kill "$holder" 2>/dev/null || true
  [ "$status" -eq 0 ]
}

# --- R12 (step 12): watcher-derived OPEN on needs-input / blocked ---
# NOTE: plan test setups reconciled to the real classify vocabulary — a code
# task classifies needs-input via the manifest awaiting-approval sentinel (not a
# `needs-input:` beacon), a research task blocks via a `blocked:` beacon.
@test "R12: tick opens a decision for a needs-input code task (manifest gate)" {
  setup_code_task "build/awaiting-approval"
  run scripts/cerebro/cb-watch --tick
  [ "$status" -eq 0 ]
  [ -f "$CTD/decisions" ]
  [ "$(grep -c ' open ' "$CTD/decisions")" -eq 1 ]
  grep -q 'build/awaiting-approval' "$CTD/decisions"   # the gate one-line is recorded
}
@test "R12: tick opens a decision for a blocked research task (beacon gate)" {
  td="$CB_HOME/tasks/rblock"; mkdir -p "$td"
  printf 'blocked: upstream API 500s\n' > "$td/status"
  run scripts/cerebro/cb-watch --tick
  [ -f "$td/decisions" ]
  grep -q 'upstream API 500s' "$td/decisions"
}
@test "R12: a running task opens NO decision" {
  setup_code_task "build/3-implement"
  run scripts/cerebro/cb-watch --tick
  [ ! -f "$CTD/decisions" ] || [ "$(grep -c ' open ' "$CTD/decisions")" -eq 0 ]
}
@test "R12: two ticks over the same unanswered gate → still one open (content-key idempotent)" {
  setup_code_task "build/awaiting-approval"
  run scripts/cerebro/cb-watch --tick
  run scripts/cerebro/cb-watch --tick
  [ "$(grep -c ' open ' "$CTD/decisions")" -eq 1 ]
}

# --- 2026-08-04: the watcher stops manufacturing decisions out of current_task ---
# A conductor that finishes CORRECTLY leaves current_task naming its last phase,
# which is precisely when this fired. `ship/complete` is a statement that the
# conductor finished shipping; it was surfaced to Kyle as an unanswered decision
# on two merged tasks, through two consecutive supervisor digests.
# The fixture is the REAL shape of the two tasks that caused this: a live session,
# a manifest that has not moved in hours, and a quiet pane — classify.sh:800's R13
# arm, which reads "I cannot establish what this is" as needs-input. Without the
# ageing the manifest is fresh and the task classifies `running`, which would pass
# the no-decision assertion for the wrong reason.
setup_stalled_code_task() { # setup_stalled_code_task <current_task>
  setup_code_task "$1"
  touch -d '2 hours ago' "$CWT/.ai/specs/fix-w/manifest.md"
  export CB_PANE_CMD="true"      # quiet pane: no menu, no busy spinner, no wedge
}
@test "no phantom: a FINISHED conductor (current_task, no gate) opens NO decision" {
  setup_stalled_code_task "ship/complete"
  run scripts/cerebro/cb-watch --tick
  [ "$status" -eq 0 ]
  grep -q 'fix-w needs-input' "$CB_HOME/logs/events"   # the STATE is still recorded
  [ ! -f "$CTD/decisions" ] || [ "$(grep -c ' open ' "$CTD/decisions")" -eq 0 ]
}
@test "no phantom: ten ticks over a finished conductor still open nothing" {
  setup_stalled_code_task "ship/1-land-and-followup-item"
  for _ in 1 2 3 4 5 6 7 8 9 10; do run scripts/cerebro/cb-watch --tick; done
  grep -q 'fix-w needs-input' "$CB_HOME/logs/events"
  [ ! -f "$CTD/decisions" ] || [ "$(grep -c ' open ' "$CTD/decisions")" -eq 0 ]
}
# The DURABILITY half. Even for a task whose manifest DOES declare a gate, an
# answer has to stick: the pre-fix watcher re-appended the identical key on the
# next tick, so a resolve at 17:50 was undone at 17:51.
@test "no phantom: a resolved PROJECTED key stays resolved across watch cycles" {
  setup_code_task "build/awaiting-approval"
  run scripts/cerebro/cb-watch --tick
  k="$(awk '$2=="open"{print $3; exit}' "$CTD/decisions")"; [ -n "$k" ]
  _decision_resolve "$CTD" "$k"
  for _ in 1 2 3; do run scripts/cerebro/cb-watch --tick; done
  run open_decisions "$CTD"; [ -z "$output" ]                  # STILL closed
  run bash -c "tail -1 '$CTD/decisions'"; [[ "$output" == *" resolved $k"* ]]
}
# ANTI-MASKING, on the terminal signal specifically (cb-board:20-32). The seal is
# scoped to projected keys precisely so this keeps holding: trading the phantom for
# a human-authored question that silently vanishes would be the worse bug.
@test "anti-masking: a DECLARED question survives a terminal signal" {
  td="$CB_HOME/tasks/asked"; mkdir -p "$td"; printf 'kind=research\n' > "$td/meta"
  k=$(_decision_key needs-input "one PR or two?")
  _decision_declare "$td" "$k" needs-input "one PR or two?"
  printf -- '---\nstatus: complete\n---\n' > "$td/report.md"   # terminal: ready-for-review
  run scripts/cerebro/cb-watch --tick
  run open_decisions "$td"; [[ "$output" == *"one PR or two?"* ]]
  run open_decisions_live "$td"; [[ "$output" == *"one PR or two?"* ]]
}
@test "anti-masking: a DECLARED question survives a resolve-then-re-ask cycle" {
  td="$CB_HOME/tasks/asked2"; mkdir -p "$td"; printf 'kind=research\n' > "$td/meta"
  k=$(_decision_key needs-input "still the same question")
  _decision_declare "$td" "$k" needs-input "still the same question"
  _decision_resolve "$td" "$k"
  _decision_declare "$td" "$k" needs-input "still the same question"
  run scripts/cerebro/cb-watch --tick
  run open_decisions "$td"; [[ "$output" == *"still the same question"* ]]
}

# --- R12 (step 12): CLOSE — progress-inferred + the anti-masking guard ---
@test "R12: terminal flip alone does NOT close an open decision (anti-masking)" {
  td="$CB_HOME/tasks/gate-y"; mkdir -p "$td"; printf 'kind=research\n' > "$td/meta"
  k=$(_decision_key needs-input "gate"); _decision_open "$td" "$k" needs-input "gate"
  printf -- '---\nstatus: complete\n---\n' > "$td/report.md"   # now classifies ready-for-review
  run scripts/cerebro/cb-watch --tick
  run open_decisions "$td"; [ -n "$output" ]                   # STILL open — was never answered
}
@test "R12: a fresh working beacon after the open closes it (progress-inferred)" {
  td="$CB_HOME/tasks/gate-z"; mkdir -p "$td"; printf 'kind=research\n' > "$td/meta"
  k=$(_decision_key needs-input "gate"); _decision_open "$td" "$k" needs-input "gate"
  printf 'running: resumed after answer\n' > "$td/status"      # fresh working beacon → classify running
  run scripts/cerebro/cb-watch --tick
  run open_decisions "$td"; [ -z "$output" ]                   # closed by genuine progress
}
@test "R12: a failed flip does NOT close an open decision (anti-masking)" {
  td="$CB_HOME/tasks/gate-f"; mkdir -p "$td"; printf 'kind=research\n' > "$td/meta"
  k=$(_decision_key blocked "stuck on X"); _decision_open "$td" "$k" blocked "stuck on X"
  printf -- '---\nstatus: failed\n---\n' > "$td/report.md"     # classifies failed
  run scripts/cerebro/cb-watch --tick
  run open_decisions "$td"; [ -n "$output" ]                   # STILL open
}

# --- R12 (step 12) Task 6: migration — a pre-existing gated task with no
# decisions log gets one opened on the first post-deploy tick (no retro history).
@test "R12 migration: an in-flight needs-input task with no decisions log gets opened on first tick" {
  setup_code_task "review/awaiting-approval"     # a gate that predates the decisions log
  [ ! -f "$CTD/decisions" ]                        # legacy: no log yet
  run scripts/cerebro/cb-watch --tick
  [ -f "$CTD/decisions" ]
  run open_decisions "$CTD"; [[ "$output" == *"review/awaiting-approval"* ]]
}

# --- R19 (step 13): focus auto-exit wiring — focus + Kyle-returned → catch-up ---
@test "R19: a tick in focus with a returned-Kyle coordinator pane flips mode to catch-up" {
  setup_code_task "build/awaiting-approval"          # an open decision exists
  printf 'focus' > "$CB_HOME/mode"
  export CB_INJECT_MARK='@@'
  # A submitted human turn echoes as its own `❯ <text>` line above the live
  # composer box → cb_focus_human_returned true. The pane is then mid-turn on that
  # question, so the digest defers this tick and mode stays catch-up (it flushes on
  # a later tick when the composer is free).
  export CB_COORD_PANE_CMD="printf '%s\n' '❯ where are we on eja-3648' '✢ Gallivanting… (12s · ↓ 1.1k tokens)' '─────' '❯ ' '─────'"
  run scripts/cerebro/cb-watch --tick
  [ "$status" -eq 0 ]
  [ "$(cat "$CB_HOME/mode")" = "catch-up" ]          # exited focus, requested catch-up
}
@test "R19: a tick in focus with a real idle capture STAYS in focus (no false exit)" {
  setup_code_task "build/awaiting-approval"
  printf 'focus' > "$CB_HOME/mode"
  # real 2026-08-02 capture of a finished, idle pane — Kyle is not back
  export CB_COORD_PANE_CMD="cat '$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)/fixtures/panes/coord-idle-empty.txt'"
  run scripts/cerebro/cb-watch --tick
  [ "$status" -eq 0 ]
  [ "$(cat "$CB_HOME/mode")" = "focus" ]              # still heads-down
}

@test "M6: cb-watch promotes an at-cap wedge to needs-relaunch — pages once, resolves decision, no resume" {
  export CB_HOME="$BATS_TEST_TMPDIR/.cerebro"
  mkdir -p "$CB_HOME/tasks/fix-b" "$CB_HOME/beacons" "$CB_HOME/logs"
  export HOME="$BATS_TEST_TMPDIR/home"; mkdir -p "$HOME"
  CWT="$BATS_TEST_TMPDIR/wt"; mkdir -p "$CWT/.ai/specs/fix-b"
  printf 'kind=code\nworktree=%s\njira=EJA-9\nsession=fix-b\ntarget=ultron\n' "$CWT" > "$CB_HOME/tasks/fix-b/meta"
  printf -- '---\ncurrent_task: build/3-implement\n---\n' > "$CWT/.ai/specs/fix-b/manifest.md"
  touch -d '3 hours ago' "$CWT/.ai/specs/fix-b/manifest.md"
  printf '2' > "$CB_HOME/tasks/fix-b/remediation-count"          # at cap → needs-relaunch
  printf '%s open 111 blocked build/3-implement\n' "2026-07-15T00:00:00+00:00" > "$CB_HOME/tasks/fix-b/decisions"
  export CB_TMUX_BIN="$BATS_TEST_TMPDIR/faketmux"
  cat > "$CB_TMUX_BIN" <<'XEOF'
#!/usr/bin/env bash
echo "tmux $*" >> "$CB_TMUX_LOG"
XEOF
  chmod +x "$CB_TMUX_BIN"; export CB_TMUX_LOG="$BATS_TEST_TMPDIR/tmux.log"
  export CB_SEND_DELAY=0 CB_GRACE_SECS=0
  export CB_COORD_PANE_CMD="cat '$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)/fixtures/panes/coord-idle-empty.txt'"
  local fixpanes; fixpanes="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)/fixtures/panes"
  export CB_SESSION_LIST_CMD="printf 'fix-b\n'"
  export CB_PANE_CMD="cat '$fixpanes/spend-wedge.txt'"

  run scripts/cerebro/cb-watch --tick
  [ "$status" -eq 0 ]
  grep -q 'fix-b needs-relaunch' "$CB_HOME/logs/events"          # distinct state logged
  run grep -q 'auto-resumed' "$CB_HOME/logs/events"; [ "$status" -ne 0 ]   # NO remediation resume
  grep -aq 'relaunch' "$CB_TMUX_LOG"                             # paged into the coordinator
  grep -q 'resolved 111' "$CB_HOME/tasks/fix-b/decisions"        # superseded blocked decision resolved
}

# =====================================================================
# P1 reconciliation — cb-ask (declared) vs watcher-derived (heuristic).
# BOTH paths stay (design spec), but a task must never surface twice: a
# live declared decision suppresses the heuristic open, and supersedes
# (resolves) one already opened.
# =====================================================================
setup_declared_task() {   # research task, live window, declared question
  export CB_WINDOW_LIST_CMD="printf 'ask-t\n'"
  mkdir -p "$CB_HOME/tasks/ask-t"
  printf 'running: started\n' > "$CB_HOME/tasks/ask-t/status"
  scripts/cerebro/cb-ask ask-t "which carrier first?" --options "PRU|LFG"
}
decision_lines() { grep -c ' declared \| open ' "$CB_HOME/tasks/ask-t/decisions"; }

@test "P1: a declared decision suppresses the watcher's heuristic open (one surface)" {
  setup_declared_task
  touch -d '90 minutes ago' "$CB_HOME/tasks/ask-t/status"   # past CB_PAUSE_RESURFACE_SECS → needs-input
  run scripts/cerebro/cb-watch --tick
  [ "$status" -eq 0 ]
  [ "$(decision_lines)" -eq 1 ]                              # still ONLY the declared line
  run open_decisions "$CB_HOME/tasks/ask-t"
  [ "$(printf '%s\n' "$output" | grep -c .)" -eq 1 ]
  [[ "$output" == *"which carrier first? [PRU|LFG]"* ]]
}

@test "P1: a declared decision SUPERSEDES a heuristic key the watcher already opened" {
  export CB_WINDOW_LIST_CMD="printf 'ask-t\n'"
  mkdir -p "$CB_HOME/tasks/ask-t"
  printf 'blocked: cannot pick a carrier\n' > "$CB_HOME/tasks/ask-t/status"
  run scripts/cerebro/cb-watch --tick                        # heuristic open lands first
  [ "$(grep -c ' open ' "$CB_HOME/tasks/ask-t/decisions")" -eq 1 ]
  scripts/cerebro/cb-ask ask-t "which carrier first?" --options "PRU|LFG"
  touch -d '90 minutes ago' "$CB_HOME/tasks/ask-t/status"
  run scripts/cerebro/cb-watch --tick
  run open_decisions "$CB_HOME/tasks/ask-t"
  [ "$(printf '%s\n' "$output" | grep -c .)" -eq 1 ]         # collapsed to one
  [[ "$output" == *"which carrier first?"* ]]                # and it is the declared one
  grep -q ' resolved ' "$CB_HOME/tasks/ask-t/decisions"      # append-only supersession
}

@test "P1: with NO declared decision the fail-safe heuristic open still fires (both paths kept)" {
  export CB_WINDOW_LIST_CMD="printf 'silent-t\n'"
  mkdir -p "$CB_HOME/tasks/silent-t"
  printf 'blocked: upstream API returning 500s\n' > "$CB_HOME/tasks/silent-t/status"
  run scripts/cerebro/cb-watch --tick
  [ "$status" -eq 0 ]
  grep -q ' open ' "$CB_HOME/tasks/silent-t/decisions"
  run open_decisions "$CB_HOME/tasks/silent-t"
  [[ "$output" == *"upstream API returning 500s"* ]]
}

@test "P1: a tick right after cb-ask on a BARE launch beacon does not resolve the declaration" {
  # the regression this guards: cb-start writes `running` with no trailing
  # newline (cb-start:228). If cb-ask appends onto it unterminated, the beacon
  # reads `runningpaused`, classify falls through to `running`, and the
  # running-arm below resolves the decision the worker just declared.
  export CB_WINDOW_LIST_CMD="printf 'ask-t\n'"
  mkdir -p "$CB_HOME/tasks/ask-t"
  printf 'running' > "$CB_HOME/tasks/ask-t/status"
  scripts/cerebro/cb-ask ask-t "which carrier first?"
  run scripts/cerebro/cb-watch --tick
  [ "$status" -eq 0 ]
  run open_decisions "$CB_HOME/tasks/ask-t"
  [[ "$output" == *"which carrier first?"* ]]
}

# CORRECTED 2026-07-30. This test used to assert that progress alone closes a
# DECLARED decision. That is wrong and it cost two real questions: cb-ask is an
# ask-and-continue channel, and for a CODE task `classify_code` never reads the
# beacon, so the task keeps classifying `running` while the worker carries on
# with the parts that do not depend on the answer. The running-arm then closed
# the question 11s and 32s after it was asked (eja-3963) — gone from the board
# before any human saw it. The answer path was never this arm anyway: cb-send
# resolves open decisions on delivery (cb-send:181-186). So progress closes
# HEURISTIC keys only; a declared question is closed by an actual answer.
@test "P1: the worker keeps working while it waits → the declared decision STAYS open" {
  setup_declared_task
  printf 'running: proceeding with the parts that do not need the answer\n' >> "$CB_HOME/tasks/ask-t/status"
  run scripts/cerebro/cb-watch --tick
  [ "$status" -eq 0 ]
  run open_decisions "$CB_HOME/tasks/ask-t"
  [[ "$output" == *"which carrier first?"* ]]
}

@test "P1: progress still closes a HEURISTIC key (the derived guess, not a real question)" {
  export CB_WINDOW_LIST_CMD="printf 'heur-t\n'"
  mkdir -p "$CB_HOME/tasks/heur-t"
  printf 'blocked: waiting on something\n' > "$CB_HOME/tasks/heur-t/status"
  run scripts/cerebro/cb-watch --tick          # watcher derives + opens its own key
  printf 'running: back to work\n' >> "$CB_HOME/tasks/heur-t/status"
  run scripts/cerebro/cb-watch --tick          # progress clears the guess
  [ "$status" -eq 0 ]
  run open_decisions "$CB_HOME/tasks/heur-t"
  [ -z "$output" ]
}

@test "P1: the declared decision reaches the board's Needs-you bucket" {
  setup_declared_task
  export CB_VAULT="$BATS_TEST_TMPDIR/vault"; mkdir -p "$CB_VAULT"
  run scripts/cerebro/cb-watch --tick
  grep -q 'ask-t (needs-input: which carrier first? \[PRU|LFG\])' "$CB_VAULT/board.md"
}

# --- reap rides the watcher (2026-07-30) — cb-reap used to be invoked from
#     exactly one place, cb-intake --tick, so slot reclamation inherited the
#     hourly cadence AND intake's availability. When intake was paused on
#     2026-07-29, reaping stopped with it while finished agents held every slot. ---

@test "cb-watch --loop sweeps cb-reap on the sub-cadence, not every tick" {
  local shim="$BATS_TEST_TMPDIR/bin"; mkdir -p "$shim"
  # sleep counts iterations and breaks the loop after 3 of them
  cat > "$shim/sleep" <<EOF
#!/usr/bin/env bash
n=\$(cat "$BATS_TEST_TMPDIR/n" 2>/dev/null || echo 0); n=\$((n+1))
printf '%s' "\$n" > "$BATS_TEST_TMPDIR/n"
[ "\$n" -ge 3 ] && exit 1
exit 0
EOF
  chmod +x "$shim/sleep"
  # shim cb-reap by name so the real one never runs against the live fleet
  cat > "$BATS_TEST_TMPDIR/reaplog" <<< ""
  run env PATH="$shim:$PATH" CB_REAP_EVERY_TICKS=2 CB_TICK_SECS=0 \
    timeout 5 scripts/cerebro/cb-watch --loop
  # 3 iterations with every-2 → at least one sweep attempted
  [ -f "$BATS_TEST_TMPDIR/n" ]
  [ "$(cat "$BATS_TEST_TMPDIR/n")" -ge 2 ]
}

@test "CB_WATCH_REAP=0 disables the sweep entirely" {
  local shim="$BATS_TEST_TMPDIR/bin"; mkdir -p "$shim"
  cat > "$shim/sleep" <<EOF
#!/usr/bin/env bash
printf 'slept' > "$BATS_TEST_TMPDIR/slept2"
exit 1
EOF
  chmod +x "$shim/sleep"
  # a cb-reap that would fail loudly if called — the kill switch must prevent it
  cat > "$shim/cb-reap" <<'EOF'
#!/usr/bin/env bash
echo CALLED > /dev/stderr; exit 9
EOF
  chmod +x "$shim/cb-reap"
  run env PATH="$shim:$PATH" CB_WATCH_REAP=0 CB_REAP_EVERY_TICKS=1 \
    timeout 5 scripts/cerebro/cb-watch --loop
  [ -f "$BATS_TEST_TMPDIR/slept2" ]   # it ticked
  [[ "$output" != *"CALLED"* ]]       # but never swept
}

@test "a failing cb-reap never kills the watcher loop" {
  local shim="$BATS_TEST_TMPDIR/bin"; mkdir -p "$shim"
  cat > "$shim/sleep" <<EOF
#!/usr/bin/env bash
n=\$(cat "$BATS_TEST_TMPDIR/n3" 2>/dev/null || echo 0); n=\$((n+1))
printf '%s' "\$n" > "$BATS_TEST_TMPDIR/n3"
[ "\$n" -ge 3 ] && exit 1
exit 0
EOF
  chmod +x "$shim/sleep"
  run env PATH="$shim:$PATH" CB_REAP_EVERY_TICKS=1 CB_TICK_SECS=0 \
    timeout 5 scripts/cerebro/cb-watch --loop
  # reached iteration 3 → the loop survived the sweeps (set -e did not trip)
  [ "$(cat "$BATS_TEST_TMPDIR/n3")" -ge 3 ]
}

# --- R20: the ready-no-PR arm, moved out of cb-magneto (2026-08-01) ---
# cb-pr-check's only caller used to be cb-magneto's sweep, which never ran once.
# The arm now rides the watcher tick. These tests are the "it actually fires"
# proof the move needs — a moved capability nothing triggers is the same defect.

setup_r20() {   # a shipped code task: run dir + 04-ship.md, no pr, no summary.md
  R20TD="$CB_HOME/tasks/ship-x"; mkdir -p "$R20TD"
  R20WT="$BATS_TEST_TMPDIR/wt-ship"; mkdir -p "$R20WT/.ai/specs/ship-x"
  printf 'kind=code\nworktree=%s\njira=EJA-77\nsession=ship-x\n' "$R20WT" > "$R20TD/meta"
  printf -- '---\nname: ship-x\njira: EJA-77\ncurrent_task: ship/done\n---\n' \
    > "$R20WT/.ai/specs/ship-x/manifest.md"
  printf '# Ship\n- **Branch:** `wc-ship-x`\n' > "$R20WT/.ai/specs/ship-x/04-ship.md"
  R20LOG="$BATS_TEST_TMPDIR/prcheck.calls"
  cat > "$BATS_TEST_TMPDIR/prcheck-stub" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$1" >> "$R20LOG"
exit \${R20_PRCHECK_EXIT:-0}
EOF
  chmod +x "$BATS_TEST_TMPDIR/prcheck-stub"
  export CB_PRCHECK_CMD="$BATS_TEST_TMPDIR/prcheck-stub"
  export CB_SESSION_LIST_CMD="printf ''"
}

@test "R20 fires cb-pr-check on the three-condition case (no pr, 04-ship.md, no summary.md)" {
  setup_r20
  run scripts/cerebro/cb-watch --tick
  [ "$status" -eq 0 ]
  [ -f "$R20LOG" ]
  grep -qx 'ship-x' "$R20LOG"
}

@test "R20 does not fire when a pr file already exists" {
  setup_r20
  printf '123' > "$R20TD/pr"; printf 'MERGED' > "$R20TD/pr.state"
  run scripts/cerebro/cb-watch --tick
  [ "$status" -eq 0 ]
  [ ! -f "$R20LOG" ]
}

@test "R20 does not fire when summary.md exists (PR already created)" {
  setup_r20
  printf '# summary\n' > "$R20TD/summary.md"
  run scripts/cerebro/cb-watch --tick
  [ "$status" -eq 0 ]
  [ ! -f "$R20LOG" ]
}

@test "R20 does not fire when the run dir has no 04-ship.md (conductor hasn't shipped)" {
  setup_r20
  rm "$R20WT/.ai/specs/ship-x/04-ship.md"
  run scripts/cerebro/cb-watch --tick
  [ "$status" -eq 0 ]
  [ ! -f "$R20LOG" ]
}

@test "R20 does not fire for a non-code task" {
  setup_r20
  printf 'kind=research\nworktree=%s\n' "$R20WT" > "$R20TD/meta"
  run scripts/cerebro/cb-watch --tick
  [ "$status" -eq 0 ]
  [ ! -f "$R20LOG" ]
}

@test "R20 retries every tick but logs the failure exactly once (R18 dedup)" {
  setup_r20
  export R20_PRCHECK_EXIT=1
  run scripts/cerebro/cb-watch --tick
  [ "$status" -eq 0 ]                                   # a failed create never kills the tick
  run scripts/cerebro/cb-watch --tick
  [ "$status" -eq 0 ]
  [ "$(grep -c '^ship-x$' "$R20LOG")" = "2" ]           # retried
  [ "$(grep -c 'ship-x pr-check-failed' "$CB_HOME/logs/events")" = "1" ]   # logged once
}

# --- LANDING (2026-08-14): the report-landing arm ---
# A research/ops finding used to reach the vault only when a human remembered to
# run /ingest; cb-unlanded's register carries 90+ where that never happened. The
# arm is what makes the landing automatic, so — same argument as R20 above — a
# moved-but-untriggered capability is the same defect, and these are the "it
# actually fires" proof.

setup_land() {   # a finished research task: terminal report, no landed marker
  LTD="$CB_HOME/tasks/land-x"; mkdir -p "$LTD"
  printf 'kind=research\nsession=land-x\ndeliverable=00 Inbox/2026-08-14-research-land-x.md\n' > "$LTD/meta"
  printf -- '---\nstatus: complete\n---\n\n# finding\n' > "$LTD/report.md"
  LANDLOG="$BATS_TEST_TMPDIR/land.calls"
  cat > "$BATS_TEST_TMPDIR/land-stub" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$1" >> "$LANDLOG"
exit \${LAND_EXIT:-0}
EOF
  chmod +x "$BATS_TEST_TMPDIR/land-stub"
  export CB_LAND_CMD="$BATS_TEST_TMPDIR/land-stub"
  export CB_SESSION_LIST_CMD="printf ''"
}

@test "LAND fires cb-land on a terminal non-code task with no landed marker" {
  setup_land
  run scripts/cerebro/cb-watch --tick
  [ "$status" -eq 0 ]
  [ -f "$LANDLOG" ]
  grep -qx 'land-x' "$LANDLOG"
}

@test "LAND does not fire once the landed marker exists (idempotent, and cheap)" {
  setup_land
  printf '00 Inbox/2026-08-14-research-land-x.md\n' > "$LTD/landed"
  run scripts/cerebro/cb-watch --tick
  [ "$status" -eq 0 ]
  [ ! -f "$LANDLOG" ]
}

@test "LAND STILL fires on a task cb-land already refused — a refusal must re-evaluate" {
  # The `surfaced` marker deliberately does NOT gate this arm. cb-land clears it
  # only on the landing path (cb-land:221), which a refused task never reaches,
  # so skipping the fork here would freeze the refusal: a confidential clearance
  # later corrected to `standard`, or a collision cleared by hand, would never
  # re-land, and cb-land's changed-reason branch would be dead code under the
  # watcher. The repeat is already cheap and silent — a few stats, no write, no
  # commit — so the fork is the smaller cost and recovery stays automatic.
  setup_land
  printf 'clearance: confidential — surfaced only, never auto-filed\n' > "$LTD/surfaced"
  run scripts/cerebro/cb-watch --tick
  [ "$status" -eq 0 ]
  [ -f "$LANDLOG" ]
  grep -qx 'land-x' "$LANDLOG"
}

@test "LAND does not fire for a kind=code task — its deliverable is a PR" {
  setup_land
  printf 'kind=code\nsession=land-x\n' > "$LTD/meta"
  printf 'MERGED' > "$LTD/pr.state"      # classifies done, the other terminal state
  printf '1' > "$LTD/pr"                 # keeps the R20 arm out of this test
  run scripts/cerebro/cb-watch --tick
  [ "$status" -eq 0 ]
  [ ! -f "$LANDLOG" ]
}

@test "LAND does not fire while the task is still running (non-terminal)" {
  setup_land
  rm "$LTD/report.md"
  printf 'running: still working\n' > "$LTD/status"
  run scripts/cerebro/cb-watch --tick
  [ "$status" -eq 0 ]
  [ ! -f "$LANDLOG" ]
}

@test "LAND: a failing cb-land never kills the tick" {
  setup_land
  export LAND_EXIT=1
  run scripts/cerebro/cb-watch --tick
  [ "$status" -eq 0 ]
  grep -qx 'land-x' "$LANDLOG"
  run scripts/cerebro/cb-watch --tick        # and it retries next tick
  [ "$status" -eq 0 ]
  [ "$(grep -c '^land-x$' "$LANDLOG")" = "2" ]
}

# C3 (review cycle 1). `|| true` alone makes a failing landing indistinguishable
# from an arm that never fired — the same Type-B defect cb-watch:54-59 spells out
# for R20, which is why that arm logs its first failure and this one must too.
# C4 was exactly such a failure and would have been invisible in production.
@test "LAND: the FIRST failure logs one event and drops a beacon" {
  setup_land
  export LAND_EXIT=1
  run scripts/cerebro/cb-watch --tick
  [ "$status" -eq 0 ]
  [ -e "$CB_HOME/beacons/land-x.land-failed" ]
  grep -q 'land-x land-failed' "$CB_HOME/logs/events"
}

# ~2,880 ticks a day: a per-tick event line would bury the log, which is the
# reason R20 keys its marker per slug and creates it if absent.
@test "LAND: a repeated failure logs ONCE, not every tick" {
  setup_land
  export LAND_EXIT=1
  run scripts/cerebro/cb-watch --tick
  run scripts/cerebro/cb-watch --tick
  run scripts/cerebro/cb-watch --tick
  [ "$status" -eq 0 ]
  [ "$(grep -c 'land-x land-failed' "$CB_HOME/logs/events")" = "1" ]
  [ "$(grep -c '^land-x$' "$LANDLOG")" = "3" ]   # still retrying every tick
}

@test "LAND: a successful landing logs no failure event and no beacon" {
  setup_land
  run scripts/cerebro/cb-watch --tick
  [ "$status" -eq 0 ]
  [ ! -e "$CB_HOME/beacons/land-x.land-failed" ]
  grep -q 'land-failed' "$CB_HOME/logs/events" && return 1 || true
}
