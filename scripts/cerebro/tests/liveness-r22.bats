#!/usr/bin/env bats
# R22 — harness-process liveness. tmux name presence is necessary but not
# sufficient: a dead shell in a live-named pane must read `gone`. The asymmetry
# rule is absolute — a downgrade to `gone` requires POSITIVE evidence (pane root
# is a shell AND no harness process anywhere in its subtree). Anything unknown
# keeps today's answer and is never acted on.

setup() { load ../lib/classify.sh; TD="$BATS_TEST_TMPDIR/task"; mkdir -p "$TD"; }

# ps fixtures: "pid ppid comm" — the format of `ps -eo pid=,ppid=,comm=`
PS_HEALTHY() {   printf '1 0 systemd\n900 1 tmux\n1000 900 claude\n1001 1000 rg\n'; }
PS_TOOLCALL() {  printf '1 0 systemd\n900 1 tmux\n1000 900 bash\n1100 1000 claude\n1101 1100 npm\n'; }
PS_DEADSHELL() { printf '1 0 systemd\n900 1 tmux\n1000 900 bash\n'; }
PS_ODDCMD() {    printf '1 0 systemd\n900 1 tmux\n1000 900 python3\n'; }

@test "_proc_subtree_has finds a harness at the pane root" {
  CB_PS_CMD="$(declare -f PS_HEALTHY); PS_HEALTHY" run _proc_subtree_has 1000 '^(claude|node)$'
  [ "$status" -eq 0 ]
}
@test "_proc_subtree_has finds a harness nested under a shell root (the tool-call case)" {
  CB_PS_CMD="$(declare -f PS_TOOLCALL); PS_TOOLCALL" run _proc_subtree_has 1000 '^(claude|node)$'
  [ "$status" -eq 0 ]
}
@test "_proc_subtree_has returns not-found for a bare shell" {
  CB_PS_CMD="$(declare -f PS_DEADSHELL); PS_DEADSHELL" run _proc_subtree_has 1000 '^(claude|node)$'
  [ "$status" -eq 1 ]
}
@test "_proc_subtree_has returns CANNOT-TELL (2) when the pid is absent from the table" {
  CB_PS_CMD="$(declare -f PS_DEADSHELL); PS_DEADSHELL" run _proc_subtree_has 4242 '^(claude|node)$'
  [ "$status" -eq 2 ]
}
@test "_proc_subtree_has returns CANNOT-TELL (2) on an empty/failed ps" {
  CB_PS_CMD="exit 127" run _proc_subtree_has 1000 '^(claude|node)$'
  [ "$status" -eq 2 ]
}

@test "cb_pane_proc_state: harness at root or nested → harness" {
  CB_PS_CMD="$(declare -f PS_HEALTHY); PS_HEALTHY" run cb_pane_proc_state 1000
  [ "$output" = "harness" ]
  CB_PS_CMD="$(declare -f PS_TOOLCALL); PS_TOOLCALL" run cb_pane_proc_state 1000
  [ "$output" = "harness" ]
}
@test "cb_pane_proc_state: shell root with no harness beneath → dead" {
  CB_PS_CMD="$(declare -f PS_DEADSHELL); PS_DEADSHELL" run cb_pane_proc_state 1000
  [ "$output" = "dead" ]
}
@test "cb_pane_proc_state: an unrecognized root command is UNKNOWN, never dead" {
  CB_PS_CMD="$(declare -f PS_ODDCMD); PS_ODDCMD" run cb_pane_proc_state 1000
  [ "$output" = "unknown" ]
}
@test "cb_pane_proc_state: absent pid / unreadable ps / empty pid → unknown" {
  CB_PS_CMD="$(declare -f PS_DEADSHELL); PS_DEADSHELL" run cb_pane_proc_state 4242
  [ "$output" = "unknown" ]
  CB_PS_CMD="exit 127" run cb_pane_proc_state 1000
  [ "$output" = "unknown" ]
  run cb_pane_proc_state ""
  [ "$output" = "unknown" ]
  run cb_pane_proc_state "not-a-pid"
  [ "$output" = "unknown" ]
}

# --- session liveness: name presence + per-pane process evidence -------------
@test "cb_session_present keeps the old name-only contract (alive/gone/unavailable)" {
  CB_SESSION_LIST_CMD="printf 'code-slug\nCerebro\n'" run cb_session_present code-slug
  [ "$output" = "alive" ]
  CB_SESSION_LIST_CMD="printf 'Cerebro\n'" run cb_session_present code-slug
  [ "$output" = "gone" ]
  CB_SESSION_LIST_CMD="exit 127" run cb_session_present code-slug
  [ "$output" = "unavailable" ]
}
@test "R22: session name present but every pane is a dead shell → gone" {
  CB_SESSION_LIST_CMD="printf 'code-slug\n'" \
  CB_SESSION_PID_CMD="printf 'code-slug 1000\n'" \
  CB_PS_CMD="$(declare -f PS_DEADSHELL); PS_DEADSHELL" run cb_session_alive code-slug
  [ "$output" = "gone" ]
}
@test "R22: a session with ONE live-harness pane stays alive even if another pane is a shell" {
  CB_SESSION_LIST_CMD="printf 'code-slug\n'" \
  CB_SESSION_PID_CMD="printf 'code-slug 1000\ncode-slug 1100\n'" \
  CB_PS_CMD="printf '1 0 systemd\n1000 1 bash\n1100 1 claude\n'" run cb_session_alive code-slug
  [ "$output" = "alive" ]
}
@test "R22: a busy harness (shell pane root, claude beneath) stays alive" {
  CB_SESSION_LIST_CMD="printf 'code-slug\n'" \
  CB_SESSION_PID_CMD="printf 'code-slug 1000\n'" \
  CB_PS_CMD="$(declare -f PS_TOOLCALL); PS_TOOLCALL" run cb_session_alive code-slug
  [ "$output" = "alive" ]
}
@test "R22: session present but the pane-pid probe is unreadable → alive (unknown never acted on)" {
  CB_SESSION_LIST_CMD="printf 'code-slug\n'" CB_SESSION_PID_CMD="exit 127" run cb_session_alive code-slug
  [ "$output" = "alive" ]
  CB_SESSION_LIST_CMD="printf 'code-slug\n'" CB_SESSION_PID_CMD="printf ''" run cb_session_alive code-slug
  [ "$output" = "alive" ]
}
@test "R22: session name absent stays gone; name list unavailable stays unavailable" {
  CB_SESSION_LIST_CMD="printf 'Cerebro\n'" run cb_session_alive code-slug
  [ "$output" = "gone" ]
  CB_SESSION_LIST_CMD="exit 127" run cb_session_alive code-slug
  [ "$output" = "unavailable" ]
}
@test "R22: pane-pid lookup matches the session name literally, not as a prefix" {
  CB_SESSION_LIST_CMD="printf 'code\n'" \
  CB_SESSION_PID_CMD="printf 'code-slug 1000\n'" \
  CB_PS_CMD="$(declare -f PS_DEADSHELL); PS_DEADSHELL" run cb_session_alive code
  [ "$output" = "alive" ]     # no pane row for "code" → cannot tell → today's answer
}

# --- window liveness (research / ops X-Men live as windows in the cb session) -
@test "R22: window name present but the pane is a dead shell → gone" {
  CB_WINDOW_LIST_CMD="printf 'probe-x\n'" \
  CB_WINDOW_PID_CMD="printf 'probe-x 1000\n'" \
  CB_PS_CMD="$(declare -f PS_DEADSHELL); PS_DEADSHELL" run cb_window_alive probe-x
  [ "$output" = "gone" ]
}
@test "R22: window with a live harness pane → alive" {
  CB_WINDOW_LIST_CMD="printf 'probe-x\n'" \
  CB_WINDOW_PID_CMD="printf 'probe-x 1000\n'" \
  CB_PS_CMD="$(declare -f PS_HEALTHY); PS_HEALTHY" run cb_window_alive probe-x
  [ "$output" = "alive" ]
}
@test "R22: window pane-pid probe unreadable → alive (unknown never acted on)" {
  CB_WINDOW_LIST_CMD="printf 'probe-x\n'" CB_WINDOW_PID_CMD="exit 127" run cb_window_alive probe-x
  [ "$output" = "alive" ]
}
@test "R22: window name absent stays gone; name list unavailable stays unavailable" {
  CB_WINDOW_LIST_CMD="printf ''" run cb_window_alive probe-x
  [ "$output" = "gone" ]
  CB_WINDOW_LIST_CMD="exit 127" run cb_window_alive probe-x
  [ "$output" = "unavailable" ]
}
@test "R22: window pane-pid lookup is a literal name match (metachar slug safety)" {
  CB_WINDOW_LIST_CMD="printf 'eja.3537\n'" \
  CB_WINDOW_PID_CMD="printf 'eja-3537 1000\n'" \
  CB_PS_CMD="$(declare -f PS_DEADSHELL); PS_DEADSHELL" run cb_window_alive "eja.3537"
  [ "$output" = "alive" ]     # no pane row for the real slug → cannot tell → alive
}

# --- classify integration: the R22 downgrade flows through the classifiers ----
# RETITLED + MOVED failed → needs-input, 2026-08-16. This is row 3 of the Finding-1
# table in 99 Meta/specs/2026-08-13-classify-r13-polarity-design (47078ba6,
# kyle-2026-08-14-proceed). R22's downgrade still fires — that is what this test is
# for, and the assertion below still proves it: a dead shell routes through `gone`
# and reads DIFFERENTLY from the live-harness case in the next test, which reads
# `blocked` via `alive`. Only the terminal word moved, because a research window
# closes when the agent FINISHES as well as when it crashes.
@test "R22: classify_research — dead-shell window + stale beacon → needs-input (was blocked)" {
  printf 'running: fetching sources\n' > "$TD/status"; touch -d '2 hours ago' "$TD/status"
  CB_WINDOW_LIST_CMD="printf '$(basename "$TD")\n'" \
  CB_WINDOW_PID_CMD="printf '$(basename "$TD") 1000\n'" \
  CB_PS_CMD="$(declare -f PS_DEADSHELL); PS_DEADSHELL" run classify_research "$TD"
  [ "$output" = "needs-input" ]
  [ "$output" != "blocked" ]            # the R22 downgrade fired — this is not the alive path
}
@test "R22: classify_research — live-harness window + stale beacon still → blocked (unchanged)" {
  printf 'running: fetching sources\n' > "$TD/status"; touch -d '2 hours ago' "$TD/status"
  CB_WINDOW_LIST_CMD="printf '$(basename "$TD")\n'" \
  CB_WINDOW_PID_CMD="printf '$(basename "$TD") 1000\n'" \
  CB_PS_CMD="$(declare -f PS_HEALTHY); PS_HEALTHY" run classify_research "$TD"
  [ "$output" = "blocked" ]
}
@test "R22: classify_code — the spend-wedge path is untouched (wedged claude is still a live harness)" {
  CTD="$BATS_TEST_TMPDIR/tasks/code-slug"; mkdir -p "$CTD"
  CWT="$BATS_TEST_TMPDIR/worktree"; mkdir -p "$CWT/.ai/specs/code-slug"
  printf 'kind=code\nworktree=%s\njira=EJA-99\nsession=code-slug\n' "$CWT" > "$CTD/meta"
  printf -- '---\ncurrent_task: build/3-implement\n---\n' > "$CWT/.ai/specs/code-slug/manifest.md"
  touch -d '3 hours ago' "$CWT/.ai/specs/code-slug/manifest.md"
  local fixpanes; fixpanes="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)/fixtures/panes"
  CB_SESSION_LIST_CMD="printf 'code-slug\n'" \
  CB_SESSION_PID_CMD="printf 'code-slug 1000\n'" \
  CB_PS_CMD="$(declare -f PS_HEALTHY); PS_HEALTHY" \
  CB_PANE_CMD="cat '$fixpanes/spend-wedge.txt'" run classify_code "$CTD"
  [ "$output" = "blocked" ]
}
@test "R22: classify_code — dead-shell session goes straight to failed (not a wedge)" {
  CTD="$BATS_TEST_TMPDIR/tasks/dead-slug"; mkdir -p "$CTD"
  CWT="$BATS_TEST_TMPDIR/worktree-d"; mkdir -p "$CWT/.ai/specs/dead-slug"
  printf 'kind=code\nworktree=%s\njira=EJA-99\nsession=dead-slug\n' "$CWT" > "$CTD/meta"
  printf -- '---\ncurrent_task: build/3-implement\n---\n' > "$CWT/.ai/specs/dead-slug/manifest.md"
  touch -d '10 minutes ago' "$CWT/.ai/specs/dead-slug/manifest.md"   # FRESH manifest
  CB_SESSION_LIST_CMD="printf 'dead-slug\n'" \
  CB_SESSION_PID_CMD="printf 'dead-slug 1000\n'" \
  CB_PS_CMD="$(declare -f PS_DEADSHELL); PS_DEADSHELL" run classify_code "$CTD"
  [ "$output" = "failed" ]
}
