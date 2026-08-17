#!/usr/bin/env bats
# cb-cleanup (T25): protected reap — never destroy unmerged/dirty code work;
# hand completed work to the ingest skill via the distill queue.

setup() {
  export CB_HOME="$BATS_TEST_TMPDIR/.cerebro"; mkdir -p "$CB_HOME/tasks" "$CB_HOME/logs"
  export CB_REGISTRY="$BATS_TEST_TMPDIR/projects.md"
  CO="$BATS_TEST_TMPDIR/checkout"; mkdir -p "$CO"
  printf -- '- project: ultron\n  base: main\n  checkout: %s\n  delivery: bitbucket-pr\n' "$CO" > "$CB_REGISTRY"
  # tmux mock (cb-peek/cb-send pattern)
  export CB_TMUX_BIN="$BATS_TEST_TMPDIR/faketmux"
  cat > "$CB_TMUX_BIN" <<'EOF'
#!/usr/bin/env bash
echo "tmux $*" >> "$CB_TMUX_LOG"
EOF
  chmod +x "$CB_TMUX_BIN"; export CB_TMUX_LOG="$BATS_TEST_TMPDIR/tmux.log"
  # git mock: status --porcelain replays $GITMOCK_STATUS when set
  export GITMOCK_LOG="$BATS_TEST_TMPDIR/git.log"
  cat > "$BATS_TEST_TMPDIR/gitmock" <<'EOF'
#!/usr/bin/env bash
echo "GIT $*" >> "$GITMOCK_LOG"
case "$*" in
  *"status --porcelain"*) [ -f "${GITMOCK_STATUS:-}" ] && cat "$GITMOCK_STATUS";;
  *"fetch origin"*) [ -n "${GITMOCK_FETCH_FAILS:-}" ] && exit 1;;
  *"rev-list --count"*) echo "${GITMOCK_AHEAD:-3}";;
esac
exit 0
EOF
  chmod +x "$BATS_TEST_TMPDIR/gitmock"
  export CB_GIT_CMD="$BATS_TEST_TMPDIR/gitmock"
  export CB_GUARD_CMD=:   # R1: don't invoke the real cb-guard (network MCP probe) from tests
  # HERMETIC REAP LOG. cb-cleanup:117 resolves VAULT="${VAULT_DIR:-$HOME/vault}", and this
  # suite set neither VAULT_DIR nor HOME — so every run appended its fixture reaps to Kyle's
  # REAL `00 Inbox/<LOCAL>-reaped-sessions.md`. Measured 2026-08-14: 10 of that day's 27
  # entries were `fix-done`/`fix-forced` fixtures carrying /tmp/bats-run-*/ paths and
  # `jira: EJA-9` — 37% of a log whose entire purpose is telling Kyle where real work went.
  # A test that writes outside its sandbox corrupts the audit trail it is testing.
  export VAULT_DIR="$BATS_TEST_TMPDIR/vault"; mkdir -p "$VAULT_DIR/00 Inbox"
}

# --- R1: cb-guard rides every supervision command ---
@test "cb-cleanup runs cb-guard first" {
  mk_code_task fix-open OPEN   # a refusal-path invocation still runs the guard first
  export CB_GUARD_CMD="$BATS_TEST_TMPDIR/guard-rec"
  printf '#!/usr/bin/env bash\ntouch %q\n' "$BATS_TEST_TMPDIR/guard-ran" > "$CB_GUARD_CMD"
  chmod +x "$CB_GUARD_CMD"
  run scripts/cerebro/cb-cleanup fix-open
  [ -f "$BATS_TEST_TMPDIR/guard-ran" ]
}

mk_code_task() { # mk_code_task <slug> <pr-state>
  mkdir -p "$CB_HOME/tasks/$1"
  WT="$BATS_TEST_TMPDIR/wt-$1"; mkdir -p "$WT"
  printf 'kind=code\nworktree=%s\njira=EJA-9\nsession=%s\ntarget=ultron\n' "$WT" "$1" > "$CB_HOME/tasks/$1/meta"
  [ -n "${2:-}" ] && printf '%s' "$2" > "$CB_HOME/tasks/$1/pr.state" || true
}

@test "code: refuses unless pr.state=MERGED (protect unmerged work)" {
  mk_code_task fix-open OPEN
  run scripts/cerebro/cb-cleanup fix-open
  [ "$status" -ne 0 ]
  [[ "$output" == *"MERGED"* || "$output" == *"unmerged"* ]]
  [ ! -s "$GITMOCK_LOG" ] || ! grep -q 'worktree remove' "$GITMOCK_LOG"
  [ -d "$WT" ]
}

@test "code: refuses a dirty worktree with the dirty file named" {
  mk_code_task fix-dirty MERGED
  export GITMOCK_STATUS="$BATS_TEST_TMPDIR/status"
  printf ' M src/uncommitted-thing.ts\n' > "$GITMOCK_STATUS"
  run scripts/cerebro/cb-cleanup fix-dirty
  [ "$status" -ne 0 ]
  [[ "$output" == *"uncommitted-thing.ts"* ]]
  ! grep -q 'worktree remove' "$GITMOCK_LOG"
}

@test "code: merged + clean → worktree remove + kill-session + distill line + done" {
  mk_code_task fix-done MERGED
  run scripts/cerebro/cb-cleanup fix-done
  [ "$status" -eq 0 ]
  grep -q "GIT -C $CO worktree remove $WT" "$GITMOCK_LOG"
  grep -q 'tmux kill-session -t fix-done' "$CB_TMUX_LOG"
  grep -q 'fix-done' "$CB_HOME/logs/distill"
  load ../lib/classify.sh
  CB_SESSION_LIST_CMD="printf ''" run classify_code "$CB_HOME/tasks/fix-done"
  [ "$output" = "done" ]
}

# --- the resume note's commit count must be computed against a FRESH origin ------
# cb-reap was fixed for this on 2026-07-31 (3d85caf7) and shipped the tree-wide lint
# guard at cb-reap-fetch.bats:25. This line arrived a week later (2f719223) without a
# fetch, and the guard caught it. These two pin the contract, not just the grep — a
# bare `fetch origin` passes the lint and still leaves the note wrong when the fetch
# fails, and the note is the only audit trail once the worktree is deleted.

@test "code: fetches origin BEFORE the resume note's commit arithmetic" {
  mk_code_task fix-fetch MERGED
  run scripts/cerebro/cb-cleanup fix-fetch
  [ "$status" -eq 0 ]
  fetch_line="$(grep -n 'fetch origin' "$GITMOCK_LOG" | head -1 | cut -d: -f1)"
  count_line="$(grep -n 'rev-list --count origin/main..HEAD' "$GITMOCK_LOG" | head -1 | cut -d: -f1)"
  [ -n "$fetch_line" ]
  [ -n "$count_line" ]
  [ "$fetch_line" -lt "$count_line" ]
}

@test "code: a failed fetch is non-fatal but stamps the resume note UNVERIFIED" {
  mk_code_task fix-nofetch MERGED
  export GITMOCK_FETCH_FAILS=1
  run scripts/cerebro/cb-cleanup fix-nofetch
  [ "$status" -eq 0 ]                                   # offline reap still works
  grep -q 'worktree remove' "$GITMOCK_LOG"
  notes="$VAULT_DIR/00 Inbox/$(TZ=America/Denver date +%F)-reaped-sessions.md"
  grep -q 'UNVERIFIED' "$notes"                         # …and the count says so
  grep -q 'UNVERIFIED' "$CB_HOME/logs/events"
}

@test "code: a clean fetch leaves the resume note's count unqualified" {
  mk_code_task fix-okfetch MERGED
  run scripts/cerebro/cb-cleanup fix-okfetch
  [ "$status" -eq 0 ]
  notes="$VAULT_DIR/00 Inbox/$(TZ=America/Denver date +%F)-reaped-sessions.md"
  grep -q 'commits ahead of origin/main at reap:\*\* 3' "$notes"
  ! grep -q 'UNVERIFIED' "$notes"
}

@test "code: --force reaps an unmerged-but-clean task and still classifies done" {
  mk_code_task fix-forced OPEN
  run scripts/cerebro/cb-cleanup fix-forced --force
  [ "$status" -eq 0 ]
  grep -q 'worktree remove' "$GITMOCK_LOG"
  load ../lib/classify.sh
  CB_SESSION_LIST_CMD="printf ''" run classify_code "$CB_HOME/tasks/fix-forced"
  [ "$output" = "done" ]
}

@test "code: --force still refuses a dirty worktree (surfaced, not deleted)" {
  mk_code_task fix-fdirty OPEN
  export GITMOCK_STATUS="$BATS_TEST_TMPDIR/status"
  printf ' M precious.ts\n' > "$GITMOCK_STATUS"
  run scripts/cerebro/cb-cleanup fix-fdirty --force
  [ "$status" -ne 0 ]
  [[ "$output" == *"precious.ts"* ]]
}

@test "research: kills the cb window, leaves task dir + report in place" {
  mkdir -p "$CB_HOME/tasks/probe-r"
  printf -- '---\nstatus: complete\n---\nfindings\n' > "$CB_HOME/tasks/probe-r/report.md"
  run scripts/cerebro/cb-cleanup probe-r
  [ "$status" -eq 0 ]
  grep -q 'tmux kill-window -t cb:probe-r' "$CB_TMUX_LOG"
  [ -f "$CB_HOME/tasks/probe-r/report.md" ]
}
