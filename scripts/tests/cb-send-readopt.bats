#!/usr/bin/env bats
# cb-send against a session that has OUTLIVED its agent (2026-07-30).
#
# cb-start no longer `exec`s the harness, so a conductor's tmux session survives
# its agent's exit as a bare interactive shell. That buys the thing this change is
# for — the session name and worktree persist, so answering a cb-ask is a re-adopt
# rather than a manual rebuild — but it also creates a pane that EXECUTES anything
# typed at it. These tests pin both halves:
#
#   1. the blind-send escape hatch is gated on harness liveness, so cb-remediate
#      keeps working on wedges (live harness, no composer) and can never type into
#      a dead shell (no harness, no composer);
#   2. cb-send re-adopts a dead conductor before delivering, and that re-adopt
#      composes with the exit-3 refusal instead of replacing it.

setup() {
  export CB_HOME="$BATS_TEST_TMPDIR/.cerebro"; mkdir -p "$CB_HOME/tasks"
  export CB_GUARD_CMD=:                       # R1: no real cb-guard (network probe)
  export CB_SEND_DELAY=0 CB_VERIFY_DELAY=0
  export CB_COMPOSER_WAIT_SECS=0 CB_COMPOSER_POLL_SECS=0
  export CB_TMUX_LOG="$BATS_TEST_TMPDIR/tmux.log"; : > "$CB_TMUX_LOG"
  export STARTLOG="$BATS_TEST_TMPDIR/start.log"
  export FIXTURES="$BATS_TEST_DIRNAME/fixtures/panes"

  # fake tmux: only records. Any send-keys here is a test FAILURE in most cases
  # below, which is the whole point — we assert on the absence of keystrokes.
  export CB_TMUX_BIN="$BATS_TEST_TMPDIR/faketmux"
  printf '#!/usr/bin/env bash\necho "tmux $*" >> "$CB_TMUX_LOG"\nexit 0\n' > "$CB_TMUX_BIN"
  chmod +x "$CB_TMUX_BIN"

  # a re-adopt stand-in; records its args instead of launching a real conductor
  export CB_START_CMD="$BATS_TEST_TMPDIR/fakestart"
  printf '#!/usr/bin/env bash\necho "$*" >> "$STARTLOG"\nexit 0\n' > "$CB_START_CMD"
  chmod +x "$CB_START_CMD"

  # a bare shell pane: real chrome, no `❯` composer anywhere
  export BASHPANE="$BATS_TEST_TMPDIR/bashpane.txt"
  printf 'kyle@np-kf1-cus:~/code/worktrees/fix-x$ \n' > "$BASHPANE"
  export CB_PANE_CMD="cat $BASHPANE"
}

sends() { grep -c "send-keys" "$CB_TMUX_LOG" 2>/dev/null || true; }

# a code task whose worktree exists, parked at `paused:` the way cb-ask leaves it
code_task() {
  local slug="$1" state="${2:-paused: awaiting answer — which fix?}"
  local td="$CB_HOME/tasks/$slug" wt="$BATS_TEST_TMPDIR/wt/$slug"
  mkdir -p "$td" "$wt"
  printf 'kind=code\nworktree=%s\njira=EJA-1234\nsession=%s\ntarget=ultron\n' "$wt" "$slug" > "$td/meta"
  printf '%s\n' "$state" > "$td/status"
}

# Liveness is FILE-BACKED, not baked into the env: cb-send probes it more than
# once per run (before the re-adopt and again after it), and a re-adopt is
# supposed to CHANGE the answer. A fake cb-start can rewrite this table the way a
# real one brings a harness up.
PS_DEAD='1 0 systemd
1000 1 bash'
PS_LIVE='1 0 systemd
1000 1 claude'

harness_table() {   # harness_table <slug> <dead|live>
  export PSFILE="$BATS_TEST_TMPDIR/ps.table"
  case "$2" in dead) printf '%s\n' "$PS_DEAD" ;; live) printf '%s\n' "$PS_LIVE" ;; esac > "$PSFILE"
  export CB_SESSION_LIST_CMD="printf '$1\n'"            # the tmux NAME is present either way
  export CB_SESSION_PID_CMD="printf '$1 1000\n'"
  export CB_PS_CMD="cat $PSFILE"
}
dead_harness() { harness_table "$1" dead; }
live_harness() { harness_table "$1" live; }

# --- 1. the blind-send escape hatch is liveness-gated ------------------------
# cb-remediate sets CB_SEND_ALLOW_BLIND=1 because a spend-wedge screen has no
# composer and waiting for one can never succeed. That reasoning holds only while
# an agent is actually in there. On a dead shell the same flag would type a resume
# line at bash — and a brief is full of backticks and $(…).

@test "blind send REFUSES when the harness is gone (the pane is a shell, not a wedge)" {
  code_task fix-x 'running'; dead_harness fix-x
  CB_SEND_ALLOW_BLIND=1 run scripts/cerebro/cb-send fix-x 'continue'
  [ "$status" -eq 3 ]
  [[ "$output" == *"no live harness"* ]]
  [[ "$output" == *"EXECUTED"* ]]
  [ "$(sends)" -eq 0 ]                                  # nothing typed at the shell
}

# --- THE GHOST COMPOSER — the regression this whole gate exists for ----------
# Found by the end-to-end demo on 2026-07-30, not by any unit test: a payload
# containing `touch <path>` was typed at a dead pane and the file WAS CREATED.
#
# An exiting harness leaves its last TUI frame on screen. capture-pane still
# renders it, `❯` and all, so the composer readback sees a textbook empty
# composer on a pane whose only living process is bash. Every text-based guard
# says "go". Only the process probe knows better — which is why it has to outrank
# the pane, and why this test uses a REAL composer fixture with a DEAD harness.
@test "a dead pane still SHOWING a composer is refused anyway (text lies, the process probe does not)" {
  code_task fix-x 'running'; dead_harness fix-x
  export CB_PANE_CMD="cat $FIXTURES/composer-empty.txt"   # a perfectly valid-looking composer
  run scripts/cerebro/cb-send fix-x 'answer: `touch /tmp/pwned`'
  [ "$status" -eq 3 ]
  [[ "$output" == *"leftover frame"* ]]
  [ "$(sends)" -eq 0 ]                                  # the payload never reached the shell
}

@test "blind send is STILL allowed on a wedged but LIVE harness (cb-remediate keeps working)" {
  code_task fix-x; live_harness fix-x
  CB_SEND_ALLOW_BLIND=1 run scripts/cerebro/cb-send fix-x 'continue'
  [ "$status" -eq 0 ]
  [[ "$output" == *"delivery unverified"* ]]            # blind by construction
  grep -q "send-keys -t fix-x: continue" "$CB_TMUX_LOG"
}

@test "blind send is allowed when liveness is UNAVAILABLE (cannot tell → never a refusal)" {
  code_task fix-x
  export CB_SESSION_LIST_CMD="exit 127"
  CB_SEND_ALLOW_BLIND=1 run scripts/cerebro/cb-send fix-x 'continue'
  [ "$status" -eq 0 ]
  [ "$(sends)" -gt 0 ]
}

# --- 2. a backtick payload never reaches the shell ---------------------------
# The DoD case. Both routes to that pane must refuse, and neither may type.

@test "a backtick-laden payload at a bash pane refuses, and is never executed (default path)" {
  code_task fix-x 'running'                             # no paused/blocked → no re-adopt
  dead_harness fix-x
  run scripts/cerebro/cb-send fix-x 'try `rm -rf /tmp/pwned` and $(whoami) now'
  [ "$status" -eq 3 ]
  [[ "$output" == *"no live harness"* ]]
  [ "$(sends)" -eq 0 ]
}

@test "a backtick-laden payload at a bash pane refuses on the blind path too" {
  code_task fix-x 'running'
  dead_harness fix-x
  CB_SEND_ALLOW_BLIND=1 run scripts/cerebro/cb-send fix-x 'try `rm -rf /tmp/pwned` now'
  [ "$status" -eq 3 ]
  [ "$(sends)" -eq 0 ]
}

# --- 3. auto-re-adopt before delivering --------------------------------------

@test "a dead conductor parked at paused: is re-adopted before delivery" {
  code_task fix-x; dead_harness fix-x
  run scripts/cerebro/cb-send fix-x 'go with option b'
  [[ "$output" == *"re-adopting before delivery"* ]]
  grep -q -- "--code --adopt fix-x --target ultron" "$STARTLOG"
  grep -q -- "--jira EJA-1234" "$STARTLOG"
  grep -q -- "--worktree $BATS_TEST_TMPDIR/wt/fix-x" "$STARTLOG"
}

@test "the re-adopt does NOT weaken the refusal: a harness that never came up still exits 3, nothing typed" {
  code_task fix-x; dead_harness fix-x
  run scripts/cerebro/cb-send fix-x 'go with option b'
  [[ "$output" == *"re-adopting before delivery"* ]]    # it tried...
  [ "$status" -eq 3 ]                                   # ...and the refusal still stands
  [[ "$output" == *"no live harness"* ]]
  [ "$(sends)" -eq 0 ]
}

@test "re-adopt then deliver: a harness that comes up IS delivered to (the whole point)" {
  code_task fix-x; dead_harness fix-x
  # a faithful fake cb-start: it brings a harness up (ps table flips to claude)
  # AND the pane starts rendering a composer — both, because either alone is a
  # state the real world does not produce.
  cat > "$CB_START_CMD" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$STARTLOG"
printf '%s\n' '$PS_LIVE' > "$PSFILE"
cp "$FIXTURES/composer-empty.txt" "$BASHPANE"
exit 0
EOF
  chmod +x "$CB_START_CMD"
  run scripts/cerebro/cb-send fix-x 'go with option b'
  [ "$status" -eq 0 ]
  [ -s "$STARTLOG" ]                                    # it really did re-adopt
  grep -q "send-keys -t fix-x: go with option b" "$CB_TMUX_LOG"
}

@test "a LIVE conductor is never re-adopted (no relaunch over a working agent)" {
  code_task fix-x; live_harness fix-x
  export CB_PANE_CMD="cat $FIXTURES/composer-empty.txt"
  run scripts/cerebro/cb-send fix-x 'go with option b'
  [ "$status" -eq 0 ]
  [ ! -s "$STARTLOG" ]
}

@test "a dead conductor NOT waiting on a human is not resurrected by a stray message" {
  code_task fix-x 'running'; dead_harness fix-x
  run scripts/cerebro/cb-send fix-x 'fyi'
  [ ! -s "$STARTLOG" ]
}

@test "a task carrying a terminal signal stays reaped (summary.md → no re-adopt)" {
  code_task fix-x; dead_harness fix-x
  touch "$CB_HOME/tasks/fix-x/summary.md"
  run scripts/cerebro/cb-send fix-x 'go with option b'
  [ ! -s "$STARTLOG" ]
}

@test "a MERGED PR stays reaped too" {
  code_task fix-x; dead_harness fix-x
  printf 'MERGED' > "$CB_HOME/tasks/fix-x/pr.state"
  run scripts/cerebro/cb-send fix-x 'go with option b'
  [ ! -s "$STARTLOG" ]
}

@test "no target= in the meta → no re-adopt attempt (cb-start --adopt requires one)" {
  code_task fix-x; dead_harness fix-x
  local td="$CB_HOME/tasks/fix-x"
  grep -v '^target=' "$td/meta" > "$td/meta.tmp" && mv "$td/meta.tmp" "$td/meta"
  run scripts/cerebro/cb-send fix-x 'go with option b'
  [ ! -s "$STARTLOG" ]
  [ "$status" -eq 3 ]                                   # falls through to the normal refusal
  [ "$(sends)" -eq 0 ]
}

@test "a research task is never re-adopted (adopt is a code-path verb)" {
  local td="$CB_HOME/tasks/probe-x"; mkdir -p "$td"
  printf 'kind=research\n' > "$td/meta"
  printf 'paused: awaiting answer\n' > "$td/status"
  export CB_WINDOW_LIST_CMD="printf ''"                 # window gone
  run scripts/cerebro/cb-send probe-x 'go with option b'
  [ ! -s "$STARTLOG" ]
}

@test "a failed re-adopt is not fatal — it degrades to a refusal, never to a blind send" {
  code_task fix-x; dead_harness fix-x
  printf '#!/usr/bin/env bash\nexit 1\n' > "$CB_START_CMD"; chmod +x "$CB_START_CMD"
  run scripts/cerebro/cb-send fix-x 'go with option b'
  [ "$status" -eq 3 ]
  [[ "$output" == *"re-adopt of fix-x failed"* ]]
  [ "$(sends)" -eq 0 ]
}

# --- 2a fallout: the re-adopt must not hand its own stdin to cb-start ----------
# cb-start now REFUSES when bytes are waiting on stdin (a piped brief used to be
# silently eaten). cb-send shells out to cb-start for the re-adopt, so anything
# waiting on cb-send's stdin would reach that child and abort a recovery that has
# nothing to do with briefs. cb-send must hand the child a clean stdin.
@test "2a: the re-adopt child gets no inherited stdin payload (recovery survives a piped caller)" {
  code_task fix-x; dead_harness fix-x
  # record what the child SEES on stdin, the same way cb-start decides to refuse
  printf '#!/usr/bin/env bash\nif [ ! -t 0 ] && read -t 0 2>/dev/null && IFS= read -r -d "" -n 1 -t 0.2 b 2>/dev/null && [ -n "$b" ]; then echo BYTES > "$STARTLOG.stdin"; else echo none > "$STARTLOG.stdin"; fi\necho "$*" >> "$STARTLOG"\nexit 0\n' > "$CB_START_CMD"
  chmod +x "$CB_START_CMD"
  run bash -c 'printf "a stray payload on cb-send stdin\n" | scripts/cerebro/cb-send fix-x "go with option b"'
  grep -q -- "--code --adopt fix-x" "$STARTLOG"       # the re-adopt still happened
  [ "$(cat "$STARTLOG.stdin")" = none ]               # and the child saw a clean stdin
}
