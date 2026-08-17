#!/usr/bin/env bats
# cb-notify (T27): the minimal §8.1 skeleton — hold-by-default, hard-interrupt
# only for needs-input, one line into the Cerebro coordinator session after a
# grace hold. Dedup rides T21's event hash.

setup() {
  export CB_HOME="$BATS_TEST_TMPDIR/.cerebro"
  mkdir -p "$CB_HOME/tasks/fix-n" "$CB_HOME/beacons" "$CB_HOME/logs"
  export CB_TMUX_BIN="$BATS_TEST_TMPDIR/faketmux"
  cat > "$CB_TMUX_BIN" <<'EOF'
#!/usr/bin/env bash
echo "tmux $*" >> "$CB_TMUX_LOG"
EOF
  chmod +x "$CB_TMUX_BIN"; export CB_TMUX_LOG="$BATS_TEST_TMPDIR/tmux.log"
  export CB_GRACE_SECS=90
  export CB_SEND_DELAY=0   # cb-notify Enter-splits (7/13 hotfix); no pause under the mock
  # R17: delivery is now gated on an affirmatively-empty coordinator composer.
  # Default the pane read to an empty composer so the send-path tests deliver;
  # the R17 tests below override it to busy/unknown to assert deferral.
  export CB_COORD_PANE_CMD="cat '$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)/fixtures/panes/coord-idle-empty.txt'"   # real idle capture — empty composer, deliverable
}

# one notify ACTION = one text send (Enter is a separate key event since the hotfix)
sends() { grep -ac 'cb-watch:' "$CB_TMUX_LOG"; }

arm_event() { # arm_event <age-spec>  — the T21 event-hash beacon for fix-n
  printf 'somehash' > "$CB_HOME/beacons/fix-n.eventhash"
  touch -d "$1" "$CB_HOME/beacons/fix-n.eventhash"
}

@test "R6: paused stays board-only — no send even with an aged event (never a wedge page)" {
  arm_event '2 hours ago'
  run scripts/cerebro/cb-notify fix-n paused
  [ "$status" -eq 0 ]
  [ ! -s "$CB_TMUX_LOG" ]
}

@test "needs-input event younger than grace → no send (hold)" {
  arm_event 'now'
  run scripts/cerebro/cb-notify fix-n needs-input "build/awaiting-approval"
  [ "$status" -eq 0 ]
  [ ! -s "$CB_TMUX_LOG" ]
}

@test "needs-input older than grace → exactly one send, repeat call sends nothing" {
  arm_event '5 minutes ago'
  run scripts/cerebro/cb-notify fix-n needs-input "build/awaiting-approval"
  [ "$status" -eq 0 ]
  grep -aq 'cb-watch: fix-n needs-input (build/awaiting-approval)' "$CB_TMUX_LOG"
  [ "$(sends)" = "1" ]
  run scripts/cerebro/cb-notify fix-n needs-input "build/awaiting-approval"
  [ "$(sends)" = "1" ]   # dedup on the event hash
}

@test "a NEW gate (event hash changed) notifies again after its own grace" {
  arm_event '5 minutes ago'
  run scripts/cerebro/cb-notify fix-n needs-input "build/awaiting-approval"
  printf 'otherhash' > "$CB_HOME/beacons/fix-n.eventhash"
  touch -d '4 minutes ago' "$CB_HOME/beacons/fix-n.eventhash"
  run scripts/cerebro/cb-notify fix-n needs-input "review/awaiting-approval"
  [ "$(sends)" = "2" ]
}

@test "ready-for-review never sends (batch on surface, board-only)" {
  arm_event '5 minutes ago'
  run scripts/cerebro/cb-notify fix-n ready-for-review ""
  [ "$status" -eq 0 ]
  [ ! -s "$CB_TMUX_LOG" ]
}

@test "mode=focus holds all sends (needs-input and blocked-exhausted)" {
  arm_event '90 seconds ago'   # deliverable (>grace) but under the defer ceiling
  printf 'focus' > "$CB_HOME/mode"
  run scripts/cerebro/cb-notify fix-n needs-input "gate"
  [ "$status" -eq 0 ]; [ ! -s "$CB_TMUX_LOG" ]
  run scripts/cerebro/cb-notify fix-n blocked-exhausted "spend-wedge"
  [ "$status" -eq 0 ]; [ ! -s "$CB_TMUX_LOG" ]
}

# --- R16: focus-mode ceiling — a deferred escalation held past the ceiling
# stops being invisible via an out-of-band push + a durable marker. ---

curl_mock() { # arms CB_CURL_CMD to record argv + stdin (cb-guard pattern)
  export MOCK_DIR="$BATS_TEST_TMPDIR/mock"; mkdir -p "$MOCK_DIR"
  cat > "$MOCK_DIR/curlmock" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$MOCK_DIR/curl.argv"
cat > "$MOCK_DIR/curl.stdin"
echo ok
EOF
  chmod +x "$MOCK_DIR/curlmock"; export CB_CURL_CMD="$MOCK_DIR/curlmock"
}

@test "R16: focus + escalation UNDER the ceiling → held, no push, no alarm marker" {
  arm_event '2 minutes ago'   # < CB_MAX_DEFER_SECS (300)
  printf 'focus' > "$CB_HOME/mode"; curl_mock
  export CB_PUSH_URL="https://ntfy.example/cerebro"
  run scripts/cerebro/cb-notify fix-n needs-input "gate"
  [ "$status" -eq 0 ]
  [ ! -s "$CB_TMUX_LOG" ]                       # never sent to the coordinator
  [ ! -f "$MOCK_DIR/curl.argv" ]                # no push under the ceiling
  [ ! -f "$CB_HOME/beacons/fix-n.defer-alarmed" ]
}

@test "R16: focus + escalation PAST the ceiling → out-of-band push fires, marker written, still no coordinator send" {
  arm_event '6 minutes ago'   # > CB_MAX_DEFER_SECS (300)
  printf 'focus' > "$CB_HOME/mode"; curl_mock
  export CB_PUSH_URL="https://ntfy.example/cerebro"; export CB_PUSH_TOKEN="push-sekrit"
  run scripts/cerebro/cb-notify fix-n needs-input "gate"
  [ "$status" -eq 0 ]
  [ ! -s "$CB_TMUX_LOG" ]                       # NOT delivered to the held coordinator channel
  [ -f "$MOCK_DIR/curl.argv" ]                  # out-of-band push fired
  grep -q 'ntfy.example/cerebro' "$MOCK_DIR/curl.argv"
  ! grep -q 'push-sekrit' "$MOCK_DIR/curl.argv" # token off argv (stdin config)
  grep -q 'push-sekrit' "$MOCK_DIR/curl.stdin"
  [ -f "$CB_HOME/beacons/fix-n.defer-alarmed" ] # durable marker
}

@test "R16: ceiling alarm dedups — fires once per deferred episode" {
  arm_event '6 minutes ago'
  printf 'focus' > "$CB_HOME/mode"; curl_mock
  export CB_PUSH_URL="https://ntfy.example/cerebro"
  run scripts/cerebro/cb-notify fix-n needs-input "gate"
  [ -f "$MOCK_DIR/curl.argv" ]; rm -f "$MOCK_DIR/curl.argv"
  run scripts/cerebro/cb-notify fix-n needs-input "gate"   # same episode
  [ ! -f "$MOCK_DIR/curl.argv" ]                # no second push
}

@test "R16: ceiling with NO push channel → durable marker + loud events line, no crash" {
  arm_event '6 minutes ago'
  printf 'focus' > "$CB_HOME/mode"
  unset CB_PUSH_URL 2>/dev/null || true
  run scripts/cerebro/cb-notify fix-n needs-input "gate"
  [ "$status" -eq 0 ]                            # degrades, never crashes the watcher
  [ -f "$CB_HOME/beacons/fix-n.defer-alarmed" ]  # durable marker still written
  grep -q 'DEFER-ALARM' "$CB_HOME/logs/events"   # loud local log line
}

@test "R16: CB_MAX_DEFER_SECS is tunable (lower ceiling fires sooner)" {
  arm_event '30 seconds ago'
  printf 'focus' > "$CB_HOME/mode"; curl_mock
  export CB_PUSH_URL="https://ntfy.example/cerebro"
  CB_MAX_DEFER_SECS=10 CB_GRACE_SECS=5 run scripts/cerebro/cb-notify fix-n needs-input "gate"
  [ -f "$MOCK_DIR/curl.argv" ]
}

@test "grace is operator-tunable via CB_GRACE_SECS" {
  arm_event '10 seconds ago'
  CB_GRACE_SECS=5 run scripts/cerebro/cb-notify fix-n needs-input "gate"
  grep -q 'send-keys' "$CB_TMUX_LOG"
}

# --- R17: composer guard on the shared coordinator channel ---

@test "R17: busy coordinator pane → deferred, no send (never collides with Kyle typing / working)" {
  arm_event '5 minutes ago'
  export CB_COORD_PANE_CMD="cat '$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)/fixtures/panes/coord-busy.txt'"   # real working capture — live ticking timer
  run scripts/cerebro/cb-notify fix-n needs-input "gate"
  [ "$status" -eq 0 ]
  [ ! -s "$CB_TMUX_LOG" ]                                  # deferred, not sent
  [ ! -f "$CB_HOME/beacons/fix-n.notified" ]               # not marked delivered → retries next tick
}

@test "R17: dead-shell (unknown) coordinator pane → deferred, NEVER executes the escalation as a shell command" {
  arm_event '5 minutes ago'
  export CB_COORD_PANE_CMD="printf 'kyle@np-kf1-cus:~/vault\$ \n'"
  run scripts/cerebro/cb-notify fix-n needs-input "gate"
  [ "$status" -eq 0 ]
  [ ! -s "$CB_TMUX_LOG" ]
}

@test "R17: empty composer → delivers (types once + separate Enter), marks notified" {
  arm_event '5 minutes ago'
  export CB_COORD_PANE_CMD="cat '$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)/fixtures/panes/coord-idle-empty.txt'"
  run scripts/cerebro/cb-notify fix-n needs-input "gate"
  grep -aq 'cb-watch: fix-n needs-input (gate)' "$CB_TMUX_LOG"
  grep -qx 'tmux send-keys -t Cerebro Enter' "$CB_TMUX_LOG"
  [ "$(cat "$CB_HOME/beacons/fix-n.notified")" = "somehash" ]
}

@test "R17 BLOCKER: pane-defer past the ceiling (NOT focus) still fires the out-of-band alarm" {
  # the exact black hole R16 closes must not reopen via a non-focus defer:
  # coordinator crashed to a shell, no focus mode, escalation deferred past ceiling.
  arm_event '6 minutes ago'
  export CB_COORD_PANE_CMD="printf 'kyle@host:~\$ \n'"   # unknown → send deferred
  curl_mock; export CB_PUSH_URL="https://ntfy.example/cerebro"
  run scripts/cerebro/cb-notify fix-n needs-input "gate"
  [ "$status" -eq 0 ]
  [ ! -s "$CB_TMUX_LOG" ]                        # still not delivered to the dead coordinator
  [ -f "$MOCK_DIR/curl.argv" ]                   # but the out-of-band alarm fired
  [ -f "$CB_HOME/beacons/fix-n.defer-alarmed" ]
}

# --- watch wiring: needs-input tasks get a notify attempt every tick, so the
# grace hold matures even with no new event ---
@test "R15: cb-watch tick opens the decision and flushes it as a coalesced digest (replaces the per-task page)" {
  export HOME="$BATS_TEST_TMPDIR/home"; mkdir -p "$HOME"
  CWT="$BATS_TEST_TMPDIR/worktree"; mkdir -p "$CWT/.ai/specs/fix-n"
  printf 'kind=code\nworktree=%s\njira=EJA-9\nsession=fix-n\ntarget=ultron\n' "$CWT" > "$CB_HOME/tasks/fix-n/meta"
  printf -- '---\ncurrent_task: build/awaiting-approval\n---\n' > "$CWT/.ai/specs/fix-n/manifest.md"
  export CB_SESSION_LIST_CMD="printf 'fix-n\n'"
  export CB_ESCALATE_BATCH_SECS=0    # flush the batch window immediately for the test
  run scripts/cerebro/cb-watch --tick
  [ "$status" -eq 0 ]
  grep -aq 'Supervisor escalate' "$CB_TMUX_LOG"
  grep -aq 'fix-n: build/awaiting-approval' "$CB_TMUX_LOG"
}

# --- CB_PUSH_FORMAT: raw (ntfy, the existing contract) vs slack (JSON body) ---
# Exercised against cb_push directly — the format switch is push.sh's, and every
# caller (cb-guard, cb-notify, cb-digest, cb-watchlist) inherits it unchanged.

push_body_mock() {   # captures the -d body verbatim, plus argv and stdin
  export MOCK_DIR="$BATS_TEST_TMPDIR/pushmock"; mkdir -p "$MOCK_DIR"
  cat > "$MOCK_DIR/curlmock" <<'EOF'
#!/usr/bin/env bash
prev=""
for a in "$@"; do
  [ "$prev" = "-d" ] && printf '%s' "$a" > "$MOCK_DIR/curl.body"
  prev="$a"
done
printf '%s\n' "$@" > "$MOCK_DIR/curl.argv"
# only drain stdin when curl was actually handed a --config pipe; an
# unconditional `cat` blocks forever on the no-token path, which has no pipe.
case " $* " in *" --config "*) cat > "$MOCK_DIR/curl.stdin";; esac
echo ok
EOF
  chmod +x "$MOCK_DIR/curlmock"; export CB_CURL_CMD="$MOCK_DIR/curlmock"
  export CB_PUSH_URL="https://ntfy.example/cerebro"
  unset CB_PUSH_TOKEN CB_PUSH_FORMAT 2>/dev/null || true
  source "$BATS_TEST_DIRNAME/../lib/push.sh"
}

@test "CB_PUSH_FORMAT unset → raw body, no content-type header (today's contract)" {
  push_body_mock
  run cb_push 'watcher down for 6m'
  [ "$status" -eq 0 ]
  [ "$(cat "$MOCK_DIR/curl.body")" = 'watcher down for 6m' ]
  ! grep -q 'Content-Type' "$MOCK_DIR/curl.argv"
  grep -qx -- '-s' "$MOCK_DIR/curl.argv"
  grep -qx 'https://ntfy.example/cerebro' "$MOCK_DIR/curl.argv"
}

@test "CB_PUSH_FORMAT=raw is byte-identical to the unset default" {
  push_body_mock
  run cb_push 'watcher down for 6m'
  cp "$MOCK_DIR/curl.argv" "$BATS_TEST_TMPDIR/argv.default"
  export CB_PUSH_FORMAT=raw
  run cb_push 'watcher down for 6m'
  diff "$BATS_TEST_TMPDIR/argv.default" "$MOCK_DIR/curl.argv"
}

@test "CB_PUSH_FORMAT=slack sends a JSON body with a JSON content-type" {
  push_body_mock; export CB_PUSH_FORMAT=slack
  run cb_push 'watcher down for 6m'
  [ "$status" -eq 0 ]
  [ "$(jq -r .text "$MOCK_DIR/curl.body")" = 'watcher down for 6m' ]
  grep -qx 'Content-Type: application/json' "$MOCK_DIR/curl.argv"
}

@test "slack: quotes, backslashes, newlines and unicode survive as valid JSON" {
  push_body_mock; export CB_PUSH_FORMAT=slack
  msg='watch:exec "Carrier Bug List" -> C:\path
line two — é ✓ 100%'
  run cb_push "$msg"
  [ "$status" -eq 0 ]
  jq -e . "$MOCK_DIR/curl.body" >/dev/null          # parses at all
  [ "$(jq -r .text "$MOCK_DIR/curl.body")" = "$msg" ]   # round-trips byte-exact
}

@test "slack: a message that is itself a JSON object stays a string, not a nested object" {
  push_body_mock; export CB_PUSH_FORMAT=slack
  run cb_push '{"text":"injected","channel":"#general"}'
  [ "$status" -eq 0 ]
  [ "$(jq -r '.text' "$MOCK_DIR/curl.body")" = '{"text":"injected","channel":"#general"}' ]
  [ "$(jq -r 'keys | join(",")' "$MOCK_DIR/curl.body")" = 'text' ]
}

@test "slack + CB_PUSH_TOKEN compose — token still on stdin, never argv" {
  push_body_mock; export CB_PUSH_FORMAT=slack CB_PUSH_TOKEN=push-sekrit
  run cb_push 'gate open'
  [ "$status" -eq 0 ]
  grep -qx 'Content-Type: application/json' "$MOCK_DIR/curl.argv"
  ! grep -q 'push-sekrit' "$MOCK_DIR/curl.argv"
  grep -q 'push-sekrit' "$MOCK_DIR/curl.stdin"
  [ "$(jq -r .text "$MOCK_DIR/curl.body")" = 'gate open' ]
}

@test "unset CB_PUSH_URL returns 1 and never calls curl, whatever the format" {
  push_body_mock; export CB_PUSH_FORMAT=slack
  unset CB_PUSH_URL
  run cb_push 'nowhere to go'
  [ "$status" -eq 1 ]
  [ ! -f "$MOCK_DIR/curl.body" ]
}

@test "an unknown CB_PUSH_FORMAT refuses loudly rather than sending something malformed" {
  push_body_mock; export CB_PUSH_FORMAT=teams
  run cb_push 'gate open'
  [ "$status" -eq 2 ]                      # 2 = configured but unusable, not 1 = no channel
  [ ! -f "$MOCK_DIR/curl.body" ]
  [[ "$output" == *"unknown CB_PUSH_FORMAT=teams"* ]]
}

@test "exit codes are distinct: 1 = no channel, 2 = channel set but unusable" {
  push_body_mock
  unset CB_PUSH_URL
  run cb_push 'x'; [ "$status" -eq 1 ]           # no channel
  export CB_PUSH_URL="https://ntfy.example/cerebro"
  export CB_PUSH_FORMAT=teams
  run cb_push 'x'; [ "$status" -eq 2 ]           # configured, but unusable
  [ ! -f "$MOCK_DIR/curl.body" ]
}

@test "a misconfigured format is NOT reported to the operator as an unset URL" {
  # the whole point of the 1-vs-2 split: cb-watchlist's events line must not say
  # "set CB_PUSH_URL" when CB_PUSH_URL is exactly what is already set.
  push_body_mock; export CB_PUSH_FORMAT=teams
  _pushrc=0
  cb_push 'x' || _pushrc=$?
  [ "$_pushrc" = 2 ]
  case "$_pushrc" in 2) note="push channel MISCONFIGURED — check CB_PUSH_FORMAT";; *) note="no push channel — set CB_PUSH_URL";; esac
  [[ "$note" != *"set CB_PUSH_URL"* ]]
}
