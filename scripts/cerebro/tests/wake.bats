#!/usr/bin/env bats
# R4 — durable wake queue + drain-at-start. A watcher (or coordinator) killed
# mid-cycle must never be able to swallow an escalation. Every wake is recorded
# BEFORE any suppression marker advances, and only a drain acknowledges it.

setup() {
  export CB_HOME="$BATS_TEST_TMPDIR/.cerebro"
  mkdir -p "$CB_HOME/logs" "$CB_HOME/locks" "$CB_HOME/beacons" "$CB_HOME/state"
  export CB_WAKE_QUEUE="$CB_HOME/state/wake-queue"
  source scripts/cerebro/lib/paths.sh
  source scripts/cerebro/lib/wake.sh
}

@test "an empty queue drains silently and exits 0" {
  run scripts/cerebro/cb-wake --drain
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "an enqueued wake survives to the drain" {
  cb_wake_enqueue eja-1 needs-input spec/awaiting-approval h1 "cb-watch: eja-1 needs-input"
  run scripts/cerebro/cb-wake --drain
  [ "$status" -eq 0 ]
  [[ "$output" == *"1 unacknowledged escalation"* ]]
  [[ "$output" == *"eja-1"* ]]
  [[ "$output" == *"needs-input"* ]]
  [[ "$output" == *"spec/awaiting-approval"* ]]
}

@test "the drain CONSUMES — a second drain is silent" {
  cb_wake_enqueue eja-1 needs-input g h1 m
  run scripts/cerebro/cb-wake --drain
  [[ "$output" == *"eja-1"* ]]
  run scripts/cerebro/cb-wake --drain
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "--peek shows the queue without consuming it" {
  cb_wake_enqueue eja-1 needs-input g h1 m
  run scripts/cerebro/cb-wake --peek
  [[ "$output" == *"eja-1"* ]]
  run scripts/cerebro/cb-wake --peek
  [[ "$output" == *"eja-1"* ]]        # still there
  run scripts/cerebro/cb-wake --drain
  [[ "$output" == *"eja-1"* ]]
}

@test "the same event queued repeatedly reads as one line with a count" {
  for _ in 1 2 3; do cb_wake_enqueue eja-1 needs-input gate-a h1 m; done
  run scripts/cerebro/cb-wake --drain
  [[ "$output" == *"1 unacknowledged escalation"* ]]
  [[ "$output" == *"[x3]"* ]]
}

@test "a NEW gate for the same slug is a distinct wake" {
  cb_wake_enqueue eja-1 needs-input gate-a h1 m
  cb_wake_enqueue eja-1 needs-input gate-b h2 m
  run scripts/cerebro/cb-wake --drain
  [[ "$output" == *"2 unacknowledged escalation"* ]]
  [[ "$output" == *"gate-a"* ]]
  [[ "$output" == *"gate-b"* ]]
}

@test "several slugs all survive one drain" {
  cb_wake_enqueue a needs-input g ha m
  cb_wake_enqueue b blocked-exhausted "" hb m
  cb_wake_enqueue c needs-relaunch "" hc m
  run scripts/cerebro/cb-wake --drain
  [[ "$output" == *"3 unacknowledged"* ]]
  [[ "$output" == *"blocked-exhausted"* ]]
  [[ "$output" == *"needs-relaunch"* ]]
}

@test "a drain killed mid-flight loses nothing — the next drain re-absorbs it" {
  cb_wake_enqueue eja-1 needs-input g h1 m
  staged="$(cb_wake_stage)"                 # simulate: staged, then the process dies
  [ -f "$staged" ]
  [ ! -f "$CB_WAKE_QUEUE" ]                 # queue is aside, not on disk
  run scripts/cerebro/cb-wake --drain       # a later drain must find the straggler
  [ "$status" -eq 0 ]
  [[ "$output" == *"eja-1"* ]]
}

@test "an enqueue racing a drain is not swallowed" {
  cb_wake_enqueue old needs-input g h1 m
  staged="$(cb_wake_stage)"                 # drain has taken the queue aside
  cb_wake_enqueue new needs-input g h2 m    # ...and a fresh wake arrives now
  cb_wake_format "$staged" | grep -q old
  rm -f "$staged"
  run scripts/cerebro/cb-wake --drain
  [[ "$output" == *"new"* ]]                # the racer landed in a fresh queue
}

@test "concurrent enqueues never tear a line" {
  for i in $(seq 1 20); do cb_wake_enqueue "slug-$i" needs-input g "h$i" msg & done
  wait
  [ "$(wc -l < "$CB_WAKE_QUEUE")" -eq 20 ]
  # every line has all 6 tab-separated fields — no interleaved partial writes
  [ "$(awk -F'\t' 'NF==6' "$CB_WAKE_QUEUE" | wc -l)" -eq 20 ]
}

@test "usage error on a bad flag" {
  run scripts/cerebro/cb-wake --nope
  [ "$status" -eq 2 ]
}

# --- the integration that matters: cb-notify records BEFORE it suppresses ---

notify_setup() {
  export CB_SESSION=TestCoord CB_GRACE_SECS=0 CB_SEND_DELAY=0
  export CB_TMUX_BIN="$BATS_TEST_TMPDIR/faketmux"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$CB_TMUX_BIN"; chmod +x "$CB_TMUX_BIN"
  printf 'h-abc' > "$CB_HOME/beacons/eja-9.eventhash"
}

@test "cb-notify enqueues the wake even when delivery SUCCEEDS" {
  # The point of R4: send-keys succeeding does not mean a coordinator read it.
  notify_setup
  export CB_COORD_PANE_CMD="cat '$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)/fixtures/panes/coord-idle-empty.txt'"   # pane affirmatively empty
  run scripts/cerebro/cb-notify eja-9 needs-input spec/gate
  [ "$status" -eq 0 ]
  [ "$(cat "$CB_HOME/beacons/eja-9.notified")" = "h-abc" ]   # suppression advanced
  grep -q 'eja-9' "$CB_WAKE_QUEUE"                           # ...and the wake is durable
}

@test "cb-notify enqueues the wake when delivery is DEFERRED" {
  notify_setup
  export CB_COORD_PANE_CMD="cat '$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)/fixtures/panes/coord-busy.txt'"     # pane busy → defer
  run scripts/cerebro/cb-notify eja-9 needs-input spec/gate
  [ "$status" -eq 0 ]
  [ ! -f "$CB_HOME/beacons/eja-9.notified" ]                 # nothing delivered
  grep -q 'eja-9' "$CB_WAKE_QUEUE"
}

@test "a wake enqueued before a coordinator death is surfaced on restart" {
  notify_setup
  export CB_COORD_PANE_CMD="cat '$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)/fixtures/panes/coord-idle-empty.txt'"
  run scripts/cerebro/cb-notify eja-9 needs-input spec/gate
  # coordinator dies here; the .notified beacon means cb-notify will never
  # re-send. The restart drain is the only thing that can still surface it.
  run scripts/cerebro/cb-wake --drain
  [[ "$output" == *"eja-9"* ]]
  [[ "$output" == *"spec/gate"* ]]
}

@test "a state cb-notify ignores never reaches the queue" {
  notify_setup
  run scripts/cerebro/cb-notify eja-9 running
  [ "$status" -eq 0 ]
  [ ! -s "$CB_WAKE_QUEUE" ]
}

# The activation story is not "the drain is wired somewhere" — it is "the drain
# is wired where something READS it." cb-ensure-session's line runs in the pane's
# init shell before `exec claude`, so its output is scrollback no model sees. A
# consuming drain there would delete every unacknowledged wake on each restart:
# R4 defeating R4. Same rule the enqueue side already applies — a successful
# write is not a read.
@test "cb-ensure-session only PEEKS — it must never consume the queue" {
  grep -q 'cb-wake --peek' scripts/cerebro/cb-ensure-session
  ! grep -q 'cb-wake --drain' scripts/cerebro/cb-ensure-session
}

@test "the consuming drain lives where an agent reads the output" {
  # the board skill runs it as a tool call in the coordinator's own turn
  grep -q 'cb-wake --drain' .claude/skills/board/SKILL.md
  grep -q 'Drain the wake queue' .claude/skills/board/SKILL.md
}

@test "--peek leaves the queue intact for the real drain" {
  cb_wake_enqueue eja-1 needs-input g h1 m
  run scripts/cerebro/cb-wake --peek
  [[ "$output" == *"eja-1"* ]]
  [ -s "$CB_WAKE_QUEUE" ]                    # still on disk after a restart peek
  run scripts/cerebro/cb-wake --drain
  [[ "$output" == *"eja-1"* ]]               # the coordinator still gets it
}
