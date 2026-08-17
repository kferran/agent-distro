#!/usr/bin/env bats
# lib/coordinator.sh (R17): tri-state pane guard for the SHARED coordinator tmux
# session. Deliver ONLY into an affirmatively-empty Claude composer; defer on
# busy / unknown (a dead login shell would EXECUTE the escalation text).
#
# Every pane fixture here is a REAL `tmux capture-pane` taken 2026-08-02 on
# np-kf1-cus against Claude Code v2.1.220 — not hand-written chrome. That is
# deliberate. The version this file replaces asserted against `? for shortcuts`
# and `esc to interrupt`, strings that exist in zero lines of scrollback on any
# live pane, so the suite stayed green while cb_coord_send returned 1 on every call
# and DEFER-ALARMs piled up continuously from 2026-07-15. A synthetic fixture
# cannot catch that; a captured one cannot miss it.
#
#   coord-busy         Cerebro:0.0 mid-turn, ticking `✢ Gallivanting… (5m 9s · …)`,
#                      with an earlier `❯ Push` human turn above the composer
#   coord-idle-empty   cb:2.0 finished — `✻ Crunched for 3m 0s`, composer `❯`+U+00A0
#   coord-typed        cerebro-remaining-phases:0.0 holding Kyle's real, unsubmitted
#                      `❯ arm it` — the half-typed line the guard exists to refuse
#   coord-shell        cb:0.0, a bash pane: blank capture, no composer
#   coord-login-shell  a shell at a prompt — the R17 command-execution hazard

setup() {
  load ../lib/coordinator.sh
  export CB_SESSION=Cerebro
  export CB_TMUX_LOG="$BATS_TEST_TMPDIR/tmux.log"
  export CB_TMUX_BIN="$BATS_TEST_TMPDIR/faketmux"
  printf '#!/usr/bin/env bash\necho "tmux $*" >> "$CB_TMUX_LOG"\n' > "$CB_TMUX_BIN"
  chmod +x "$CB_TMUX_BIN"
  export CB_SEND_DELAY=0
  FIX="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)/fixtures/panes"
}

# point the pane read at a captured fixture
pane() { export CB_COORD_PANE_CMD="cat '$FIX/$1.txt'"; }

# --- the composer read: the READY test, replacing the dead footer regex ---
@test "composer: an idle pane's composer is EMPTY (the ❯ + U+00A0 case)" {
  pane coord-idle-empty
  run cb_coord_composer; [ "$status" -eq 0 ]; [ "$output" = "" ]
}
@test "composer: a half-typed pane reports its contents" {
  pane coord-typed
  run cb_coord_composer; [ "$status" -eq 0 ]; [ "$output" = "arm it" ]
}
@test "composer: a pane with no ❯ box is UNREADABLE, not empty" {
  pane coord-login-shell
  run cb_coord_composer; [ "$status" -ne 0 ]
}
@test "composer: reads the pane text passed as an argument (one capture, two questions)" {
  run cb_coord_composer "$(cat "$FIX/coord-typed.txt")"
  [ "$status" -eq 0 ]; [ "$output" = "arm it" ]
}

# --- tri-state, against the four real captures ---
@test "pane state: a real idle pane with an empty composer → empty" {
  pane coord-idle-empty
  run cb_coord_pane_state; [ "$output" = "empty" ]
}
@test "pane state: a real working pane (live ticking timer) → busy" {
  pane coord-busy
  run cb_coord_pane_state; [ "$output" = "busy" ]
}
@test "pane state: Kyle's real half-typed line → unknown (defer, do not corrupt it)" {
  pane coord-typed
  run cb_coord_pane_state; [ "$output" = "unknown" ]
}
@test "pane state: a bash pane (no composer at all) → unknown" {
  pane coord-shell
  run cb_coord_pane_state; [ "$output" = "unknown" ]
}
@test "pane state: a dead login shell at a prompt → unknown" {
  pane coord-login-shell
  run cb_coord_pane_state; [ "$output" = "unknown" ]
}
@test "pane state: unreadable/empty capture → unknown" {
  export CB_COORD_PANE_CMD="printf ''"
  run cb_coord_pane_state; [ "$output" = "unknown" ]
}
# The finished-turn line is what a naive "spinner glyph + duration" pattern gets
# wrong: `✻ Crunched for 3m 0s` carries both and is DONE. The ellipsis plus the
# parenthetical timer is what separates working from finished.
@test "pane state: a finished turn (glyph + duration, no ellipsis) does NOT read busy" {
  grep -qE 'for [0-9]+m' "$FIX/coord-idle-empty.txt"   # the duration IS on screen …
  pane coord-idle-empty
  run cb_coord_pane_state; [ "$output" = "empty" ]     # … and it still reads idle
}
# Over-broadening BUSY is the same bug in a different hat: always-defer. The
# status footer truncates to `← for agen…`, so a bare trailing `…` would match
# every pane on the box.
@test "pane state: the truncated footer ellipsis does not read as busy" {
  export CB_COORD_PANE_CMD="printf '%s\n' '  ⏵⏵ auto mode on (shift+tab to cycle) · ← for agen…' '─────' '❯ ' '─────'"
  run cb_coord_pane_state; [ "$output" = "empty" ]
}

# --- the BARE SPINNER: a turn's first seconds, before the timer appears --------
# The highest-consequence miss available, and the one the first re-seed had. The
# elapsed-time counter shows up a few seconds INTO a turn; until then the spinner
# renders with no parenthetical, so a timer-only pattern reads a just-started pane
# as idle and the injection lands mid-turn. Found twice independently: cb-guard's
# canary on Cerebro:0.0 (~1/45 samples), and a full instrumented turn that read
# `empty` for its first 3 seconds. THIS is the capture the canary caught.
@test "pane state: bare spinner with no timer → busy (canary capture, verbatim)" {
  export CB_COORD_PANE_CMD="printf '%s\n' '✻ Considering…' '  ⎿  ◻ Explore context: tmux targeting/keystroke code paths + prior Herdr assessment' '     ◻ Disambiguate what \"the tmux key id issue\" is' '      … +1 pending' '─────' '❯ ' '─────' '  .  |  main  |  [░░░░░░░░░░] 54%  |  Opus 5' '  ⏵⏵ auto mode on · 5 shells · ← for agents'"
  run cb_coord_pane_state; [ "$output" = "busy" ]
}
@test "pane state: bare spinner from a live instrumented turn → busy" {
  export CB_COORD_PANE_CMD="printf '%s\n' '✢ Frolicking…' '─────' '❯ ' '─────'"
  run cb_coord_pane_state; [ "$output" = "busy" ]
}
@test "pane state: tool-activity lines (no glyph, no timer) → busy" {
  export CB_COORD_PANE_CMD="printf '%s\n' '  Running 2 shell commands…' '─────' '❯ ' '─────'"
  run cb_coord_pane_state; [ "$output" = "busy" ]
  export CB_COORD_PANE_CMD="printf '%s\n' '◐ Reading 1 file, running 9 shell commands…' '─────' '❯ ' '─────'"
  run cb_coord_pane_state; [ "$output" = "busy" ]
}
# The grammatical rule, which is the part that survives the next vocabulary
# rotation: present participle + ellipsis = working; past tense + bare duration =
# done. Matching the completion line would make every finished pane read busy
# forever — the always-defer bug, restored.
@test "pane state: past-tense completion lines are NOT busy" {
  for done_line in '✻ Brewed for 6m 47s' '✻ Crunched for 11m 13s' '✻ Cogitated for 3s'; do
    export CB_COORD_PANE_CMD="printf '%s\n' '$done_line' '─────' '❯ ' '─────'"
    run cb_coord_pane_state
    [ "$output" = "empty" ] || { echo "regressed on: $done_line → $output"; false; }
  done
}

# --- the PERSISTED TRANSCRIPT BULLET (regression, 2026-08-07) ------------------
# A spinner line vanishes when the turn ends. A `●` line does NOT — it is the
# TUI's transcript bullet and stays on screen for the rest of the session. While
# the glyph class was `[^[:alnum:][:space:]]` (any non-alphanumeric) it accepted
# `●`, so ONE bulleted line opening with a capitalised gerund pinned the pane to
# `busy` permanently and every escalation to it deferred forever.
#
# This is the always-defer bug that the footer-ellipsis test above guards the
# other approach to, and it cost 26 hours: eja-3488-fourth-bounce, a Ph1-TL-W1
# BLOCKER, sat at spec/awaiting-approval for 93,623s with `escalation NOT
# delivered`, alongside four other agents.
#
# The third case is the nastiest and is why this is not a one-glyph story:
# assistant PROSE is bulleted too, so any reply that happens to open with a
# gerund armed the bug from that moment on.
@test "pane state: persisted \`●\` transcript lines are NOT busy" {
  for stale in \
    '● Advising using Opus 5' \
    '● Reading 1 file, running 1 shell command…' \
    '● Starting with the regex fix and reading the pane.' \
    '⎿  Successfully loaded skill'
  do
    export CB_COORD_PANE_CMD="printf '%s\n' '$stale' '─────' '❯ ' '─────'"
    run cb_coord_pane_state
    [ "$output" = "empty" ] || { echo "stale transcript read as $output: $stale"; false; }
  done
}
# The other half of the same change: narrowing the class must not cost the live
# forms. `✻ Waiting for …` is rung 4's entire reason to exist — a spinner line
# whose activity is a complete sentence, so it never ends in `…`.
@test "pane state: live spinner forms still read busy after the \`●\` exclusion" {
  # `✻ Waiting for 1 background agent to finish` was in this list and has been REMOVED
  # 2026-08-15. It is not a spinner — it is a STATUS LINE that stays on screen after the
  # agent finishes, so at the regex level it made any pane that once waited on a subagent
  # read busy forever, and every escalation to it defer forever. Caught by cb-guard's own
  # canary on `deterministic-report-landing:0.0` at 00:37, on a pane whose agent had died
  # on a 529 two and a half hours earlier — the false busy is what hid the death.
  # Genuine background-agent activity is covered by RUNG 5 (transcript advance), which is
  # stronger evidence than any frame-level pattern and is what the canary itself used.
  # ⚠️ This IS a narrowing of BUSY, against the header's polarity rule, and it leans on
  # RUNG 5 being enabled (CB_COORD_ADVANCE_SECS, default 1.2). Revert = drop the
  # `grep -vE 'waiting for N background agent'` filter in cb_coord_pane_state.
  for live in \
    '✢ Frolicking…' \
    '· Befuddling… (1m 8s · ↓ 4.3k tokens)'
  do
    export CB_COORD_PANE_CMD="printf '%s\n' '$live' '─────' '❯ ' '─────'"
    run cb_coord_pane_state
    [ "$output" = "busy" ] || { echo "live spinner read as $output: $live"; false; }
  done
}

@test "pane state: the PERSISTING background-agent line does not pin a pane busy" {
  # The always-defer bug, pinned. A pane showing only this line plus idle chrome must be
  # sendable — otherwise a conductor that once spawned a subagent can never be escalated
  # to again, which is how a dead 529'd agent went unnoticed for 2h31m on 2026-08-15.
  export CB_COORD_PANE_CMD="printf '%s\n' '✻ Waiting for 1 background agent to finish' '─────' '❯ ' '─────'"
  run cb_coord_pane_state
  [ "$output" != "busy" ] || { echo "persisting status line still pins the pane busy"; false; }
}

@test "pane state: a real spinner ALONGSIDE the persisting line still reads busy" {
  # The filter drops one line, not the frame — genuine work in the same tail still wins.
  export CB_COORD_PANE_CMD="printf '%s\n' '✻ Waiting for 1 background agent to finish' '✢ Frolicking…' '─────' '❯ ' '─────'"
  run cb_coord_pane_state
  [ "$output" = "busy" ]
}

# --- delivery ---
@test "cb_coord_send into an empty composer: types once (literal, sentinel-prefixed) THEN a separate Enter" {
  pane coord-idle-empty
  export CB_INJECT_MARK='@@'   # visible test marker (default is raw 0x1f)
  run cb_coord_send "cb-watch: fix-x needs-input (build)"
  [ "$status" -eq 0 ]
  grep -qx 'tmux send-keys -t Cerebro -l @@cb-watch: fix-x needs-input (build)' "$CB_TMUX_LOG"  # -l + sentinel
  grep -qx 'tmux send-keys -t Cerebro Enter' "$CB_TMUX_LOG"
  # typed exactly once (no retype that would concatenate two payloads)
  [ "$(grep -c 'cb-watch: fix-x' "$CB_TMUX_LOG")" -eq 1 ]
}
@test "R19: the injection carries the sentinel marker (0x1f) at the start of the text" {
  pane coord-idle-empty   # default marker = raw 0x1f
  run cb_coord_send "hello coordinator"
  [ "$status" -eq 0 ]
  # the literal-send line's text begins with the 0x1f byte then the message
  run grep -aqP -- '-l \x1fhello coordinator$' "$CB_TMUX_LOG"
  [ "$status" -eq 0 ]
}
@test "cb_coord_send defers (returns 1, sends nothing) into a dead login shell" {
  pane coord-login-shell   # must never receive send-keys — it would EXECUTE the text
  run cb_coord_send "cb-watch: fix-x needs-input"
  [ "$status" -eq 1 ]
  [ ! -s "$CB_TMUX_LOG" ]
}
@test "cb_coord_send defers (returns 1, sends nothing) into Kyle's half-typed line" {
  pane coord-typed
  run cb_coord_send "cb-watch: fix-x needs-input"
  [ "$status" -eq 1 ]
  [ ! -s "$CB_TMUX_LOG" ]
}
@test "cb_coord_send defers (returns 1, sends nothing) into a working pane" {
  pane coord-busy
  run cb_coord_send "cb-watch: fix-x needs-input"
  [ "$status" -eq 1 ]
  [ ! -s "$CB_TMUX_LOG" ]
}

# --- R19: focus auto-exit signal ---
# A submitted turn echoes into the transcript as its own `❯ <text>` line and the
# LIVE composer is the last one, so "ours or his?" is asked of the second-to-last.
# The predecessor of this block tested the last non-blank LINE of the capture,
# which on this build is always the status footer — so it returned "Kyle is back"
# for every pane in every state, including a dead shell.
@test "R19: a real human turn above the composer signals Kyle returned (exit focus)" {
  export CB_INJECT_MARK='@@'
  pane coord-busy   # holds a genuine `❯ Push` turn above the live composer
  run cb_focus_human_returned; [ "$status" -eq 0 ]
}
@test "R19: our own marker-prefixed submitted turn → stay in focus" {
  export CB_INJECT_MARK='@@'
  export CB_COORD_PANE_CMD="printf '%s\n' '❯ @@Supervisor escalate (2): a · b (pre-read)' '─────' '❯ ' '─────'"
  run cb_focus_human_returned; [ "$status" -ne 0 ]
}
@test "R19: an idle pane with nothing submitted on screen → stay in focus" {
  pane coord-idle-empty
  run cb_focus_human_returned; [ "$status" -ne 0 ]
}
@test "R19: a working pane with no submitted turn in the window → stay in focus" {
  export CB_COORD_PANE_CMD="printf '%s\n' '✢ Gallivanting… (5m 9s · ↓ 13.2k tokens)' '─────' '❯ ' '─────'"
  run cb_focus_human_returned; [ "$status" -ne 0 ]
}
@test "R19: a dead login shell → fail closed (stay in focus)" {
  pane coord-login-shell
  run cb_focus_human_returned; [ "$status" -ne 0 ]
}
@test "R19: a bash pane → fail closed (stay in focus)" {
  pane coord-shell
  run cb_focus_human_returned; [ "$status" -ne 0 ]
}
@test "R19: an unreadable pane → fail closed (stay in focus)" {
  export CB_COORD_PANE_CMD="printf ''"
  run cb_focus_human_returned; [ "$status" -ne 0 ]
}
@test "R19: Kyle's UNSUBMITTED composer text is not a human turn (it may be our own strand)" {
  pane coord-typed   # `❯ arm it` is the only ❯ line — nothing submitted above it
  run cb_focus_human_returned; [ "$status" -ne 0 ]
}

# --- RUNG 5: transcript advance (regression, 2026-08-05) --------------------
# cb-guard caught Cerebro:0.0 working while every CB_COORD_BUSY_RE rung read
# not-busy, because the TUI renders NO spinner while streaming output. The busy
# frame and the idle frame are structurally identical, so no regex over one frame
# can separate them — the signal is between two frames.

@test "RUNG 5: a pane whose tail CHANGES between samples reads busy, not empty" {
  local n="$BATS_TEST_TMPDIR/n"; echo 0 > "$n"
  cb_coord_pane_tail() {
    local i; i=$(cat "$n"); echo $((i+1)) > "$n"
    printf '  streaming line %s\n──────\n❯ \n──────\n' "$i"
  }
  CB_COORD_ADVANCE_SECS=0.05
  run cb_coord_pane_state
  [ "$output" = "busy" ]
}

@test "RUNG 5: a STILL pane with an empty composer still reads empty" {
  cb_coord_pane_tail() { printf '  quiet\n──────\n❯ \n──────\n'; }
  CB_COORD_ADVANCE_SECS=0.05
  run cb_coord_pane_state
  [ "$output" = "empty" ]
}

@test "RUNG 5: CB_COORD_ADVANCE_SECS=0 disables the second sample" {
  local n="$BATS_TEST_TMPDIR/n2"; echo 0 > "$n"
  cb_coord_pane_tail() {
    local i; i=$(cat "$n"); echo $((i+1)) > "$n"
    printf '  changing %s\n──────\n❯ \n──────\n' "$i"
  }
  CB_COORD_ADVANCE_SECS=0
  run cb_coord_pane_state
  [ "$output" = "empty" ]
}
