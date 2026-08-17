#!/usr/bin/env bats
# cb-digest (R15): coalesce the open-decision set across tasks into ONE pre-read
# digest line, flushed when the OLDEST UNDELIVERED open decision ages past
# CB_ESCALATE_BATCH_SECS (or on catch-up). Per-key delivered-dedup; reuses
# cb_escalate for focus/R17/R16 delivery.

setup() {
  load ../lib/classify.sh
  export CB_HOME="$BATS_TEST_TMPDIR/.cerebro"; mkdir -p "$CB_HOME/tasks" "$CB_HOME/beacons" "$CB_HOME/logs"
  export CB_TMUX_BIN="$BATS_TEST_TMPDIR/faketmux"
  printf '#!/usr/bin/env bash\necho "tmux $*" >> "$CB_TMUX_LOG"\n' > "$CB_TMUX_BIN"; chmod +x "$CB_TMUX_BIN"
  export CB_TMUX_LOG="$BATS_TEST_TMPDIR/tmux.log"
  export CB_SEND_DELAY=0
  export CB_INJECT_MARK='@@'                                  # visible test marker
  export CB_COORD_PANE_CMD="cat '$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)/fixtures/panes/coord-idle-empty.txt'"     # real idle capture — empty composer, deliverable
}

# open a decision on a task with a given open-timestamp age (seconds ago)
mk_decision() { # mk_decision <slug> <state> <gate> <age-iso>
  local td="$CB_HOME/tasks/$1"; mkdir -p "$td"
  printf '%s open %s %s %s\n' "$4" "$(_decision_key "$2" "$3")" "$2" "$3" > "$td/decisions"
}
iso_ago() { date -u -d "$1" +%Y-%m-%dT%H:%M:%S+00:00; }
digest_sends() { [ -f "$CB_TMUX_LOG" ] || { echo 0; return; }; grep -ac 'Supervisor escalate' "$CB_TMUX_LOG"; }

@test "R15: oldest open decision under the batch window → no flush" {
  mk_decision t-young needs-input "gate A" "$(iso_ago '30 seconds ago')"   # < 90
  run scripts/cerebro/cb-digest
  [ "$status" -eq 0 ]
  [ "$(digest_sends)" -eq 0 ]
}
@test "R15: oldest past the window → ONE digest line naming every open decision" {
  mk_decision t-old  needs-input "pick carrier" "$(iso_ago '2 minutes ago')"
  mk_decision t-two  blocked     "upstream 500s" "$(iso_ago '1 minute ago')"
  run scripts/cerebro/cb-digest
  [ "$status" -eq 0 ]
  [ "$(digest_sends)" -eq 1 ]
  grep -aq 'Supervisor escalate (2):' "$CB_TMUX_LOG"
  grep -aq 't-old: pick carrier' "$CB_TMUX_LOG"
  grep -aq 't-two: upstream 500s' "$CB_TMUX_LOG"
  grep -aq '(pre-read)' "$CB_TMUX_LOG"
}
@test "R15: per-key dedup — a second run over the same set does NOT re-flush" {
  mk_decision t-a needs-input "gate A" "$(iso_ago '2 minutes ago')"
  run scripts/cerebro/cb-digest; [ "$(digest_sends)" -eq 1 ]
  run scripts/cerebro/cb-digest; [ "$(digest_sends)" -eq 1 ]   # unchanged set → no re-flush
}
@test "R15: a NEW open key after a flush re-flushes" {
  mk_decision t-a needs-input "gate A" "$(iso_ago '2 minutes ago')"
  run scripts/cerebro/cb-digest; [ "$(digest_sends)" -eq 1 ]
  mk_decision t-b needs-input "gate B" "$(iso_ago '2 minutes ago')"
  run scripts/cerebro/cb-digest
  [ "$(digest_sends)" -eq 2 ]
  grep -aq 'gate B' "$CB_TMUX_LOG"
}
@test "R15: no-starvation — a churny NEW arrival does not reset the oldest window" {
  mk_decision t-old needs-input "old gate" "$(iso_ago '2 minutes ago')"   # already past 90
  mk_decision t-new needs-input "new gate" "$(iso_ago 'now')"             # fresh
  run scripts/cerebro/cb-digest
  [ "$(digest_sends)" -eq 1 ]                                   # flushed because the OLDEST aged out
}
@test "R15: catch-up mode flushes the full set now, ignoring the window, then clears" {
  mk_decision t-a needs-input "gate A" "$(iso_ago '10 seconds ago')"   # under the window
  printf 'catch-up' > "$CB_HOME/mode"
  run scripts/cerebro/cb-digest
  [ "$(digest_sends)" -eq 1 ]
  [ ! -f "$CB_HOME/mode" ]                                      # one-shot: cleared after delivery
}
@test "R15: a resolved decision drops out of the digest" {
  local td="$CB_HOME/tasks/t-r"; mkdir -p "$td"
  k=$(_decision_key needs-input "resolved gate")
  printf '%s open %s needs-input resolved gate\n%s resolved %s\n' "$(iso_ago '2 minutes ago')" "$k" "$(iso_ago '1 minute ago')" "$k" > "$td/decisions"
  run scripts/cerebro/cb-digest
  [ "$(digest_sends)" -eq 0 ]                                   # nothing open → no flush
}
@test "R15: focus holds the digest; past the R16 ceiling it fires the out-of-band push" {
  mk_decision t-a needs-input "gate A" "$(iso_ago '6 minutes ago')"   # > CB_MAX_DEFER_SECS 300
  printf 'focus' > "$CB_HOME/mode"
  export MOCK_DIR="$BATS_TEST_TMPDIR/mock"; mkdir -p "$MOCK_DIR"
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$@" > "$MOCK_DIR/curl.argv"\n# drain a PIPED payload, but never block on an inherited stdin (a tty or the\n# suite\x27s own descriptor never EOFs — that hung the whole suite on this test)\n[ -p /dev/stdin ] && cat >/dev/null\nexit 0\n' > "$MOCK_DIR/curlmock"; chmod +x "$MOCK_DIR/curlmock"
  export CB_CURL_CMD="$MOCK_DIR/curlmock" CB_PUSH_URL="https://ntfy/x"
  run scripts/cerebro/cb-digest
  [ "$(digest_sends)" -eq 0 ]                                   # held from the coordinator (focus)
  [ -f "$MOCK_DIR/curl.argv" ]                                 # but surfaced out-of-band past the ceiling
}
