#!/usr/bin/env bats
# cb-guard (T37): watcher liveness + connector auth health + push fallback.

setup() {
  export CB_HOME="$BATS_TEST_TMPDIR/.cerebro"
  mkdir -p "$CB_HOME/tasks" "$CB_HOME/beacons" "$CB_HOME/logs"
  export CB_TMUX_BIN="$BATS_TEST_TMPDIR/faketmux"
  cat > "$CB_TMUX_BIN" <<'EOF'
#!/usr/bin/env bash
echo "tmux $*" >> "$CB_TMUX_LOG"
EOF
  chmod +x "$CB_TMUX_BIN"; export CB_TMUX_LOG="$BATS_TEST_TMPDIR/tmux.log"
  export CB_MCP_CMD="printf 'atlassian: https://mcp.atlassian.com - ✓ Connected\n'"
  export MOCK_DIR="$BATS_TEST_TMPDIR/mock"; mkdir -p "$MOCK_DIR"
  cat > "$MOCK_DIR/curlmock" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$MOCK_DIR/curl.argv"
cat > "$MOCK_DIR/curl.stdin"
echo ok
EOF
  chmod +x "$MOCK_DIR/curlmock"
  export CB_CURL_CMD="$MOCK_DIR/curlmock"
  export CB_SEND_DELAY=0
  # R17: the coordinator send is now composer-guarded. Default the pane read to
  # an affirmatively-empty composer so the alert-send tests deliver; the defer
  # test below overrides it.
  export CB_COORD_PANE_CMD="cat '$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)/fixtures/panes/coord-idle-empty.txt'"
  # (e) the coordinator-signature canary samples every pane twice with a sleep
  # between. Off for the rest of the suite so it costs nothing and cannot bleed
  # into the tmux log those tests assert on; the canary tests turn it on.
  export CB_COORD_CANARY=0
}

in_flight_task() {
  mkdir -p "$CB_HOME/tasks/fix-g"
  printf 'running' > "$CB_HOME/beacons/fix-g.state"
}

@test "in-flight task + stale watcher heartbeat → watcher-down alert" {
  in_flight_task
  touch -d '30 minutes ago' "$CB_HOME/beacons/watch.heartbeat"
  run scripts/cerebro/cb-guard
  [ "$status" -eq 0 ]
  grep -q 'watcher down' "$CB_HOME/logs/events"
  grep -aq 'cb-guard: watcher down' "$CB_TMUX_LOG"
}

@test "R17: a non-empty coordinator pane defers the tmux alert — but push + events still fire" {
  in_flight_task
  touch -d '30 minutes ago' "$CB_HOME/beacons/watch.heartbeat"
  export CB_COORD_PANE_CMD="printf 'kyle@host:~\$ \n'"   # dead shell → coordinator send deferred
  export CB_PUSH_URL="https://ntfy.example/cerebro"
  run scripts/cerebro/cb-guard
  [ "$status" -eq 0 ]
  run grep -aq 'cb-guard: watcher down' "$CB_TMUX_LOG"  # NOT injected into the shell
  [ "$status" -ne 0 ]
  grep -q 'watcher down' "$CB_HOME/logs/events"          # durable record still written
  [ -f "$MOCK_DIR/curl.argv" ]                            # out-of-band push still fired
}

@test "fresh heartbeat → silent" {
  in_flight_task
  touch "$CB_HOME/beacons/watch.heartbeat"
  run scripts/cerebro/cb-guard
  [ "$status" -eq 0 ]
  [ ! -s "$CB_TMUX_LOG" ]
  ! grep -q 'watcher down' "$CB_HOME/logs/events" 2>/dev/null
}

@test "no in-flight tasks → stale heartbeat is not an alert" {
  touch -d '30 minutes ago' "$CB_HOME/beacons/watch.heartbeat"
  run scripts/cerebro/cb-guard
  [ ! -s "$CB_TMUX_LOG" ]
}

@test "missing heartbeat with in-flight tasks alerts (watcher never started)" {
  in_flight_task
  run scripts/cerebro/cb-guard
  grep -q 'watcher down' "$CB_HOME/logs/events"
}

@test "disconnected MCP connector → re-auth escalation" {
  export CB_MCP_CMD="printf 'atlassian: https://x - ✗ Disconnected (needs authentication)\nslack: https://y - ✓ Connected\n'"
  touch "$CB_HOME/beacons/watch.heartbeat"
  run scripts/cerebro/cb-guard
  grep -q 'atlassian needs re-auth' "$CB_HOME/logs/events"
  grep -aq 'cb-guard: atlassian needs re-auth' "$CB_TMUX_LOG"
  ! grep -q 'slack needs re-auth' "$CB_HOME/logs/events"
}

@test "CB_PUSH_URL set → one push per alert, token via stdin config not argv" {
  in_flight_task
  touch -d '30 minutes ago' "$CB_HOME/beacons/watch.heartbeat"
  export CB_PUSH_URL="https://ntfy.example/cerebro"
  export CB_PUSH_TOKEN="push-sekrit"
  run scripts/cerebro/cb-guard
  [ -f "$MOCK_DIR/curl.argv" ]
  grep -q 'ntfy.example/cerebro' "$MOCK_DIR/curl.argv"
  ! grep -q 'push-sekrit' "$MOCK_DIR/curl.argv"
  grep -q 'push-sekrit' "$MOCK_DIR/curl.stdin"
}

@test "no CB_PUSH_URL → no curl call" {
  in_flight_task
  touch -d '30 minutes ago' "$CB_HOME/beacons/watch.heartbeat"
  run scripts/cerebro/cb-guard
  [ ! -f "$MOCK_DIR/curl.argv" ]
}

# --- edge-triggered content dedup (lib/dedup.sh) -----------------------------
# The defect: 1,537 identical "needs re-auth" lines in logs/events, 74-82/day.

@test "dedup: the same warning on two consecutive runs logs exactly once" {
  export CB_MCP_CMD="printf 'atlassian: https://x - ✗ Disconnected (needs authentication)\n'"
  touch "$CB_HOME/beacons/watch.heartbeat"
  run scripts/cerebro/cb-guard; [ "$status" -eq 0 ]
  run scripts/cerebro/cb-guard; [ "$status" -eq 0 ]
  [ "$(grep -c 'atlassian needs re-auth' "$CB_HOME/logs/events")" -eq 1 ]
  # the tmux copy and the push are suppressed with it, not just the log line
  [ "$(grep -ac 'cb-guard: atlassian needs re-auth' "$CB_TMUX_LOG")" -eq 1 ]
}

@test "dedup RE-ARM: an alert that clears and later recurs logs again" {
  touch "$CB_HOME/beacons/watch.heartbeat"
  export CB_MCP_CMD="printf 'atlassian: https://x - ✗ Disconnected (needs authentication)\n'"
  run scripts/cerebro/cb-guard
  export CB_MCP_CMD="printf 'atlassian: https://x - ✓ Connected\n'"          # condition clears
  run scripts/cerebro/cb-guard
  export CB_MCP_CMD="printf 'atlassian: https://x - ✗ Disconnected (needs authentication)\n'"  # and recurs
  run scripts/cerebro/cb-guard
  [ "$(grep -c 'atlassian needs re-auth' "$CB_HOME/logs/events")" -eq 2 ]
}

@test "dedup does not suppress a DIFFERENT alert raised in the same run" {
  in_flight_task
  touch -d '30 minutes ago' "$CB_HOME/beacons/watch.heartbeat"
  export CB_MCP_CMD="printf 'atlassian: https://x - ✗ Disconnected (needs authentication)\n'"
  run scripts/cerebro/cb-guard
  grep -q 'watcher down' "$CB_HOME/logs/events"
  grep -q 'atlassian needs re-auth' "$CB_HOME/logs/events"
}

# --- allowlist scoping + name parsing ----------------------------------------
# Fixture is `claude mcp list` output copied verbatim on 2026-08-02. The old
# fixture used a bare name and U+2717, which is exactly why the plugin-name
# parse bug and the U+2718 gap both survived.

live_mcp_list() {
  export CB_MCP_CMD="cat <<'EOF'
claude.ai Google Calendar: https://calendarmcp.googleapis.com/mcp/v1 - ✔ Connected
claude.ai Gmail: https://gmailmcp.googleapis.com/mcp/v1 - ✔ Connected
claude.ai Google Drive: https://drivemcp.googleapis.com/mcp/v1 - ✔ Connected
claude.ai Atlassian Rovo: https://mcp.atlassian.com/v1/mcp - ✔ Connected
plugin:playwright:playwright: npx @playwright/mcp@latest - ✔ Connected
plugin:atlassian:atlassian: https://mcp.atlassian.com/v1/mcp/authv2 (HTTP) - ✔ Connected
plugin:voicemode:voicemode: uv run voicemode - ✘ Failed to connect — -32000: MCP error -32000: Connection closed
plugin:slack:slack: https://mcp.slack.com/mcp (HTTP) - ✔ Connected
kusto-mcp: npx -y kusto-mcp@latest - ✔ Connected
mempalace: mempalace-mcp  - ✔ Connected
EOF"
}

@test "allowlist: live output where only voicemode is down → silent" {
  live_mcp_list
  touch "$CB_HOME/beacons/watch.heartbeat"
  run scripts/cerebro/cb-guard
  [ "$status" -eq 0 ]
  ! grep -q 'needs re-auth' "$CB_HOME/logs/events" 2>/dev/null
  [ ! -s "$CB_TMUX_LOG" ]
}

@test "per-service: one down transport with healthy siblings → SILENT" {
  # The live 2026-08-14 shape: `atlassian` matches three rows, only Rovo is down,
  # and every fleet Jira call succeeds through the other two. Row-level alerting
  # called this "needs re-auth" and named a transport nothing depends on.
  export CB_MCP_CMD="printf 'claude.ai Atlassian Rovo: https://mcp.atlassian.com/v1/mcp - ! Needs authentication\nclaude.ai Atlassian: https://mcp.atlassian.com/v1/sse - ✔ Connected\nplugin:atlassian:atlassian: https://mcp.atlassian.com/v1/mcp/authv2 (HTTP) - ✔ Connected\n'"
  touch "$CB_HOME/beacons/watch.heartbeat"
  run scripts/cerebro/cb-guard
  [ "$status" -eq 0 ]
  ! grep -q 'needs re-auth' "$CB_HOME/logs/events" 2>/dev/null
  [ ! -s "$CB_TMUX_LOG" ]
}

@test "per-service: EVERY transport down → alerts once, naming all of them" {
  export CB_MCP_CMD="printf 'claude.ai Atlassian Rovo: https://mcp.atlassian.com/v1/mcp - ! Needs authentication\nclaude.ai Atlassian: https://mcp.atlassian.com/v1/sse - ✘ Failed to connect\n'"
  touch "$CB_HOME/beacons/watch.heartbeat"
  run scripts/cerebro/cb-guard
  grep -q 'needs re-auth' "$CB_HOME/logs/events"
  grep -q 'claude.ai Atlassian Rovo' "$CB_HOME/logs/events"
  grep -q 'no healthy atlassian transport remains' "$CB_HOME/logs/events"
  [ "$(grep -c 'needs re-auth' "$CB_HOME/logs/events")" -eq 1 ]
}

@test "allowlist: a down FLEET-CRITICAL plugin alerts, named in full not as 'plugin'" {
  export CB_MCP_CMD="printf 'plugin:atlassian:atlassian: https://mcp.atlassian.com/v1/mcp/authv2 (HTTP) - ✘ Failed to connect\n'"
  touch "$CB_HOME/beacons/watch.heartbeat"
  run scripts/cerebro/cb-guard
  grep -q 'plugin:atlassian:atlassian needs re-auth' "$CB_HOME/logs/events"
  ! grep -qx '.* cb-guard plugin needs re-auth .*' "$CB_HOME/logs/events"
}

@test "allowlist: a space-bearing claude.ai name parses and matches" {
  export CB_MCP_CMD="printf 'claude.ai Google Drive: https://drivemcp.googleapis.com/mcp/v1 - ✘ Failed to connect\n'"
  touch "$CB_HOME/beacons/watch.heartbeat"
  run scripts/cerebro/cb-guard
  grep -q 'claude.ai Google Drive needs re-auth' "$CB_HOME/logs/events"
}

# --- (d) gate-vocabulary canary ----------------------------------------------
# The watchdog watches the gate predicate. classify_code's old sentinel
# (*/awaiting-approval) matched 1 of 1,600 live current_task values and nobody
# noticed, because a gate predicate that never fires looks exactly like "no
# conductor is at a gate."

gate_task() { # gate_task <current_task>
  mkdir -p "$CB_HOME/tasks/gt"
  local wt="$BATS_TEST_TMPDIR/wt"; mkdir -p "$wt/.ai/specs/gt"
  printf 'kind=code\nworktree=%s\njira=EJA-1\nsession=gt\n' "$wt" > "$CB_HOME/tasks/gt/meta"
  printf -- '---\njira: EJA-1\ncurrent_task: %s\n---\n' "$1" > "$wt/.ai/specs/gt/manifest.md"
  printf 'x' > "$wt/.ai/specs/gt/context.md"; touch -d '1 hour ago' "$wt/.ai/specs/gt/context.md"
}

@test "canary: an unrecognised current_task is surfaced by name" {
  touch "$CB_HOME/beacons/watch.heartbeat"
  gate_task "ship/some-phase-nobody-has-written-yet"
  run scripts/cerebro/cb-guard
  [ "$status" -eq 0 ]
  grep -q 'gate detection has no opinion' "$CB_HOME/logs/events"
  grep -q 'ship/some-phase-nobody-has-written-yet' "$CB_HOME/logs/events"
}

@test "canary: a recognised gate or progress value is silent" {
  touch "$CB_HOME/beacons/watch.heartbeat"
  gate_task "ship/3-gate"
  run scripts/cerebro/cb-guard
  ! grep -q 'gate detection has no opinion' "$CB_HOME/logs/events" 2>/dev/null
  gate_task "ship/complete"
  run scripts/cerebro/cb-guard
  ! grep -q 'gate detection has no opinion' "$CB_HOME/logs/events" 2>/dev/null
}

@test "canary: the alert dedups like every other cb-guard alert" {
  touch "$CB_HOME/beacons/watch.heartbeat"
  gate_task "ship/brand-new-vocabulary"
  run scripts/cerebro/cb-guard
  run scripts/cerebro/cb-guard
  [ "$(grep -c 'gate detection has no opinion' "$CB_HOME/logs/events")" -eq 1 ]
}

@test "allowlist is overridable — CB_MCP_CRITICAL scopes the check" {
  live_mcp_list
  export CB_MCP_CRITICAL="voicemode"
  touch "$CB_HOME/beacons/watch.heartbeat"
  run scripts/cerebro/cb-guard
  grep -q 'plugin:voicemode:voicemode needs re-auth' "$CB_HOME/logs/events"
}

# --- (e) coordinator pane-signature canary ------------------------------------
# The signatures in lib/coordinator.sh key on Claude-TUI chrome, the TUI renames
# its chrome per version, and a pattern that matches NOTHING is indistinguishable
# from a quiet fleet — which is how `? for shortcuts` / `esc to interrupt` stayed
# dead for weeks while every escalation deferred. These tests are the regression
# net for that specific silence.

coord_canary_on() {
  export CB_COORD_CANARY=1
  export CB_COORD_CANARY_SECS=0      # no throttle inside a test
  export CB_COORD_CANARY_SETTLE=0    # no real sleep
  touch "$CB_HOME/beacons/watch.heartbeat"
}
# a scripted fake pane list + capture: $1 = pane names, $2 = script emitting a
# capture for "$pane" on each call (so a pane can differ between the two samples)
coord_panes() { export CB_COORD_PANES_CMD="printf '%s\n' $1"; }
FIXP() { echo "$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)/fixtures/panes"; }

@test "canary (e): the shipped signatures are silent on healthy panes" {
  coord_canary_on
  coord_panes "'a:0.0' 'b:0.0'"
  # both samples identical and busy-matching → nothing to report
  export CB_COORD_CAP_CMD="cat '$(FIXP)/coord-busy.txt'"
  run scripts/cerebro/cb-guard
  ! grep -q 'coordinator BUSY signature' "$CB_HOME/logs/events" 2>/dev/null
  ! grep -q 'coordinator READY test is dead' "$CB_HOME/logs/events" 2>/dev/null
}

@test "canary (e): BUSY matching nothing on a demonstrably working pane is named" {
  coord_canary_on
  coord_panes "'a:0.0'"
  export CB_COORD_BUSY_RE='zzz-no-live-build-says-this-zzz'
  # transcript advances between samples, composer holds still → the pane is working
  cat > "$BATS_TEST_TMPDIR/cap" <<'EOF'
#!/usr/bin/env bash
n="$BATS_TEST_TMPDIR/capn"; c=$(( $(cat "$n" 2>/dev/null || echo 0) + 1 )); echo "$c" > "$n"
printf '%s\n' "● turn output line $c" '─────' '❯ ' '─────'
EOF
  chmod +x "$BATS_TEST_TMPDIR/cap"
  export CB_COORD_CAP_CMD="$BATS_TEST_TMPDIR/cap"
  run scripts/cerebro/cb-guard
  grep -q 'coordinator BUSY signature matches nothing on working pane(s): a:0.0' "$CB_HOME/logs/events"
}

@test "canary (e): a pane whose COMPOSER moved is Kyle typing, not signature drift" {
  coord_canary_on
  coord_panes "'a:0.0'"
  export CB_COORD_BUSY_RE='zzz-no-live-build-says-this-zzz'
  cat > "$BATS_TEST_TMPDIR/cap" <<'EOF'
#!/usr/bin/env bash
n="$BATS_TEST_TMPDIR/capn"; c=$(( $(cat "$n" 2>/dev/null || echo 0) + 1 )); echo "$c" > "$n"
printf '%s\n' "● steady transcript" '─────' "❯ half a sentence $c" '─────'
EOF
  chmod +x "$BATS_TEST_TMPDIR/cap"
  export CB_COORD_CAP_CMD="$BATS_TEST_TMPDIR/cap"
  run scripts/cerebro/cb-guard
  ! grep -q 'coordinator BUSY signature' "$CB_HOME/logs/events" 2>/dev/null
}

@test "canary (e): a static pane proves nothing and is not reported" {
  coord_canary_on
  coord_panes "'a:0.0'"
  export CB_COORD_BUSY_RE='zzz-no-live-build-says-this-zzz'
  export CB_COORD_CAP_CMD="cat '$(FIXP)/coord-idle-empty.txt'"
  run scripts/cerebro/cb-guard
  ! grep -q 'coordinator BUSY signature' "$CB_HOME/logs/events" 2>/dev/null
}

@test "canary (e): no readable composer on ANY pane → the READY test is dead" {
  coord_canary_on
  coord_panes "'a:0.0' 'b:0.0'"
  export CB_COORD_CAP_CMD="cat '$(FIXP)/coord-login-shell.txt'"
  run scripts/cerebro/cb-guard
  grep -q 'coordinator READY test is dead' "$CB_HOME/logs/events"
}

@test "canary (e): BOTH signatures stubbed dead still raises (the 2026-08-02 state)" {
  coord_canary_on
  coord_panes "'a:0.0'"
  export CB_COORD_BUSY_RE='zzz-no-live-build-says-this-zzz'
  export CB_COORD_CAP_CMD="cat '$(FIXP)/coord-login-shell.txt'"
  run scripts/cerebro/cb-guard
  grep -q 'coordinator READY test is dead' "$CB_HOME/logs/events"
}

@test "canary (e): no live panes at all → silent (an empty box is not drift)" {
  coord_canary_on
  export CB_COORD_PANES_CMD="printf ''"
  run scripts/cerebro/cb-guard
  ! grep -q 'coordinator READY test is dead' "$CB_HOME/logs/events" 2>/dev/null
}

@test "canary (e): throttled — a second run inside the window re-samples nothing" {
  coord_canary_on
  export CB_COORD_CANARY_SECS=3600
  coord_panes "'a:0.0'"
  export CB_COORD_CAP_CMD="cat '$(FIXP)/coord-login-shell.txt'"
  run scripts/cerebro/cb-guard
  grep -q 'coordinator READY test is dead' "$CB_HOME/logs/events"
  rm -f "$CB_HOME/beacons/guard.alerts"    # defeat the (c) dedup, leave the throttle
  run scripts/cerebro/cb-guard
  [ "$(grep -c 'coordinator READY test is dead' "$CB_HOME/logs/events")" -eq 1 ]
}

@test "canary (e): the alert dedups like every other cb-guard alert" {
  coord_canary_on
  coord_panes "'a:0.0'"
  export CB_COORD_CAP_CMD="cat '$(FIXP)/coord-login-shell.txt'"
  run scripts/cerebro/cb-guard
  run scripts/cerebro/cb-guard
  [ "$(grep -c 'coordinator READY test is dead' "$CB_HOME/logs/events")" -eq 1 ]
}

@test "canary (e): off by default when CB_COORD_CANARY=0" {
  export CB_COORD_CANARY=0
  touch "$CB_HOME/beacons/watch.heartbeat"
  export CB_COORD_PANES_CMD="printf '%s\n' 'a:0.0'"
  export CB_COORD_CAP_CMD="cat '$(FIXP)/coord-login-shell.txt'"
  run scripts/cerebro/cb-guard
  ! grep -q 'coordinator READY test is dead' "$CB_HOME/logs/events" 2>/dev/null
}

@test "canary (e): the failing capture is KEPT — events line + capture file" {
  coord_canary_on
  coord_panes "'a:0.0'"
  export CB_COORD_BUSY_RE='zzz-no-live-build-says-this-zzz'
  # a bare spinner with no timer: the real form the first re-seed missed
  cat > "$BATS_TEST_TMPDIR/cap" <<'EOF'
#!/usr/bin/env bash
n="$BATS_TEST_TMPDIR/capn"; c=$(( $(cat "$n" 2>/dev/null || echo 0) + 1 )); echo "$c" > "$n"
printf '%s\n' '✻ Considering…' "  ⎿  ◻ turn output $c" '─────' '❯ ' '─────'
EOF
  chmod +x "$BATS_TEST_TMPDIR/cap"
  export CB_COORD_CAP_CMD="$BATS_TEST_TMPDIR/cap"
  run scripts/cerebro/cb-guard
  # the unmatched form is inline on the events line …
  grep -q 'COORD-CANARY-EVIDENCE pane=a:0.0' "$CB_HOME/logs/events"
  grep -q 'Considering…' "$CB_HOME/logs/events"
  # … and the full both-samples capture is on disk, with why it was kept
  [ -f "$CB_HOME/logs/coord-canary.capture" ]
  grep -q 'BUSY matched nothing' "$CB_HOME/logs/coord-canary.capture"
  grep -q '# sample A:' "$CB_HOME/logs/coord-canary.capture"
  grep -q '# sample B:' "$CB_HOME/logs/coord-canary.capture"
  grep -q 'zzz-no-live-build-says-this-zzz' "$CB_HOME/logs/coord-canary.capture"
  # the ALERT itself stays stable so the (c) dedup still works on it
  grep -q 'logs/coord-canary.capture' "$CB_HOME/logs/events"
}

@test "canary (e): evidence does not break the alert dedup" {
  coord_canary_on
  coord_panes "'a:0.0'"
  export CB_COORD_BUSY_RE='zzz-no-live-build-says-this-zzz'
  cat > "$BATS_TEST_TMPDIR/cap" <<'EOF'
#!/usr/bin/env bash
n="$BATS_TEST_TMPDIR/capn"; c=$(( $(cat "$n" 2>/dev/null || echo 0) + 1 )); echo "$c" > "$n"
printf '%s\n' '✻ Considering…' "  ⎿  turn output $c" '─────' '❯ ' '─────'
EOF
  chmod +x "$BATS_TEST_TMPDIR/cap"
  export CB_COORD_CAP_CMD="$BATS_TEST_TMPDIR/cap"
  run scripts/cerebro/cb-guard
  run scripts/cerebro/cb-guard
  # the spinner frame differs between runs, but the alert text does not
  [ "$(grep -c 'coordinator BUSY signature matches nothing' "$CB_HOME/logs/events")" -eq 1 ]
}

# --- (e) the OTHER polarity: BUSY matching a pane that is provably idle -------
# The drift test above only asks "does BUSY match nothing?". It is structurally
# blind to the inverse — BUSY matching a FINISHED pane — which is the same
# always-defer outage from the opposite direction, and permanent, because the
# line that matched is persisted transcript rather than a redrawn spinner.
@test "canary (e): BUSY matching a static, empty-composer pane is reported as FALSE BUSY" {
  coord_canary_on
  coord_panes "'a:0.0'"
  # over-broad pattern + a finished pane: `✻ Crunched for 11m 13s` is DONE
  export CB_COORD_BUSY_RE='for [0-9]+m'
  export CB_COORD_CAP_CMD="printf '%s\n' '✻ Crunched for 11m 13s' '─────' '❯ ' '─────'"
  run scripts/cerebro/cb-guard
  grep -q 'coordinator BUSY signature matches an IDLE pane: a:0.0' "$CB_HOME/logs/events"
  grep -q 'COORD-CANARY-EVIDENCE pane=a:0.0 why=FALSE BUSY' "$CB_HOME/logs/events"
  grep -q 'Crunched for 11m 13s' "$CB_HOME/logs/coord-canary.capture"
}
@test "canary (e): the SHIPPED pattern does not false-busy a finished pane" {
  coord_canary_on
  coord_panes "'a:0.0'"
  export CB_COORD_CAP_CMD="cat '$(FIXP)/coord-idle-empty.txt'"
  run scripts/cerebro/cb-guard
  ! grep -q 'matches an IDLE pane' "$CB_HOME/logs/events" 2>/dev/null
}
@test "canary (e): a genuinely busy pane is not FALSE BUSY (transcript advances)" {
  coord_canary_on
  coord_panes "'a:0.0'"
  cat > "$BATS_TEST_TMPDIR/cap" <<'EOF'
#!/usr/bin/env bash
n="$BATS_TEST_TMPDIR/capn"; c=$(( $(cat "$n" 2>/dev/null || echo 0) + 1 )); echo "$c" > "$n"
printf '%s\n' "✢ Gitifying… (${c}s · ↓ 1.1k tokens)" '─────' '❯ ' '─────'
EOF
  chmod +x "$BATS_TEST_TMPDIR/cap"
  export CB_COORD_CAP_CMD="$BATS_TEST_TMPDIR/cap"
  run scripts/cerebro/cb-guard
  ! grep -q 'matches an IDLE pane' "$CB_HOME/logs/events" 2>/dev/null
  ! grep -q 'matches nothing on working' "$CB_HOME/logs/events" 2>/dev/null
}
@test "canary (e): unchanged evidence does not re-log an events line" {
  coord_canary_on
  coord_panes "'a:0.0'"
  export CB_COORD_BUSY_RE='for [0-9]+m'
  export CB_COORD_CAP_CMD="printf '%s\n' '✻ Crunched for 11m 13s' '─────' '❯ ' '─────'"
  run scripts/cerebro/cb-guard
  rm -f "$CB_HOME/beacons/guard.alerts"   # defeat the (c) dedup, not the evidence guard
  run scripts/cerebro/cb-guard
  [ "$(grep -c 'COORD-CANARY-EVIDENCE' "$CB_HOME/logs/events")" -eq 1 ]
}
