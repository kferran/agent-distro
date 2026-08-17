#!/usr/bin/env bats
# P4 — the turn/speech policy. The prose contract lives in
# scripts/cerebro/policy/turn-policy.md; the machine-checkable half is the
# enumerated escalation whitelist, enforced at cb_escalate — the one chokepoint
# every escalation in the system already flows through.

setup() {
  load ../lib/turnpolicy.sh
  export CB_HOME="$BATS_TEST_TMPDIR/.cerebro"
  mkdir -p "$CB_HOME/tasks" "$CB_HOME/beacons" "$CB_HOME/logs"
}

@test "the whitelist enumerates exactly the six escalation reasons" {
  run cb_escalation_codes
  [ "$status" -eq 0 ]
  [ "$output" = "decision
blocked-exhausted
needs-relaunch
merge-ready
intake-ambiguous
unrecognized" ]
}
@test "cb_escalation_allowed accepts every enumerated code" {
  while read -r c; do
    run cb_escalation_allowed "$c"
    [ "$status" -eq 0 ]
  done < <(cb_escalation_codes)
}
@test "cb_escalation_allowed refuses an unknown code, an empty code, and no code at all" {
  run cb_escalation_allowed "fyi"; [ "$status" -ne 0 ]
  run cb_escalation_allowed "";    [ "$status" -ne 0 ]
  run cb_escalation_allowed;       [ "$status" -ne 0 ]
}
@test "cb_escalation_allowed matches whole lines only (no substring or regex match)" {
  run cb_escalation_allowed "decisions"; [ "$status" -ne 0 ]
  run cb_escalation_allowed "deci";      [ "$status" -ne 0 ]
  run cb_escalation_allowed ".*";        [ "$status" -ne 0 ]
}

# --- doc ↔ lib anti-drift: the policy doc is not decoration ------------------
POLICY() { printf 'scripts/cerebro/policy/turn-policy.md'; }
doc_codes() { awk '/^```escalation-codes$/{f=1;next} /^```$/{f=0} f' "$(POLICY)"; }

@test "the policy doc exists and carries all six required clauses" {
  [ -f "$(POLICY)" ]
  grep -q '^## Silence contract' "$(POLICY)"
  grep -q '^## Escalation whitelist' "$(POLICY)"
  grep -q '^## Escalation form' "$(POLICY)"
  grep -q '^## The no-op reply' "$(POLICY)"
  grep -q '^## Anti-idle-drift' "$(POLICY)"
  grep -q '^## Away-mode authority carve-out' "$(POLICY)"
}
@test "anti-drift: the doc's escalation-codes block matches cb_escalation_codes exactly" {
  [ -n "$(doc_codes)" ]
  [ "$(doc_codes)" = "$(cb_escalation_codes)" ]
}
@test "the escalation form names all four parts, in order, on one line" {
  grep -q 'evidence, then consequence, then options, then recommendation' "$(POLICY)"
  grep -q '^Options: ' "$(POLICY)"
  grep -q '^Recommend: ' "$(POLICY)"
}
@test "the no-op reply is stated as one fixed literal line" {
  grep -q '^`Nothing needs you\.`$' "$(POLICY)"
}

# --- the gate at the chokepoint ---------------------------------------------
# A refused escalation must not deliver AND must not fire the R16 ceiling push:
# a non-escalation is not a held escalation.
setup_escalate_env() {
  load ../lib/paths.sh; load ../lib/push.sh; load ../lib/coordinator.sh
  export CB_TMUX_BIN="$BATS_TEST_TMPDIR/faketmux"
  printf '#!/usr/bin/env bash\necho "tmux $*" >> "$CB_TMUX_LOG"\n' > "$CB_TMUX_BIN"; chmod +x "$CB_TMUX_BIN"
  export CB_TMUX_LOG="$BATS_TEST_TMPDIR/tmux.log"
  export CB_SEND_DELAY=0
  export CB_INJECT_MARK='@@'
  export CB_COORD_PANE_CMD="cat '$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)/fixtures/panes/coord-idle-empty.txt'"      # real idle capture — empty composer, deliverable
  export MOCK_DIR="$BATS_TEST_TMPDIR/mock"; mkdir -p "$MOCK_DIR"
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$@" > "$MOCK_DIR/curl.argv"\n# drain a PIPED payload, but never block on an inherited stdin (a tty or the\n# suite\x27s own descriptor never EOFs — that hung the whole suite on this test)\n[ -p /dev/stdin ] && cat >/dev/null\nexit 0\n' > "$MOCK_DIR/curlmock"
  chmod +x "$MOCK_DIR/curlmock"
  export CB_CURL_CMD="$MOCK_DIR/curlmock" CB_PUSH_URL="https://ntfy/x"
}

@test "gate: a whitelisted code delivers" {
  setup_escalate_env
  run cb_escalate "test escalation" 0 "$CB_HOME/beacons/a.alarm" k1 decision
  [ "$status" -eq 0 ]
  grep -aq 'test escalation' "$CB_TMUX_LOG"
}
@test "gate: a non-whitelisted code never delivers and logs POLICY-REFUSED" {
  setup_escalate_env
  run cb_escalate "chatty status update" 0 "$CB_HOME/beacons/b.alarm" k2 fyi
  [ "$status" -ne 0 ]
  [ ! -f "$CB_TMUX_LOG" ] || ! grep -aq 'chatty status update' "$CB_TMUX_LOG"
  grep -q 'POLICY-REFUSED' "$CB_HOME/logs/events"
  grep -q 'code=fyi' "$CB_HOME/logs/events"
}
@test "gate: a missing code is refused (fail-closed)" {
  setup_escalate_env
  run cb_escalate "no code at all" 0 "$CB_HOME/beacons/c.alarm" k3
  [ "$status" -ne 0 ]
  grep -q 'POLICY-REFUSED' "$CB_HOME/logs/events"
}
@test "gate: a refused escalation does NOT fire the R16 ceiling push" {
  setup_escalate_env
  run cb_escalate "chatty status update" 9999 "$CB_HOME/beacons/d.alarm" k4 fyi
  [ "$status" -ne 0 ]
  [ ! -f "$MOCK_DIR/curl.argv" ]                      # no out-of-band push
  [ ! -f "$CB_HOME/beacons/d.alarm" ]                 # no alarm marker written
}
@test "gate: a whitelisted code held by focus STILL fires the ceiling push" {
  setup_escalate_env
  printf 'focus' > "$CB_HOME/mode"
  run cb_escalate "real escalation" 9999 "$CB_HOME/beacons/e.alarm" k5 decision
  [ "$status" -ne 0 ]                                  # held, not delivered
  [ -f "$MOCK_DIR/curl.argv" ]                         # but surfaced out-of-band
}

# --- every existing caller path still escalates (no silently killed path) ----
mk_notify_task() {   # mk_notify_task <slug> — a task with a matured event hash
  mkdir -p "$CB_HOME/tasks/$1"
  printf 'abc123' > "$CB_HOME/beacons/$1.eventhash"
  touch -d '10 minutes ago' "$CB_HOME/beacons/$1.eventhash"
}
notify_env() {
  export CB_TMUX_BIN="$BATS_TEST_TMPDIR/faketmux"
  printf '#!/usr/bin/env bash\necho "tmux $*" >> "$CB_TMUX_LOG"\n' > "$CB_TMUX_BIN"; chmod +x "$CB_TMUX_BIN"
  export CB_TMUX_LOG="$BATS_TEST_TMPDIR/tmux.log"
  export CB_SEND_DELAY=0 CB_GRACE_SECS=90
  export CB_COORD_PANE_CMD="cat '$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)/fixtures/panes/coord-idle-empty.txt'"
}

@test "caller path: cb-notify needs-input still delivers" {
  notify_env; mk_notify_task n1
  run scripts/cerebro/cb-notify n1 needs-input "pick a carrier"
  [ "$status" -eq 0 ]
  grep -aq 'n1 needs-input' "$CB_TMUX_LOG"
}
@test "caller path: cb-notify blocked-exhausted still delivers" {
  notify_env; mk_notify_task n2
  run scripts/cerebro/cb-notify n2 blocked-exhausted "spend-wedge"
  [ "$status" -eq 0 ]
  grep -aq 'n2 blocked-exhausted' "$CB_TMUX_LOG"
}
@test "caller path: cb-notify needs-relaunch still delivers" {
  notify_env; mk_notify_task n3
  run scripts/cerebro/cb-notify n3 needs-relaunch "build/3-implement"
  [ "$status" -eq 0 ]
  grep -aq 'n3 needs-relaunch' "$CB_TMUX_LOG"
}
@test "caller path: cb-digest still delivers its coalesced digest" {
  load ../lib/classify.sh
  notify_env
  local td="$CB_HOME/tasks/d1"; mkdir -p "$td"
  printf '%s open %s needs-input pick carrier\n' \
    "$(date -u -d '2 minutes ago' +%Y-%m-%dT%H:%M:%S+00:00)" \
    "$(_decision_key needs-input 'pick carrier')" > "$td/decisions"
  run scripts/cerebro/cb-digest
  [ "$status" -eq 0 ]
  grep -aq 'Supervisor escalate (1):' "$CB_TMUX_LOG"
}
