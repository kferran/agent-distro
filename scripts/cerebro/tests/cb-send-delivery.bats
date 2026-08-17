#!/usr/bin/env bats
# cb-send delivery verification (2026-07-24). The 7/13 Enter-split hotfix reduced
# but did not eliminate the strand: the Enter is still swallowed for an idle-at-a-
# prompt or busy composer and the message sits typed-but-unsubmitted. cb-send now
# reads the composer back and recovers (Enter rung, then C-u + retype).
#
# The pane fixtures are REAL captures from live conductor sessions on 7/24 — the
# stranded one is an actual stranded message caught in the wild. They carry the
# real chrome, including the U+00A0 that follows `❯` in an EMPTY composer (an
# ASCII-space assumption inverts the whole guard).

setup() {
  load ../lib/classify.sh
  export CB_HOME="$BATS_TEST_TMPDIR/.cerebro"; mkdir -p "$CB_HOME/tasks"
  export CB_GUARD_CMD=:                      # R1: no real cb-guard (network probe)
  export CB_SEND_DELAY=0 CB_VERIFY_DELAY=0
  export CB_TMUX_LOG="$BATS_TEST_TMPDIR/tmux.log"
  export FAKE_STATE="$BATS_TEST_TMPDIR/state"; mkdir -p "$FAKE_STATE"
  export FIXTURES="$BATS_TEST_DIRNAME/fixtures/panes"
  export MSG="skip the screenshots, go with the code trace"   # matches the fixture

  # Stateful fake tmux: models a composer. `send-keys <text>` types (composer shows
  # the message), `send-keys Enter` submits — but only the FAKE_SUBMIT_AT'th Enter
  # actually lands, which is the bug. `capture-pane` renders the resulting state.
  export CB_TMUX_BIN="$BATS_TEST_TMPDIR/faketmux"
  cat > "$CB_TMUX_BIN" <<'EOF'
#!/usr/bin/env bash
echo "tmux $*" >> "$CB_TMUX_LOG"
typed="$FAKE_STATE/typed"; enters="$FAKE_STATE/enters"
n_typed=$(cat "$typed" 2>/dev/null || echo 0); n_enters=$(cat "$enters" 2>/dev/null || echo 0)
case "$1" in
  capture-pane)
    if [ -n "${FAKE_PANE_OVERRIDE:-}" ]; then cat "$FAKE_PANE_OVERRIDE"
    elif [ "$n_enters" -ge "${FAKE_SUBMIT_AT:-1}" ] || [ "$n_typed" -eq 0 ]; then
      cat "$FIXTURES/composer-empty.txt"
    else cat "$FIXTURES/composer-stranded.txt"; fi ;;
  send-keys)
    shift; while [ $# -gt 0 ]; do
      case "$1" in
        Enter) echo $(( n_enters + 1 )) > "$enters"; n_enters=$(( n_enters + 1 ));;
        C-u)   echo 0 > "$typed"; n_typed=0;;
        -t|"$FAKE_TARGET") ;;
        *) echo 1 > "$typed"; n_typed=1;;
      esac; shift
    done ;;
esac
exit 0
EOF
  chmod +x "$CB_TMUX_BIN"
  export FAKE_TARGET="cb:probe-x"
}

sends()  { grep -c "send-keys" "$CB_TMUX_LOG" || true; }

# --- the happy path is unchanged -------------------------------------------
@test "delivers on the first Enter: types, submits, verifies, exits 0" {
  export FAKE_SUBMIT_AT=1
  run scripts/cerebro/cb-send probe-x "$MSG"
  [ "$status" -eq 0 ]
  [ "$(sends)" -eq 2 ]                                    # type + Enter, no recovery
  ! grep -q "C-u" "$CB_TMUX_LOG"
}

# --- detect + recover: THE BUG ----------------------------------------------
@test "recovers a stranded message with a second Enter (no retype)" {
  export FAKE_SUBMIT_AT=2                                 # first Enter is swallowed
  run scripts/cerebro/cb-send probe-x "$MSG"
  [ "$status" -eq 0 ]
  [ "$(grep -c "send-keys -t cb:probe-x Enter" "$CB_TMUX_LOG")" -eq 2 ]
  ! grep -q "C-u" "$CB_TMUX_LOG"                          # cheapest rung sufficed
}

@test "escalates to C-u + retype when the Enter rung does not clear the strand" {
  export FAKE_SUBMIT_AT=3                                 # two Enters swallowed
  run scripts/cerebro/cb-send probe-x "$MSG"
  [ "$status" -eq 0 ]
  grep -q "send-keys -t cb:probe-x C-u" "$CB_TMUX_LOG"    # cleared before retyping
  [ "$(grep -c "send-keys -t cb:probe-x $MSG" "$CB_TMUX_LOG")" -eq 2 ]
}

@test "never silently 'sent': exits non-zero with a NOT DELIVERED message" {
  export FAKE_SUBMIT_AT=99                                # every Enter swallowed
  run scripts/cerebro/cb-send probe-x "$MSG"
  [ "$status" -eq 4 ]
  [[ "$output" == *"NOT DELIVERED"* ]]
  [ "$(grep -c "send-keys -t cb:probe-x C-u" "$CB_TMUX_LOG")" -eq 2 ]   # bounded
}

# --- idempotency -------------------------------------------------------------
@test "a stranded message from a PRIOR run is submitted, never retyped" {
  echo 1 > "$FAKE_STATE/typed"; export FAKE_SUBMIT_AT=1   # composer already holds it
  run scripts/cerebro/cb-send probe-x "$MSG"
  [ "$status" -eq 0 ]
  [ "$(grep -c "send-keys -t cb:probe-x $MSG" "$CB_TMUX_LOG")" -eq 0 ]  # no double-type
  [ "$(sends)" -eq 1 ]                                    # Enter only
}

@test "refuses to type into a composer holding someone else's text" {
  # Since the ghost probe (2026-08-03) this refusal is EARNED, not assumed: the
  # pane override holds the text fixed, so the probe character appends rather
  # than replaces and the original survives — real pending input. The old
  # assertion here was `sends == 0`; the probe makes that two keystrokes, so the
  # claim it was standing in for is asserted directly instead — our message never
  # goes out, and the composer is handed back exactly as we found it.
  # (Ghost-vs-pending in full: tests/cb-send-ghost.bats.)
  sed 's/skip the screenshots.*/fix the prudential replacement quest/' \
    "$FIXTURES/composer-stranded.txt" > "$BATS_TEST_TMPDIR/other.txt"
  export FAKE_PANE_OVERRIDE="$BATS_TEST_TMPDIR/other.txt"
  run scripts/cerebro/cb-send probe-x "$MSG"
  [ "$status" -eq 3 ]
  [[ "$output" == *"refusing"* ]]
  [ "$(grep -c "send-keys -t cb:probe-x $MSG" "$CB_TMUX_LOG")" -eq 0 ]   # never typed
  ! grep -q "send-keys -t cb:probe-x Enter" "$CB_TMUX_LOG"               # never submitted
  [ "$(grep -c "send-keys -t cb:probe-x BSpace" "$CB_TMUX_LOG")" -eq 1 ] # probe taken back
  [ "$(sends)" -eq 2 ]                                    # exactly the probe pair
}

# --- an EMPTY composer is `❯` + U+00A0, not `❯` + space ----------------------
@test "an empty composer reads as empty (NBSP normalized), so the send proceeds" {
  export FAKE_PANE_OVERRIDE="$FIXTURES/composer-empty.txt"
  run scripts/cerebro/cb-send probe-x "$MSG"
  [ "$status" -eq 0 ]                                     # not refused as 'non-empty'
  grep -q "send-keys -t cb:probe-x $MSG" "$CB_TMUX_LOG"
}

# --- unreadable pane: REFUSES now, and that is deliberate (2026-07-30) -------
# This used to assert exit 0 + a blind send, because cb-remediate called cb-send
# bare under `set -e` and a non-zero would abort before its count++/marker —
# retrying every tick and bypassing CB_REMEDIATE_CAP. That coupling has been cut:
# cb-remediate now counts the ATTEMPT whether or not cb-send delivered (the cap
# always meant "how often we try"), so cb-send is free to hold the stronger
# contract: never type into a pane you cannot read.
@test "unreadable pane (spend-wedge, no composer) → exit 3, nothing typed" {
  export FAKE_PANE_OVERRIDE="$FIXTURES/spend-wedge.txt"
  export CB_COMPOSER_WAIT_SECS=1 CB_COMPOSER_POLL_SECS=0.1
  run scripts/cerebro/cb-send probe-x "$MSG"
  [ "$status" -eq 3 ]
  [[ "$output" == *"no composer"* ]]
  ! grep -q "send-keys" "$CB_TMUX_LOG"
}

# --- R12: the decision closes only when the message actually landed ----------
@test "R12: a delivered answer resolves the slug's open decision" {
  export FAKE_SUBMIT_AT=2                                 # recovered, so: delivered
  td="$CB_HOME/tasks/gate-x"; mkdir -p "$td"
  k=$(_decision_key needs-input "gate"); _decision_open "$td" "$k" needs-input "gate"
  export FAKE_TARGET="cb:gate-x"
  run scripts/cerebro/cb-send gate-x "$MSG"
  [ "$status" -eq 0 ]
  run open_decisions "$td"; [ -z "$output" ]
}

@test "R12: an undelivered answer leaves the decision OPEN" {
  export FAKE_SUBMIT_AT=99
  td="$CB_HOME/tasks/gate-y"; mkdir -p "$td"
  k=$(_decision_key needs-input "gate"); _decision_open "$td" "$k" needs-input "gate"
  export FAKE_TARGET="cb:gate-y"
  run scripts/cerebro/cb-send gate-y "$MSG"
  [ "$status" -eq 4 ]
  run open_decisions "$td"; [ -n "$output" ]              # gate stays open
}

# --- no composer: WAIT, then REFUSE. Never type blind (2026-07-30) -----------
# The regression this guards is the most expensive one cb-send has had. It used to
# treat "no composer" as "send blind": type, Enter, exit 0. Against a harness that
# has not finished booting that types into nothing and reports success. On
# 2026-07-30, five recovery conductors were adopted and briefed in one pass at load
# 48; all five booted slowly, all five briefs vanished, and all five agents sat at a
# bare `running` beacon having never received an instruction — while cb-send said
# "sent" for every one. A spawn is exactly when delivery most needs to be real and
# exactly when the composer is most likely absent.

@test "no composer ever appears → exit 3, and NOTHING is typed" {
  export FAKE_PANE_OVERRIDE="$BATS_TEST_TMPDIR/nocomposer.txt"
  printf 'some pane chrome\nno composer here\n' > "$FAKE_PANE_OVERRIDE"
  export CB_COMPOSER_WAIT_SECS=2 CB_COMPOSER_POLL_SECS=0
  run scripts/cerebro/cb-send probe-x "$MSG"
  [ "$status" -eq 3 ]
  [[ "$output" == *"no composer"* ]]
  # the whole point: not one keystroke went out
  ! grep -q "send-keys" "$CB_TMUX_LOG"
}

@test "a composer that appears late is waited for, then delivered normally" {
  # pane has no composer until the 3rd capture, modelling a booting harness
  export FAKE_PANE_OVERRIDE="$BATS_TEST_TMPDIR/late.txt"
  printf 'still booting\n' > "$FAKE_PANE_OVERRIDE"
  export CB_COMPOSER_WAIT_SECS=10 CB_COMPOSER_POLL_SECS=0.1
  ( sleep 0.3; cp "$FIXTURES/composer-empty.txt" "$FAKE_PANE_OVERRIDE" ) &
  run scripts/cerebro/cb-send probe-x "$MSG"
  [ "$status" -eq 0 ]
  grep -q "send-keys" "$CB_TMUX_LOG"          # it did eventually type
  wait
}

@test "the refusal is distinguishable from the composer-holds-other-text refusal" {
  # both exit 3; the messages must differ so a caller can tell them apart
  export FAKE_PANE_OVERRIDE="$BATS_TEST_TMPDIR/nc2.txt"
  printf 'no composer\n' > "$FAKE_PANE_OVERRIDE"
  export CB_COMPOSER_WAIT_SECS=1 CB_COMPOSER_POLL_SECS=0
  run scripts/cerebro/cb-send probe-x "$MSG"
  [ "$status" -eq 3 ]
  [[ "$output" != *"already holds other text"* ]]
}
