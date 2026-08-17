#!/usr/bin/env bats
# watchlist.sh — config parse + poll scheduling + last-seen state + the material
# match seam. Covers milestone 2's bash seams (the MCP read/diff is the agent's;
# these are the deterministic parts the poll rides on).

setup() {
  export CB_HOME="$BATS_TEST_TMPDIR/.cerebro"; mkdir -p "$CB_HOME"
  export CB_WATCH_STATE="$CB_HOME/watchlist"
  export CB_WATCHLIST="$BATS_TEST_TMPDIR/watchlist.md"
  cat > "$CB_WATCHLIST" <<'EOF'
# header prose ignored

- signal: preprod
  kind: email-thread, jira-tickets
  jira: ASD-1112, ASD-1124, ASD-426
  poll_interval: 3h
  target_tracker: 01 Projects/edj/preprod-readiness.md
  material_rule: new, reopened, slip, env-down

- signal: exec-committee
  kind: email
  email_from: Lauren.Piwowarczyk@edwardjones.com, Katie.Robinson@edwardjones.com
  poll_interval: 6h
  target_tracker: 01 Projects/edj/exec-committee.md
  material_rule: new, reopened, slip
EOF
  load ../lib/watchlist.sh
}

@test "signals lists both blocks in order" {
  run watchlist_signals
  [ "${lines[0]}" = "preprod" ]
  [ "${lines[1]}" = "exec-committee" ]
}

@test "field reads scalar values, scoped to the right block" {
  [ "$(watchlist_field preprod poll_interval)" = "3h" ]
  [ "$(watchlist_field exec-committee poll_interval)" = "6h" ]
  [ "$(watchlist_field preprod target_tracker)" = "01 Projects/edj/preprod-readiness.md" ]
}

@test "field strips a trailing comment" {
  cat >> "$CB_WATCHLIST" <<'EOF'

- signal: probe
  poll_interval: 1h   # hourly, with a comment
  material_rule: new
EOF
  [ "$(watchlist_field probe poll_interval)" = "1h" ]
}

@test "list splits comma-separated jira keys" {
  run watchlist_list preprod jira
  [ "${#lines[@]}" -eq 3 ]
  [ "${lines[0]}" = "ASD-1112" ]
  [ "${lines[2]}" = "ASD-426" ]
}

@test "interval_secs parses h/m/d/s and bare seconds" {
  [ "$(watchlist_interval_secs 3h)" -eq 10800 ]
  [ "$(watchlist_interval_secs 30m)" -eq 1800 ]
  [ "$(watchlist_interval_secs 2d)" -eq 172800 ]
  [ "$(watchlist_interval_secs 90s)" -eq 90 ]
  [ "$(watchlist_interval_secs 120)" -eq 120 ]
  [ "$(watchlist_interval_secs junk)" -eq 0 ]
}

@test "a never-polled signal is due" {
  run watchlist_due preprod
  [ "$status" -eq 0 ]
}

@test "a just-polled signal is not due until the interval elapses" {
  export CB_NOW=1000000
  watchlist_mark_polled preprod          # stamps last_poll at CB_NOW
  run watchlist_due preprod              # 0s elapsed < 3h
  [ "$status" -ne 0 ]
  export CB_NOW=$(( 1000000 + 10799 ))   # just under 3h
  run watchlist_due preprod
  [ "$status" -ne 0 ]
  export CB_NOW=$(( 1000000 + 10800 ))   # exactly 3h → due
  run watchlist_due preprod
  [ "$status" -eq 0 ]
}

@test "last-seen state round-trips atomically" {
  printf 'ASD-1124=Reopened\nlast_email_id=abc123\n' | watchlist_state_set preprod
  run watchlist_state_get preprod
  [[ "$output" == *"ASD-1124=Reopened"* ]]
  [[ "$output" == *"last_email_id=abc123"* ]]
}

@test "material match honors the per-signal controlled vocab" {
  run watchlist_material_match preprod reopened
  [ "$status" -eq 0 ]
  run watchlist_material_match preprod env-down
  [ "$status" -eq 0 ]
  run watchlist_material_match preprod note      # not in preprod's set → routine
  [ "$status" -ne 0 ]
  run watchlist_material_match exec-committee env-down   # not in exec-committee's set
  [ "$status" -ne 0 ]
}
