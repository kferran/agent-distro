setup() {
  load ../lib/classify.sh   # R12: decision-log helpers for the resolve-on-send tests
  export CB_TMUX_BIN="$BATS_TEST_TMPDIR/faketmux"
  cat > "$CB_TMUX_BIN" <<'EOF'
#!/usr/bin/env bash
echo "tmux $*" >> "$CB_TMUX_LOG"
EOF
  chmod +x "$CB_TMUX_BIN"; export CB_TMUX_LOG="$BATS_TEST_TMPDIR/log"
  export CB_GUARD_CMD=:   # R1: don't invoke the real cb-guard (network MCP probe) from tests
  # cb-send refuses to type at a pane it cannot READ (2026-07-30 "never type
  # blind" — five briefs went into booting harnesses that reported success). The
  # fake tmux above prints nothing for capture-pane, which reads as "no composer",
  # so from that change onward every send in this file waited the full 45s and
  # then refused with exit 3. Five tests here went red on main and stayed red.
  # They are about target resolution, the Enter split and decision resolution —
  # not the composer guard — so give them a readable empty composer (a real
  # capture, NBSP and all) and let them test what they were written to test.
  export CB_PANE_CMD="cat '$BATS_TEST_DIRNAME/fixtures/panes/composer-empty.txt'"
  export CB_SEND_DELAY=0 CB_VERIFY_DELAY=0
}

# --- R1: cb-guard rides every supervision command (who-watches-the-watcher) ---
guard_shim() { # arms CB_GUARD_CMD to record that the guard ran
  export CB_GUARD_CMD="$BATS_TEST_TMPDIR/guard-rec"
  printf '#!/usr/bin/env bash\ntouch %q\n' "$BATS_TEST_TMPDIR/guard-ran" > "$CB_GUARD_CMD"
  chmod +x "$CB_GUARD_CMD"
}
@test "cb-send runs cb-guard first" {
  export CB_HOME="$BATS_TEST_TMPDIR/.cerebro"; mkdir -p "$CB_HOME/tasks"
  guard_shim
  run scripts/cerebro/cb-send probe-x "yes"
  [ -f "$BATS_TEST_TMPDIR/guard-ran" ]
}
@test "cb-peek runs cb-guard first" {
  export CB_HOME="$BATS_TEST_TMPDIR/.cerebro"; mkdir -p "$CB_HOME/tasks"
  guard_shim
  run scripts/cerebro/cb-peek probe-x
  [ -f "$BATS_TEST_TMPDIR/guard-ran" ]
}
@test "cb-send issues send-keys to cb:<slug>" {
  run scripts/cerebro/cb-send probe-x "yes"
  [[ "$(cat "$CB_TMUX_LOG")" == *"send-keys -t cb:probe-x"* ]]
}

# --- code tasks live in per-slug SESSIONS: target resolves from task meta ---
@test "cb-send targets the per-slug session for a kind=code task" {
  export CB_HOME="$BATS_TEST_TMPDIR/.cerebro"; mkdir -p "$CB_HOME/tasks/fix-x"
  printf 'kind=code\nsession=fix-x\n' > "$CB_HOME/tasks/fix-x/meta"
  # A code task also faces the dead-harness refusal (2026-07-30): a session that
  # is positively `gone` is a bare shell, where a send would EXECUTE rather than
  # type. Only code tasks hit it, so only this test needs the session present.
  export CB_SESSION_LIST_CMD="printf 'fix-x\n'"
  run scripts/cerebro/cb-send fix-x "continue"
  [[ "$(cat "$CB_TMUX_LOG")" == *"send-keys -t fix-x: continue"* ]]
}

@test "cb-peek targets the per-slug session for a kind=code task" {
  export CB_HOME="$BATS_TEST_TMPDIR/.cerebro"; mkdir -p "$CB_HOME/tasks/fix-x"
  printf 'kind=code\nsession=fix-x\n' > "$CB_HOME/tasks/fix-x/meta"
  run scripts/cerebro/cb-peek fix-x
  [[ "$(cat "$CB_TMUX_LOG")" == *"capture-pane -p -t fix-x:"* ]]
}

@test "cb-send submits Enter as a separate key event after the text" {
  export CB_SEND_DELAY=0
  run scripts/cerebro/cb-send probe-x "status check"
  [ "$status" -eq 0 ]
  [ "$(grep -c "send-keys -t cb:probe-x" "$CB_TMUX_LOG")" -eq 2 ]
  [[ "$(tail -1 "$CB_TMUX_LOG")" == *"send-keys -t cb:probe-x Enter"* ]]
  [[ "$(head -1 "$CB_TMUX_LOG")" != *Enter ]]
}

# --- R12 (step 12): cb-send closes the slug's open decision (coordinator-marked) ---
@test "R12: cb-send resolves the slug's open decision" {
  export CB_HOME="$BATS_TEST_TMPDIR/.cerebro"; td="$CB_HOME/tasks/gate-x"; mkdir -p "$td"
  k=$(_decision_key needs-input "gate"); _decision_open "$td" "$k" needs-input "gate"
  run scripts/cerebro/cb-send gate-x "my answer"
  [ "$status" -eq 0 ]
  run open_decisions "$td"; [ -z "$output" ]        # closed by the human answer
}
@test "R12: cb-send with no open decision is a harmless no-op (still sends)" {
  export CB_HOME="$BATS_TEST_TMPDIR/.cerebro"; mkdir -p "$CB_HOME/tasks/quiet"
  run scripts/cerebro/cb-send quiet "hello"
  [ "$status" -eq 0 ]
  grep -q 'send-keys -t cb:quiet' "$CB_TMUX_LOG"
}

# --- (e) scope-add #2: long payloads auto-route via a file pointer ---
# A payload over CB_SEND_MAX_INLINE trips Claude Code's bracketed-paste collapse
# (lands typed-but-unsubmitted); write it to a file and send a short pointer.
#
# The readable empty composer these need is armed once in setup() — cb-send will
# not type at a pane it cannot read.
@test "(e) a short payload sends inline — no file written" {
  export CB_HOME="$BATS_TEST_TMPDIR/.cerebro"; mkdir -p "$CB_HOME/tasks/short-x"
  run scripts/cerebro/cb-send short-x "continue"
  [ "$status" -eq 0 ]
  [[ "$(cat "$CB_TMUX_LOG")" == *"send-keys -t cb:short-x continue"* ]]
  [ -z "$(find "$CB_HOME/tasks/short-x" -name 'send-msg.*' 2>/dev/null)" ]
}

@test "(e) a long payload is written to a file and a short 'Read <file>' pointer is sent" {
  export CB_HOME="$BATS_TEST_TMPDIR/.cerebro"; mkdir -p "$CB_HOME/tasks/long-x"
  long="$(printf 'x%.0s' {1..400})"     # 400 chars, well over the 200 default
  run scripts/cerebro/cb-send long-x "$long"
  [ "$status" -eq 0 ]
  # the raw 400-char blob is NOT in the send-keys stream (no paste collapse)
  ! grep -q "$long" "$CB_TMUX_LOG"
  # a pointer was sent instead
  grep -q 'send-keys -t cb:long-x Read ' "$CB_TMUX_LOG"
  # and the full payload landed in a file
  f="$(find "$CB_HOME/tasks/long-x" -name 'send-msg.*')"
  [ -n "$f" ]
  [ "$(cat "$f")" = "$long" ]
}

@test "(e) the inline threshold is tunable via CB_SEND_MAX_INLINE" {
  export CB_HOME="$BATS_TEST_TMPDIR/.cerebro"; mkdir -p "$CB_HOME/tasks/tune-x"
  CB_SEND_MAX_INLINE=5 run scripts/cerebro/cb-send tune-x "abcdefghij"   # 10 > 5
  f="$(find "$CB_HOME/tasks/tune-x" -name 'send-msg.*')"
  [ -n "$f" ]
}
