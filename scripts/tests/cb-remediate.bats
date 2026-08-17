#!/usr/bin/env bats
# cb-remediate (T30): spend-wedge verify-then-resume, cap 2, FYI events —
# the spec-§14 matrix. Invoked by cb-watch every tick while a task is blocked.

setup() {
  export CB_HOME="$BATS_TEST_TMPDIR/.cerebro"
  mkdir -p "$CB_HOME/tasks/fix-b" "$CB_HOME/beacons" "$CB_HOME/logs"
  printf 'kind=code\nworktree=%s\njira=EJA-9\nsession=fix-b\ntarget=ultron\n' "$BATS_TEST_TMPDIR" > "$CB_HOME/tasks/fix-b/meta"
  # the blocked event's hash beacon (written by cb-watch when the episode began)
  printf 'wedgehash' > "$CB_HOME/beacons/fix-b.eventhash"
  touch -d '2 minutes ago' "$CB_HOME/beacons/fix-b.eventhash"
  # tmux mock for cb-send / cb-notify
  export CB_TMUX_BIN="$BATS_TEST_TMPDIR/faketmux"
  cat > "$CB_TMUX_BIN" <<'EOF'
#!/usr/bin/env bash
echo "tmux $*" >> "$CB_TMUX_LOG"
EOF
  chmod +x "$CB_TMUX_BIN"; export CB_TMUX_LOG="$BATS_TEST_TMPDIR/tmux.log"
  export CB_SEND_DELAY=0   # cb-send Enter-splits (7/13 hotfix); no need to pause under the mock
  # R17: cb-notify's blocked-exhausted page is now composer-guarded — default the
  # coordinator pane read to an empty composer so the page delivers under test.
  export CB_COORD_PANE_CMD="cat '$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)/fixtures/panes/coord-idle-empty.txt'"   # real idle capture — empty composer, deliverable
  # Remediation targets a WEDGED agent — harness ALIVE, parked on a spend-limit /
  # usage-wall screen. Model that: the session exists. Until 2026-07-30 this fixture
  # created no session at all, which cb_session_alive reports as `gone` — and
  # cb-send's dead-harness refusal then correctly declines to type at what is
  # indistinguishable from a bare shell. The guard is right (a dead harness wants a
  # re-adopt, not keystrokes); the fixture was modelling the wrong scenario. Presence
  # alone suffices: with no pane rows, cb_session_alive returns `alive` rather than
  # downgrading on missing evidence.
  export CB_SESSION_LIST_CMD="printf 'fix-b\n'"
  # (b) scope-add #2: cb-remediate now re-verifies a live spend-wedge signature
  # in THIS task's pane before acting. Default the pane to a genuine spend wedge
  # so the existing resume/cap tests model a truly-wedged session; the (b) tests
  # below override with idle / busy panes to prove the hold.
  local fp; fp="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)/fixtures/panes"
  export CB_PANE_CMD="cat '$fp/spend-wedge.txt'"
}

@test "spend not flowing → no send, no count bump, retriable next tick" {
  CB_SPEND_PROBE_CMD="false" run scripts/cerebro/cb-remediate fix-b
  [ "$status" -eq 0 ]
  [ ! -s "$CB_TMUX_LOG" ]
  [ ! -f "$CB_HOME/tasks/fix-b/remediation-count" ]
  # no episode marker — a later tick with flowing spend must still act
  CB_SPEND_PROBE_CMD="true" run scripts/cerebro/cb-remediate fix-b
  grep -q 'send-keys -t fix-b: continue' "$CB_TMUX_LOG"
}

@test "flowing → exactly one resume send + FYI event + count=1" {
  CB_SPEND_PROBE_CMD="true" run scripts/cerebro/cb-remediate fix-b
  [ "$status" -eq 0 ]
  grep -q 'send-keys -t fix-b: continue' "$CB_TMUX_LOG"
  # one resume ACTION = one text send (cb-send now Enter-splits into two key events)
  [ "$(grep -c 'send-keys -t fix-b: continue' "$CB_TMUX_LOG")" = "1" ]
  [ "$(cat "$CB_HOME/tasks/fix-b/remediation-count")" = "1" ]
  grep -q 'fix-b auto-resumed attempt 1/2 (spend-wedge)' "$CB_HOME/logs/events"
}

@test "two ticks over the same wedge episode → one action (idempotent)" {
  CB_SPEND_PROBE_CMD="true" run scripts/cerebro/cb-remediate fix-b
  CB_SPEND_PROBE_CMD="true" run scripts/cerebro/cb-remediate fix-b
  [ "$(grep -c 'send-keys -t fix-b: continue' "$CB_TMUX_LOG")" = "1" ]
  [ "$(cat "$CB_HOME/tasks/fix-b/remediation-count")" = "1" ]
}

@test "a NEW wedge episode (fresh blocked event) resumes again → count=2" {
  CB_SPEND_PROBE_CMD="true" run scripts/cerebro/cb-remediate fix-b
  touch "$CB_HOME/beacons/fix-b.eventhash"     # new blocked event, newer than the marker
  CB_SPEND_PROBE_CMD="true" run scripts/cerebro/cb-remediate fix-b
  [ "$(grep -c 'send-keys -t fix-b: continue' "$CB_TMUX_LOG")" = "2" ]
  [ "$(cat "$CB_HOME/tasks/fix-b/remediation-count")" = "2" ]
  grep -q 'attempt 2/2' "$CB_HOME/logs/events"
}

@test "third wedge → no resume, escalation event + page (cap 2)" {
  printf '2' > "$CB_HOME/tasks/fix-b/remediation-count"
  CB_SPEND_PROBE_CMD="true" run scripts/cerebro/cb-remediate fix-b
  [ "$status" -eq 0 ]
  ! grep -q 'continue' "$CB_TMUX_LOG"                       # no resume send
  grep -q 'remediation exhausted' "$CB_HOME/logs/events"
  grep -aq 'cb-watch: fix-b blocked-exhausted' "$CB_TMUX_LOG"
  # idempotent within the episode
  : > "$CB_TMUX_LOG"
  CB_SPEND_PROBE_CMD="true" run scripts/cerebro/cb-remediate fix-b
  [ ! -s "$CB_TMUX_LOG" ]
}

# --- watch wiring: a blocked task gets a remediation attempt every tick ---
@test "cb-watch tick invokes remediation for a blocked task" {
  export HOME="$BATS_TEST_TMPDIR/home"; mkdir -p "$HOME"
  CWT="$BATS_TEST_TMPDIR/worktree"; mkdir -p "$CWT/.ai/specs/fix-b"
  printf 'kind=code\nworktree=%s\njira=EJA-9\nsession=fix-b\ntarget=ultron\n' "$CWT" > "$CB_HOME/tasks/fix-b/meta"
  printf -- '---\ncurrent_task: build/3-implement\n---\n' > "$CWT/.ai/specs/fix-b/manifest.md"
  touch -d '3 hours ago' "$CWT/.ai/specs/fix-b/manifest.md"
  local fixpanes; fixpanes="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)/fixtures/panes"
  export CB_SESSION_LIST_CMD="printf 'fix-b\n'"
  export CB_PANE_CMD="cat '$fixpanes/spend-wedge.txt'"
  export CB_SPEND_PROBE_CMD="true"
  run scripts/cerebro/cb-watch --tick
  [ "$status" -eq 0 ]
  grep -q 'fix-b blocked' "$CB_HOME/logs/events"
  grep -q 'send-keys -t fix-b: continue' "$CB_TMUX_LOG"
  grep -q 'auto-resumed attempt 1/2' "$CB_HOME/logs/events"
}

@test "M6: refuses to resume an already-terminal task (summary.md present) + logs misclassification" {
  printf 'done\n' > "$CB_HOME/tasks/fix-b/summary.md"
  CB_SPEND_PROBE_CMD="true" run scripts/cerebro/cb-remediate fix-b
  [ "$status" -eq 0 ]
  [ ! -s "$CB_TMUX_LOG" ]
  [ ! -f "$CB_HOME/tasks/fix-b/remediation-count" ]
  grep -q 'fix-b misclassification' "$CB_HOME/logs/events"
  [ -f "$CB_HOME/beacons/fix-b.remediated" ]
}

@test "M6: refuses when pr.state=MERGED" {
  printf 'MERGED' > "$CB_HOME/tasks/fix-b/pr.state"
  CB_SPEND_PROBE_CMD="true" run scripts/cerebro/cb-remediate fix-b
  [ ! -s "$CB_TMUX_LOG" ]
  grep -q 'fix-b misclassification' "$CB_HOME/logs/events"
}

# Req 2 — per-task, timing-dependent: the REAL probe resumes a wedged task only
# when ANOTHER task is demonstrably spending (its manifest bumped within window).
@test "M6 req2: real probe resumes when another task's manifest is fresh (per-task)" {
  local OWT="$BATS_TEST_TMPDIR/other"; mkdir -p "$CB_HOME/tasks/other" "$OWT/.ai/specs/other"
  printf 'kind=code\nworktree=%s\njira=EJA-7\nsession=other\ntarget=ultron\n' "$OWT" > "$CB_HOME/tasks/other/meta"
  printf -- '---\ncurrent_task: build/2\n---\n' > "$OWT/.ai/specs/other/manifest.md"   # fresh (now)
  unset CB_SPEND_PROBE_CMD
  run scripts/cerebro/cb-remediate fix-b
  grep -q 'send-keys -t fix-b: continue' "$CB_TMUX_LOG"
  [ "$(cat "$CB_HOME/tasks/fix-b/remediation-count")" = "1" ]
}

# Req 1 — login-agnostic: with NO other task spending, the real probe holds — no
# number of ticks (a /login is just a tick) resumes it; only flowing spend does.
@test "M6 req1: real probe holds when no other task is spending (login is not a signal)" {
  unset CB_SPEND_PROBE_CMD
  run scripts/cerebro/cb-remediate fix-b     # tick 1
  run scripts/cerebro/cb-remediate fix-b     # "tick after a login" — same probe
  [ ! -s "$CB_TMUX_LOG" ]
  [ ! -f "$CB_HOME/tasks/fix-b/remediation-count" ]
}

# --- (b) scope-add #2: resume only on a GENUINE live wedge signal now ---
FP_B() { echo "$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)/fixtures/panes"; }

@test "(b) idle pane (no spend banner, just idle chrome) → hold, no resume, no count bump" {
  # eja-3600: awaiting Kyle's PR click, idle — classify's wedge pattern matches
  # the idle chrome, but there's no genuine spend banner → must NOT resume.
  CB_PANE_CMD="cat '$(FP_B)/research-idle.txt'" CB_SPEND_PROBE_CMD="true" \
    run scripts/cerebro/cb-remediate fix-b
  [ "$status" -eq 0 ]
  [ ! -s "$CB_TMUX_LOG" ]
  [ ! -f "$CB_HOME/tasks/fix-b/remediation-count" ]
  grep -q 'fix-b remediation held' "$CB_HOME/logs/events"
}

@test "(b) busy pane (turn in progress) → hold, no resume (not wedged)" {
  # rca-eja-3525: actively working (esc to interrupt) — a busy session is never
  # a wedge, even if a stale classification carried `blocked`.
  CB_PANE_CMD="cat '$(FP_B)/research-busy.txt'" CB_SPEND_PROBE_CMD="true" \
    run scripts/cerebro/cb-remediate fix-b
  [ ! -s "$CB_TMUX_LOG" ]
  [ ! -f "$CB_HOME/tasks/fix-b/remediation-count" ]
}

@test "(b) idle pane at cap does NOT page exhausted (never burns a false needs-relaunch)" {
  # the (b) gate precedes the cap check: a healthy-but-classified-blocked task
  # carrying count=2 must hold, not page 'exhausted' / flip to needs-relaunch.
  printf '2' > "$CB_HOME/tasks/fix-b/remediation-count"
  CB_PANE_CMD="cat '$(FP_B)/research-idle.txt'" CB_SPEND_PROBE_CMD="true" \
    run scripts/cerebro/cb-remediate fix-b
  [ ! -s "$CB_TMUX_LOG" ]
  ! grep -q 'remediation exhausted' "$CB_HOME/logs/events"
  grep -q 'fix-b remediation held' "$CB_HOME/logs/events"
}

@test "(b) genuine spend banner (default pane) still resumes — the real wedge path is intact" {
  CB_SPEND_PROBE_CMD="true" run scripts/cerebro/cb-remediate fix-b
  grep -q 'send-keys -t fix-b: continue' "$CB_TMUX_LOG"
  [ "$(cat "$CB_HOME/tasks/fix-b/remediation-count")" = "1" ]
}
