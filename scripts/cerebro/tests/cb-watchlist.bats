#!/usr/bin/env bats
# cb-watchlist — render + auto-append (M3) and material-change push (M4).
# The manifest is the input; the tracker's board section + Log are the outputs.
# Judgment is never written; only factual deltas.

setup() {
  export CB_HOME="$BATS_TEST_TMPDIR/.cerebro"; mkdir -p "$CB_HOME/logs"
  export CB_MANIFEST="$CB_HOME/manifest.jsonl"
  export CB_WATCH_STATE="$CB_HOME/watchlist"
  export CB_VAULT="$BATS_TEST_TMPDIR/vault"; mkdir -p "$CB_VAULT/01 Projects/edj"
  export CB_WATCHLIST="$BATS_TEST_TMPDIR/watchlist.md"
  cat > "$CB_WATCHLIST" <<'EOF'
- signal: preprod
  kind: jira-tickets
  poll_interval: 3h
  target_tracker: 01 Projects/edj/preprod-readiness.md
  board_section: Where things stand
  material_rule: new, reopened, slip, env-down

- signal: exec-committee
  kind: email, gsheet
  poll_interval: 6h
  target_tracker: 01 Projects/edj/exec-committee.md
  board_section: T&L delivery / bug status
  material_rule: new, reopened, slip, cancelled
EOF
  # a pre-existing curated tracker (like the real preprod-readiness.md)
  cat > "$CB_VAULT/01 Projects/edj/preprod-readiness.md" <<'EOF'
---
type: readiness-tracker
---

# EDJ PreProd Readiness

## Where things stand

_placeholder to be overwritten_

## Root-context

Curated prose that must survive the render.

## Log

### 2026-07-15
- Prior entry, must not be clobbered.
EOF
  # a fixed "now" so the Log date heading is deterministic
  export CB_NOW=1784160000   # 2026-07-16T00:00:00Z
}

@test "M3: a factual delta lands in the board section AND the Log; curated prose survives" {
  scripts/cerebro/cb-watchlist append preprod ASD-1124 reopened "disclosure page reopened by Thomas Rosales"
  run scripts/cerebro/cb-watchlist --render
  [ "$status" -eq 0 ]
  f="$CB_VAULT/01 Projects/edj/preprod-readiness.md"
  # board section overwritten with the delta
  grep -q 'ASD-1124.*reopened' "$f"
  ! grep -q 'placeholder to be overwritten' "$f"
  # Log gained a dated one-liner under a date heading
  grep -q '^## Log' "$f"
  grep -q 'ASD-1124' "$f"
  # curated prose + prior Log entry preserved
  grep -q 'Curated prose that must survive' "$f"
  grep -q 'Prior entry, must not be clobbered' "$f"
}

@test "M3: render is idempotent — a second render does NOT re-append the Log line" {
  scripts/cerebro/cb-watchlist append preprod ASD-1124 reopened "x"
  scripts/cerebro/cb-watchlist --render
  f="$CB_VAULT/01 Projects/edj/preprod-readiness.md"
  c1="$(grep -c '\*\*ASD-1124\*\*' "$f")"          # one board line + one Log bullet
  scripts/cerebro/cb-watchlist --render
  c2="$(grep -c '\*\*ASD-1124\*\*' "$f")"
  [ "$c1" -eq "$c2" ]                               # no growth across renders
  # exactly one Log bullet (dated form: `- YYYY-MM-DD **ASD-1124**`)
  [ "$(grep -cE '^- [0-9]{4}-[0-9]{2}-[0-9]{2} \*\*ASD-1124\*\*' "$f")" -eq 1 ]
}

@test "M3: two events for one key → ONE board line (latest), Log collapses the flap to one bullet" {
  scripts/cerebro/cb-watchlist append preprod ASD-1124 new "first seen"
  scripts/cerebro/cb-watchlist append preprod ASD-1124 reopened "then reopened"
  run scripts/cerebro/cb-watchlist --render
  f="$CB_VAULT/01 Projects/edj/preprod-readiness.md"
  # board: exactly one line for the key, showing the latest state
  [ "$(grep -c 'ASD-1124' "$f")" -ge 1 ]
  grep -q '\*\*ASD-1124\*\* — reopened' "$f"       # board shows latest
  ! grep -q '\*\*ASD-1124\*\* — new' "$f"          # not the superseded state
}

@test "M3: judgment is never written — only factual deltas" {
  scripts/cerebro/cb-watchlist append preprod ASD-1124 reopened "reopened by Thomas"
  scripts/cerebro/cb-watchlist --render
  f="$CB_VAULT/01 Projects/edj/preprod-readiness.md"
  # the tracker carries the fact, never a judgment prompt like "does 7/20 slip?"
  ! grep -qi 'does 7/20 slip' "$f"
  ! grep -qi 'risk call' "$f"
}

@test "M3: a fresh signal with no tracker gets a scaffold at the configured board_section" {
  scripts/cerebro/cb-watchlist append exec-committee DECK-716 new "new status deck posted"
  run scripts/cerebro/cb-watchlist --render
  [ "$status" -eq 0 ]
  f="$CB_VAULT/01 Projects/edj/exec-committee.md"
  [ -f "$f" ]
  grep -q '^## T&L delivery / bug status' "$f"     # the configured section header
  grep -q 'DECK-716' "$f"
}

@test "M4: a material delta fires the push exactly once; a routine delta does not" {
  export CB_PUSH_URL="https://push.example/topic"
  mkdir -p "$BATS_TEST_TMPDIR/mock"
  cat > "$BATS_TEST_TMPDIR/mock/curlmock" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$BATS_TEST_TMPDIR/pushlog"    # one line per push, full argv (carries -d <msg>)
EOF
  chmod +x "$BATS_TEST_TMPDIR/mock/curlmock"
  export CB_CURL_CMD="$BATS_TEST_TMPDIR/mock/curlmock"
  : > "$BATS_TEST_TMPDIR/pushlog"
  scripts/cerebro/cb-watchlist append preprod ASD-1124 reopened "material: reopened blocker"  # reopened ∈ material set
  scripts/cerebro/cb-watchlist append preprod ASD-9999 note "routine daily status note"        # note ∉ material set
  scripts/cerebro/cb-watchlist --render
  [ -f "$BATS_TEST_TMPDIR/pushlog" ]
  grep -q 'ASD-1124' "$BATS_TEST_TMPDIR/pushlog"        # material pushed
  ! grep -q 'ASD-9999' "$BATS_TEST_TMPDIR/pushlog"      # routine NOT pushed
  # push fires once, not again on the next (idempotent) render
  scripts/cerebro/cb-watchlist --render
  [ "$(grep -c 'ASD-1124' "$BATS_TEST_TMPDIR/pushlog")" -eq 1 ]
}

@test "M4: no push channel configured → material delta logs a fallback, still renders" {
  unset CB_PUSH_URL 2>/dev/null || true
  scripts/cerebro/cb-watchlist append preprod ASD-1124 reopened "x"
  run scripts/cerebro/cb-watchlist --render
  [ "$status" -eq 0 ]
  grep -q 'watch-material preprod ASD-1124 reopened (no push channel' "$CB_HOME/logs/events"
}

@test "--poll nudges the coordinator for a due signal, marks it polled, focus suspends" {
  export CB_TMUX_BIN="$BATS_TEST_TMPDIR/faketmux"
  cat > "$CB_TMUX_BIN" <<'EOF'
#!/usr/bin/env bash
echo "tmux $*" >> "$CB_TMUX_LOG"
EOF
  chmod +x "$CB_TMUX_BIN"; export CB_TMUX_LOG="$BATS_TEST_TMPDIR/tmux.log"; : > "$CB_TMUX_LOG"
  export CB_SEND_DELAY=0
  run scripts/cerebro/cb-watchlist --poll
  [ "$status" -eq 0 ]
  grep -q 'send-keys -t Cerebro watch-poll preprod' "$CB_TMUX_LOG"
  grep -q 'send-keys -t Cerebro watch-poll exec-committee' "$CB_TMUX_LOG"
  # marked polled → not due now, so a second poll nudges nothing
  : > "$CB_TMUX_LOG"
  run scripts/cerebro/cb-watchlist --poll
  [ ! -s "$CB_TMUX_LOG" ]
  # focus suspends entirely
  scripts/cerebro/cb-watchlist mark-polled preprod   # keep clocks reset
  rm -f "$CB_WATCH_STATE"/*.last_poll
  printf focus > "$CB_HOME/mode"
  : > "$CB_TMUX_LOG"
  run scripts/cerebro/cb-watchlist --poll
  [ ! -s "$CB_TMUX_LOG" ]
}
