#!/usr/bin/env bats
# cb-send's GHOST-COMPOSER probe (2026-08-03).
#
# The composer paints a previously-recalled input the way a shell paints a
# history entry. capture-pane cannot tell that frame from live typing, so the
# holds-other-text refusal fired against an empty composer — and nothing ever
# clears a ghost, so the refusal was PERMANENT. A finished conductor sat
# unreachable for over an hour on 2026-08-02, with `cb-start --code --adopt`
# refusing in the same state (correctly: the harness really was alive).
#
# The fake tmux here models the distinction properly rather than faking its
# outcome. `buf` is what the pane REALLY holds; `ghost` is a frame painted only
# while `buf` is empty. Typing appends to `buf`, so a ghost gets "replaced" and
# real text gets "appended" as an emergent property — which is precisely the
# question the probe asks.
#
# ⚠️ The separator after `❯` is U+00A0, NOT an ASCII space. That single byte is
# the whole bug: it defeated two attempts at this fix in one hour on 2026-08-02,
# because both were written as line comparisons against `❯ `. It is asserted
# directly in "the separator really is U+00A0" and exercised by every case here
# via the default SEP.

setup() {
  load ../lib/classify.sh
  export CB_HOME="$BATS_TEST_TMPDIR/.cerebro"; mkdir -p "$CB_HOME/tasks"
  export CB_GUARD_CMD=:                      # R1: no real cb-guard (network probe)
  export CB_SEND_DELAY=0 CB_VERIFY_DELAY=0
  export CB_TMUX_LOG="$BATS_TEST_TMPDIR/tmux.log"; : > "$CB_TMUX_LOG"
  export FAKE_STATE="$BATS_TEST_TMPDIR/state"; mkdir -p "$FAKE_STATE"
  export MSG="rebase onto main and re-run the suite"
  export GHOST="! git push --force-with-lease origin ai/plugin-skill-cache"
  export FAKE_TARGET="cb:probe-x"

  export CB_TMUX_BIN="$BATS_TEST_TMPDIR/faketmux"
  cat > "$CB_TMUX_BIN" <<'EOF'
#!/usr/bin/env bash
echo "tmux $*" >> "$CB_TMUX_LOG"
buf_f="$FAKE_STATE/buf"; ghost_f="$FAKE_STATE/ghost"
buf="$(cat "$buf_f" 2>/dev/null || true)"
case "$1" in
  capture-pane)
    content="$buf"
    # the ghost is a painted FRAME: visible only while nothing is really held
    if [ -z "$content" ] && [ -f "$ghost_f" ]; then content="$(cat "$ghost_f")"; fi
    printf '%s\n' "⏺ Cogitated for 22m 2s"
    printf '%s\n' "────────────────────────────────────────────────────"
    # padded to the pane width, as a real capture-pane line is — so any check
    # written against the RAW line (rather than the normalized composer read)
    # fails here the way it failed live
    printf '❯%s%-46s\n' "${SEP:-$(printf '\302\240')}" "$content"
    printf '%s\n' "────────────────────────────────────────────────────"
    printf '%s\n' "  ultron  |  fe/probe-x  |  auto mode on"
    ;;
  send-keys)
    shift
    while [ $# -gt 0 ]; do
      case "$1" in
        -t)     shift ;;
        Enter)  : > "$buf_f"; rm -f "$ghost_f" ;;   # submitted; the frame goes too
        C-u)    : > "$buf_f" ;;
        BSpace) buf="${buf%?}"; printf '%s' "$buf" > "$buf_f" ;;
        *)      buf="$buf$1";  printf '%s' "$buf" > "$buf_f" ;;
      esac
      shift
    done
    ;;
esac
exit 0
EOF
  chmod +x "$CB_TMUX_BIN"
}

ghost()   { printf '%s' "$1" > "$FAKE_STATE/ghost"; }
pending() { printf '%s' "$1" > "$FAKE_STATE/buf"; }
sends()   { grep -c "send-keys" "$CB_TMUX_LOG" || true; }
typed()   { grep -c "send-keys -t $FAKE_TARGET $MSG\$" "$CB_TMUX_LOG" || true; }

# --- the bug ------------------------------------------------------------------
@test "a GHOST line does not block delivery: the probe frees the composer" {
  ghost "$GHOST"
  run scripts/cerebro/cb-send probe-x "$MSG"
  [ "$status" -eq 0 ]
  [[ "$output" == *"GHOST"* ]]
  [ "$(typed)" -eq 1 ]
  grep -q "send-keys -t $FAKE_TARGET Enter" "$CB_TMUX_LOG"
}

@test "the probe restores the composer: one probe char, one BSpace, in order" {
  ghost "$GHOST"
  run scripts/cerebro/cb-send probe-x "$MSG"
  [ "$status" -eq 0 ]
  [ "$(grep -c "send-keys -t $FAKE_TARGET Q\$" "$CB_TMUX_LOG")" -eq 1 ]
  [ "$(grep -c "send-keys -t $FAKE_TARGET BSpace\$" "$CB_TMUX_LOG")" -eq 1 ]
  # the BSpace must come after the probe char, or the composer is left dirty
  [ "$(grep -n "send-keys -t $FAKE_TARGET Q\$" "$CB_TMUX_LOG" | cut -d: -f1)" \
    -lt "$(grep -n "send-keys -t $FAKE_TARGET BSpace\$" "$CB_TMUX_LOG" | cut -d: -f1)" ]
}

# --- the guard it must not weaken ---------------------------------------------
@test "REAL pending text still refuses: the probe APPENDED, so the text is live" {
  pending "fix the prudential replacement question"
  run scripts/cerebro/cb-send probe-x "$MSG"
  [ "$status" -eq 3 ]
  [[ "$output" == *"already holds other text"* ]]
  [ "$(typed)" -eq 0 ]                       # our message never went out
}

@test "a refused probe leaves the real pending text exactly as it was" {
  pending "fix the prudential replacement question"
  run scripts/cerebro/cb-send probe-x "$MSG"
  [ "$status" -eq 3 ]
  [ "$(cat "$FAKE_STATE/buf")" = "fix the prudential replacement question" ]
}

@test "replace-vs-append is the WHOLE test: same starting frame, opposite verdicts" {
  # identical text on screen; the only difference is whether the pane holds it
  ghost "shared text on the screen"
  run scripts/cerebro/cb-send probe-x "$MSG"
  [ "$status" -eq 0 ]

  : > "$CB_TMUX_LOG"; rm -f "$FAKE_STATE/ghost" "$FAKE_STATE/buf"
  pending "shared text on the screen"
  run scripts/cerebro/cb-send probe-x "$MSG"
  [ "$status" -eq 3 ]
}

# --- U+00A0: the byte that caused this ----------------------------------------
@test "the separator really is U+00A0, not an ASCII space" {
  ghost "$GHOST"
  "$CB_TMUX_BIN" capture-pane -p -t "$FAKE_TARGET" | grep '❯' | od -An -c \
    | tr -s ' ' | grep -q '342 235 257 302 240'
}

@test "a U+00A0-separated ghost is detected (an ASCII-space match would miss it)" {
  ghost "$GHOST"
  SEP="$(printf '\302\240')" run scripts/cerebro/cb-send probe-x "$MSG"
  [ "$status" -eq 0 ]
  [ "$(typed)" -eq 1 ]
}

@test "the verdict does not depend on the separator: ASCII space reads the same" {
  ghost "$GHOST"
  SEP=" " run scripts/cerebro/cb-send probe-x "$MSG"
  [ "$status" -eq 0 ]
  [ "$(typed)" -eq 1 ]
}

# --- the one place a probe would do real damage --------------------------------
@test "an interactive MENU refuses without probing — not one keystroke" {
  # a Claude Code option list renders `❯ 1. Yes`, which reads as a composer
  # holding text. It is the agent asking Kyle directly: a stray keystroke at a
  # selection list is an ANSWER, so this arm must never fire the probe.
  export CB_PANE_CMD="printf '%s\n' '⏺ Do you want to make this edit?' '' '❯ 1. Yes' '  2. No, tell Claude what to do differently (esc)' '' 'Enter to select · ↑/↓ to navigate'"
  run scripts/cerebro/cb-send probe-x "$MSG"
  [ "$status" -eq 3 ]
  [[ "$output" == *"interactive option menu"* ]]
  ! grep -q "send-keys" "$CB_TMUX_LOG"
}

# --- fail toward the refusal ---------------------------------------------------
@test "an unreadable pane AFTER the probe is not evidence of freedom → refuse" {
  # first read shows the ghost; the pane then goes unreadable mid-probe
  cat > "$BATS_TEST_TMPDIR/flaky" <<'EOF'
#!/usr/bin/env bash
n="$FAKE_STATE/reads"; c=$(( $(cat "$n" 2>/dev/null || echo 0) + 1 )); echo "$c" > "$n"
if [ "$c" -le 1 ]; then
  printf '────\n❯%s%s\n────\n' "$(printf '\302\240')" "a recalled line"
else
  printf 'the TUI went away\n'
fi
EOF
  chmod +x "$BATS_TEST_TMPDIR/flaky"
  export CB_PANE_CMD="$BATS_TEST_TMPDIR/flaky"
  run scripts/cerebro/cb-send probe-x "$MSG"
  [ "$status" -eq 3 ]
  [ "$(typed)" -eq 0 ]
  grep -q "send-keys -t $FAKE_TARGET BSpace\$" "$CB_TMUX_LOG"   # still restored
}

# --- no path may leave a task permanently unreachable --------------------------
# A guard that can never be satisfied is worse than the strand it prevents. The
# probe makes the guard accurate; this makes a stuck channel say so.
@test "refused TWICE for the same reason → a blocked decision on the board" {
  td="$CB_HOME/tasks/probe-x"; mkdir -p "$td"
  pending "someone else is mid-sentence"

  run scripts/cerebro/cb-send probe-x "$MSG"
  [ "$status" -eq 3 ]
  [[ "$output" != *"SURFACED"* ]]            # one refusal is just a refusal
  run open_decisions "$td"; [ -z "$output" ]

  run scripts/cerebro/cb-send probe-x "$MSG"
  [ "$status" -eq 3 ]
  [[ "$output" == *"SURFACED"* ]]
  run open_decisions "$td"
  [ -n "$output" ]
  [[ "$output" == *"blocked"* ]]
  [[ "$output" == *"cannot reach probe-x"* ]]
}

@test "two DIFFERENT refusal reasons are not a recurrence" {
  td="$CB_HOME/tasks/probe-x"; mkdir -p "$td"
  export CB_COMPOSER_WAIT_SECS=1 CB_COMPOSER_POLL_SECS=0
  export CB_PANE_CMD="printf 'no composer here\n'"
  run scripts/cerebro/cb-send probe-x "$MSG"
  [ "$status" -eq 3 ]; [[ "$output" == *"no composer"* ]]

  unset CB_PANE_CMD
  pending "someone else is mid-sentence"
  run scripts/cerebro/cb-send probe-x "$MSG"
  [ "$status" -eq 3 ]
  [[ "$output" != *"SURFACED"* ]]
  run open_decisions "$td"; [ -z "$output" ]
}

@test "a delivery clears the refusal counter, so the next refusal starts over" {
  td="$CB_HOME/tasks/probe-x"; mkdir -p "$td"
  printf 'pending-text 1\n' > "$td/send-refusals"
  ghost "$GHOST"
  run scripts/cerebro/cb-send probe-x "$MSG"
  [ "$status" -eq 0 ]
  [ ! -f "$td/send-refusals" ]
}

@test "the surfaced decision resolves once delivery works again" {
  td="$CB_HOME/tasks/probe-x"; mkdir -p "$td"
  pending "someone else is mid-sentence"
  run scripts/cerebro/cb-send probe-x "$MSG"
  run scripts/cerebro/cb-send probe-x "$MSG"
  run open_decisions "$td"; [ -n "$output" ]

  rm -f "$FAKE_STATE/buf"; ghost "$GHOST"
  run scripts/cerebro/cb-send probe-x "$MSG"
  [ "$status" -eq 0 ]
  run open_decisions "$td"; [ -z "$output" ]   # R12 sweep closed it
}
