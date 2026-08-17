#!/usr/bin/env bats
# cb-reap — the research/ops reap decision. Written 2026-07-30 for a regression:
# cb-reap had a SECOND implementation of "is this task done" that grepped the
# beacon, and the beacon vocabulary (cb-brief) has no terminal word — agents write
# running/paused/blocked and treat report.md as the terminal deliverable. So
# `blocked: deliverables written` on a task whose report.md said `status: complete`
# pinned a finished slot forever (asd-1226-attemptsubmission-stranding, 2026-07-29),
# and 110 of 125 finished tasks sat on a `running` beacon.
# State is now DERIVED via lib/classify.sh, where terminal report frontmatter wins
# outright. These tests pin that.

setup() {
  export CB_HOME="$BATS_TEST_TMPDIR/.cerebro"; mkdir -p "$CB_HOME/tasks" "$CB_HOME/logs"
  export VAULT_DIR="$BATS_TEST_TMPDIR/vault"; mkdir -p "$VAULT_DIR/00 Inbox"
  # shim tmux on PATH — cb-reap calls it directly, not via CB_TMUX_BIN
  export SHIM="$BATS_TEST_TMPDIR/bin"; mkdir -p "$SHIM"
  export TMUX_LOG="$BATS_TEST_TMPDIR/tmux.log"; : > "$TMUX_LOG"
  export WINDOWS="$BATS_TEST_TMPDIR/windows"   # lines: "<name> <activity-epoch>"
  export SESSIONS="$BATS_TEST_TMPDIR/sessions" # lines: "<name> <activity-epoch>"
  : > "$WINDOWS"; : > "$SESSIONS"
  export WT_ROOT="$BATS_TEST_TMPDIR/worktrees"; mkdir -p "$WT_ROOT"
  cat > "$SHIM/tmux" <<'EOF'
#!/usr/bin/env bash
echo "tmux $*" >> "$TMUX_LOG"
case "$1" in
  has-session) [ "$3" = cb ] && exit 0 || exit 1;;
  list-windows) cat "$WINDOWS";;
  ls)          cat "$SESSIONS" 2>/dev/null; exit 0;;
  kill-window) echo "KILLED $3" >> "$TMUX_LOG"; exit 0;;
  kill-session) echo "KILLEDSES $3" >> "$TMUX_LOG"; exit 0;;
  *) exit 0;;
esac
EOF
  chmod +x "$SHIM/tmux"; export PATH="$SHIM:$PATH"
  # classify.sh's liveness probe — the window is alive in every test here
  export CB_WINDOW_LIST_CMD="awk '{print \$1}' '$WINDOWS'"
}

mk_task() { # mk_task <slug> <report-status|-> <beacon-line> <quiet-minutes>
  local slug="$1" rep="$2" beacon="$3" quiet="$4"
  mkdir -p "$CB_HOME/tasks/$slug"
  [ "$rep" = "-" ] || printf -- '---\nstatus: %s\n---\n' "$rep" > "$CB_HOME/tasks/$slug/report.md"
  printf '%s\n' "$beacon" > "$CB_HOME/tasks/$slug/status"
  printf '%s %s\n' "$slug" "$(( $(date +%s) - quiet*60 ))" >> "$WINDOWS"
}

@test "REGRESSION: complete report + 'blocked:' beacon is REAPED, not pinned" {
  # the asd-1226 shape — agent used blocked: to mean "done, awaiting a human"
  mk_task asd-1226 complete "blocked: deliverables written. Investigation finished." 5
  run scripts/cerebro/cb-reap --sweep
  [ "$status" -eq 0 ]
  grep -q "KILLED cb:asd-1226" "$TMUX_LOG"
}

@test "REGRESSION: complete report + 'running:' beacon is REAPED" {
  # the 110-of-125 shape — beacon never reached a terminal word because there isn't one
  mk_task bug-backlog complete "running: devitem→Jira map delivered (181 items)" 5
  run scripts/cerebro/cb-reap --sweep
  [ "$status" -eq 0 ]
  grep -q "KILLED cb:bug-backlog" "$TMUX_LOG"
}

@test "a done task reaps at 8m — well inside the 20-minute idle proxy" {
  # positive evidence of completion beats an absence-of-output proxy; a live TUI
  # keeps redrawing so window_activity rarely goes quiet for 20m. Floor is
  # DONE_QUIET_MIN (5m), not WIN_IDLE_MIN (20m).
  mk_task quick-done complete "running: wrote report" 8
  run scripts/cerebro/cb-reap --sweep
  grep -q "KILLED cb:quick-done" "$TMUX_LOG"
}

@test "but a done task IS held below the race floor" {
  # guards the window between the report write and the beacon settling (< 5m)
  mk_task just-wrote complete "running: writing report" 1
  run scripts/cerebro/cb-reap --sweep
  ! grep -q "KILLED cb:just-wrote" "$TMUX_LOG"
}

@test "no report.md → never reaped, however quiet" {
  mk_task no-report - "running: still working" 90
  run scripts/cerebro/cb-reap --sweep
  ! grep -q "KILLED cb:no-report" "$TMUX_LOG"
}

@test "report present but NOT terminal + fresh window → kept (falls back to idle proxy)" {
  mk_task partial-fresh draft "running: mid-flight" 3
  run scripts/cerebro/cb-reap --sweep
  ! grep -q "KILLED cb:partial-fresh" "$TMUX_LOG"
}

@test "report present but NOT terminal + long-idle window → reaped via the fallback" {
  mk_task partial-idle draft "running: mid-flight" 45
  run scripts/cerebro/cb-reap --sweep
  grep -q "KILLED cb:partial-idle" "$TMUX_LOG"
}

@test "genuinely paused is kept even with a complete report absent" {
  mk_task really-paused - "paused: waiting on Albert's reply" 60
  run scripts/cerebro/cb-reap --sweep
  ! grep -q "KILLED cb:really-paused" "$TMUX_LOG"
}

@test "reap-protect still wins over a done classification" {
  mk_task protected-done complete "running: done" 30
  printf 'protected-done\n' > "$CB_HOME/reap-protect"
  run scripts/cerebro/cb-reap --sweep
  ! grep -q "KILLED cb:protected-done" "$TMUX_LOG"
}

@test "the bare 'bash' window is never touched" {
  printf 'bash %s\n' "$(( $(date +%s) - 9999 ))" >> "$WINDOWS"
  run scripts/cerebro/cb-reap --sweep
  ! grep -q "KILLED cb:bash" "$TMUX_LOG"
}

@test "a reap appends a resume note to the dated reaped-sessions log" {
  mk_task noted complete "running: done" 30
  run scripts/cerebro/cb-reap --sweep
  local log="$VAULT_DIR/00 Inbox/$(TZ=America/Denver date +%F)-reaped-sessions.md"
  [ -f "$log" ]
  grep -q "noted" "$log"
}

@test "--dry-run reaps nothing" {
  mk_task dry complete "running: done" 30
  run scripts/cerebro/cb-reap --sweep --dry-run
  [ "$status" -eq 0 ]
  ! grep -q "KILLED" "$TMUX_LOG"
  [[ "$output" == *"WOULD reap"* ]]
}

@test "a DECLARED pause outranks a terminal report — paused agents are never reaped" {
  # caught live 2026-07-30: jones-forms-current-identifier-binding had a complete
  # report AND `paused: awaiting Albert reply`. The report is interim; the agent
  # resumes when the answer lands. Reaping it would discard live context.
  mk_task paused-with-report complete "paused: awaiting Albert reply in Slack; clears when Kyle relays it" 60
  run scripts/cerebro/cb-reap --sweep
  ! grep -q "KILLED cb:paused-with-report" "$TMUX_LOG"
}

@test "but 'blocked:' with a terminal report IS reaped — that is the misuse we defeat" {
  # the contract defines blocked as "stuck, needing a decision". A task with a
  # terminal report is not stuck; asd-1226 used blocked to mean "done".
  mk_task blocked-but-done complete "blocked: deliverables written, only human gates remain" 60
  run scripts/cerebro/cb-reap --sweep
  grep -q "KILLED cb:blocked-but-done" "$TMUX_LOG"
}

# ---------- code-conductor branch ----------
# Same defect, second half: this branch grepped the beacon for needs-input|blocked.
# classify_code never reads the beacon at all — it keys on the cb-cleanup `done`
# marker, pr.state, summary.md, the manifest gate, liveness and pane signatures.

mk_code() { # mk_code <slug> <beacon-line> <quiet-min>   (+ caller adds signals)
  local slug="$1" beacon="$2" quiet="$3"
  mkdir -p "$CB_HOME/tasks/$slug" "$WT_ROOT/$slug"
  printf 'kind=code\nsession=%s\n' "$slug" > "$CB_HOME/tasks/$slug/meta"
  printf '%s\n' "$beacon" > "$CB_HOME/tasks/$slug/status"
  printf '%s %s\n' "$slug" "$(( $(date +%s) - quiet*60 ))" >> "$SESSIONS"
  export CB_WT_BASE="$WT_ROOT"
}

@test "code: a MERGED pr.state reaps the session — beacon says running" {
  mk_code merged-pr "running: still shipping" 30
  printf 'MERGED\n' > "$CB_HOME/tasks/merged-pr/pr.state"
  run scripts/cerebro/cb-reap --sweep
  grep -q "KILLEDSES merged-pr" "$TMUX_LOG"
}

@test "code: a DECLINED pr.state reaps as failed — beacon says running" {
  mk_code declined-pr "running: awaiting review" 30
  printf 'DECLINED\n' > "$CB_HOME/tasks/declined-pr/pr.state"
  run scripts/cerebro/cb-reap --sweep
  grep -q "KILLEDSES declined-pr" "$TMUX_LOG"
}

@test "code: cb-cleanup's done marker reaps even with a 'blocked:' beacon" {
  mk_code marked-done "blocked: waiting on something stale" 30
  touch "$CB_HOME/tasks/marked-done/done"
  run scripts/cerebro/cb-reap --sweep
  grep -q "KILLEDSES marked-done" "$TMUX_LOG"
}

# Fixture updated 2026-08-16: `pr` added because 47078ba6 (Finding 3, Kyle-pinned)
# made the terminal shortcut require summary.md AND pr. The assertion is unchanged —
# a task at Kyle's ship gate is still never stood down. What moved is what counts as
# shipped, and this fixture declared it the old way.
@test "code: summary.md + pr => ready-for-review is NOT reaped (awaiting Kyle's ship gate)" {
  mk_code at-ship-gate "running: ship/awaiting-approval" 30
  printf 'pull-requests/2600\n' > "$CB_HOME/tasks/at-ship-gate/summary.md"
  printf 'https://bitbucket.org/porchsoftware/ultron/pull-requests/2600\n' > "$CB_HOME/tasks/at-ship-gate/pr"
  run scripts/cerebro/cb-reap --sweep
  ! grep -q "KILLEDSES at-ship-gate" "$TMUX_LOG"
}

@test "code: a declared pause still reaps-as-paused, with the cb-resume note" {
  mk_code paused-code "paused: waiting for Kyle's arch call" 30
  run scripts/cerebro/cb-reap --sweep
  grep -q "KILLEDSES paused-code" "$TMUX_LOG"
  local log="$VAULT_DIR/00 Inbox/$(TZ=America/Denver date +%F)-reaped-sessions.md"
  grep -q "resume: cb-resume paused-code" "$log"
  ! grep -q "cb-start --code --adopt" "$log"
}

@test "code: a pause declared in the MANIFEST is kept, not stood down" {
  # The beacon `paused:` arm above reaps-with-worktree-kept — that is the agent's
  # own hand-off. A manifest `gate: paused` is the conductor annotating itself
  # mid-wait, and must not cost it its session: with 0 commits it would otherwise
  # fall through to the "never built" arm and be killed.
  mk_code manifest-paused "running: investigating" 30
  printf 'kind=code\nsession=manifest-paused\nworktree=%s/manifest-paused\n' "$WT_ROOT" \
    > "$CB_HOME/tasks/manifest-paused/meta"
  mkdir -p "$WT_ROOT/manifest-paused/.ai/specs/manifest-paused"
  printf -- '---\ncurrent_task: spec/2-investigate\ngate: paused\ngate_question: waiting on the form-tool mapping\n---\n' \
    > "$WT_ROOT/manifest-paused/.ai/specs/manifest-paused/manifest.md"
  # a REAL repo: without one the commit arithmetic aborts the sweep, and the
  # assertion below would pass on a crash rather than on the keep arm
  git -C "$WT_ROOT/manifest-paused" init -q
  printf 'manifest-paused %s\n' "$(date +%s)" >> "$WINDOWS"
  run scripts/cerebro/cb-reap --sweep
  ! grep -q "KILLEDSES manifest-paused" "$TMUX_LOG"
}

@test "code: an active session is never touched" {
  mk_code busy "running: building" 1
  printf 'MERGED\n' > "$CB_HOME/tasks/busy/pr.state"
  run scripts/cerebro/cb-reap --sweep
  ! grep -q "KILLEDSES busy" "$TMUX_LOG"
}

@test "code: Cerebro and cb sessions are never reaped" {
  printf 'Cerebro %s\ncb %s\n' "$(( $(date +%s) - 9999 ))" "$(( $(date +%s) - 9999 ))" >> "$SESSIONS"
  run scripts/cerebro/cb-reap --sweep
  ! grep -q "KILLEDSES Cerebro" "$TMUX_LOG"
  ! grep -q "KILLEDSES cb" "$TMUX_LOG"
}

@test "code: a session with no worktree is skipped" {
  mkdir -p "$CB_HOME/tasks/no-wt"; printf 'kind=code\n' > "$CB_HOME/tasks/no-wt/meta"
  printf 'MERGED\n' > "$CB_HOME/tasks/no-wt/pr.state"
  printf 'no-wt %s\n' "$(( $(date +%s) - 1800 ))" >> "$SESSIONS"
  export CB_WT_BASE="$WT_ROOT"
  run scripts/cerebro/cb-reap --sweep
  ! grep -q "KILLEDSES no-wt" "$TMUX_LOG"
}

# ---------- ingest queue: a reap must never LOSE a finding ----------
# Reaping frees the slot but cannot land the report — /ingest decides destination
# and that is judgment (operating contract: "where a human is structurally
# required"). So the finding is queued durably instead of dropped.

@test "ingest queue: reaping a done research task queues its report" {
  mk_task queued-finding complete "running: report written" 30
  run scripts/cerebro/cb-reap --sweep
  grep -q "KILLED cb:queued-finding" "$TMUX_LOG"
  [ -f "$CB_HOME/logs/ingest-queue" ]
  grep -q "queued-finding" "$CB_HOME/logs/ingest-queue"
  grep -q "report=$CB_HOME/tasks/queued-finding/report.md" "$CB_HOME/logs/ingest-queue"
}

@test "ingest queue: a declared deliverable path is recorded when present" {
  mkdir -p "$CB_HOME/tasks/with-deliv"
  printf -- '---\nstatus: complete\ndeliverable: 00 Inbox/2026-07-29-thing.md\n---\n' \
    > "$CB_HOME/tasks/with-deliv/report.md"
  printf 'running: done\n' > "$CB_HOME/tasks/with-deliv/status"
  printf 'with-deliv %s\n' "$(( $(date +%s) - 1800 ))" >> "$WINDOWS"
  run scripts/cerebro/cb-reap --sweep
  grep -q "deliverable=00 Inbox/2026-07-29-thing.md" "$CB_HOME/logs/ingest-queue"
}

@test "ingest queue: no declared deliverable records 'none', not an empty field" {
  mk_task no-deliv complete "running: done" 30
  run scripts/cerebro/cb-reap --sweep
  grep -q "deliverable=none" "$CB_HOME/logs/ingest-queue"
}

@test "ingest queue: a NON-terminal report is not queued" {
  # only complete/done/partial land in the queue; a draft has nothing to ingest
  mk_task draft-idle draft "running: mid-flight" 45
  run scripts/cerebro/cb-reap --sweep
  grep -q "KILLED cb:draft-idle" "$TMUX_LOG"        # still reaped via the idle proxy
  ! grep -q "draft-idle" "$CB_HOME/logs/ingest-queue" 2>/dev/null
}

@test "ingest queue: nothing is queued when nothing is reaped" {
  mk_task not-reaped complete "paused: waiting on Kyle" 60
  run scripts/cerebro/cb-reap --sweep
  ! grep -q "not-reaped" "$CB_HOME/logs/ingest-queue" 2>/dev/null
}

@test "the resume note names the un-ingested report path so the human surface carries it too" {
  mk_task noted-uningested complete "running: done" 30
  run scripts/cerebro/cb-reap --sweep
  local log="$VAULT_DIR/00 Inbox/$(TZ=America/Denver date +%F)-reaped-sessions.md"
  grep -q "NOT ingested" "$log"
  grep -q "noted-uningested/report.md" "$log"
}

@test "--dry-run queues nothing" {
  mk_task dry-noqueue complete "running: done" 30
  run scripts/cerebro/cb-reap --sweep --dry-run
  [ ! -f "$CB_HOME/logs/ingest-queue" ] || ! grep -q "dry-noqueue" "$CB_HOME/logs/ingest-queue"
}
