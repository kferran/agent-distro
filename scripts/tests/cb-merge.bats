#!/usr/bin/env bats
# cb-merge (T23): poll-only merge detection (Bitbucket merge stays
# operator-driven) + local ff for delivery: local-only rows.

setup() {
  export HOME="$BATS_TEST_TMPDIR/home"; mkdir -p "$HOME"
  export CB_HOME="$BATS_TEST_TMPDIR/.cerebro"; mkdir -p "$CB_HOME/tasks" "$CB_HOME/logs"
  export CB_REGISTRY="$BATS_TEST_TMPDIR/projects.md"
  printf -- '- project: ultron\n  workspace: porchsoftware\n  repo: ultron\n  base: main\n  checkout: %s\n  delivery: bitbucket-pr\n  reviewers: ["a1b2"]\n- project: sandbox\n  checkout: %s\n  delivery: local-only\n' "$BATS_TEST_TMPDIR" "$BATS_TEST_TMPDIR" > "$CB_REGISTRY"
  export BB_EMAIL="a@b" BB_API_TOKEN="tok"
  export MOCK_DIR="$BATS_TEST_TMPDIR/mock"; mkdir -p "$MOCK_DIR"
  cat > "$MOCK_DIR/curlmock" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$MOCK_DIR/argv"
cat > /dev/null
cat "$MOCK_DIR/response"
EOF
  chmod +x "$MOCK_DIR/curlmock"
  export CB_CURL_CMD="$MOCK_DIR/curlmock"
  export CB_CLEANUP_CMD="touch $MOCK_DIR/cleanup-called"
}

mk_open_pr_task() { # mk_open_pr_task <slug> <target>
  mkdir -p "$CB_HOME/tasks/$1"
  printf 'kind=code\nworktree=%s\njira=EJA-9\nsession=%s\ntarget=%s\n' "$BATS_TEST_TMPDIR" "$1" "$2" > "$CB_HOME/tasks/$1/meta"
  printf '7 https://bb/pr/7' > "$CB_HOME/tasks/$1/pr"
  printf 'OPEN' > "$CB_HOME/tasks/$1/pr.state"
}

@test "--poll MERGED: pr.state updated + cleanup hook invoked" {
  mk_open_pr_task fix-m ultron
  printf '{"id":7,"state":"MERGED"}\n200' > "$MOCK_DIR/response"
  run scripts/cerebro/cb-merge --poll fix-m
  [ "$status" -eq 0 ]
  [ "$(cat "$CB_HOME/tasks/fix-m/pr.state")" = "MERGED" ]
  [ -f "$MOCK_DIR/cleanup-called" ]
  grep -q 'fix-m merged' "$CB_HOME/logs/events"
}

@test "--poll OPEN: no-op — state unchanged, no cleanup" {
  mk_open_pr_task fix-o ultron
  printf '{"id":7,"state":"OPEN"}\n200' > "$MOCK_DIR/response"
  run scripts/cerebro/cb-merge --poll fix-o
  [ "$status" -eq 0 ]
  [ "$(cat "$CB_HOME/tasks/fix-o/pr.state")" = "OPEN" ]
  [ ! -f "$MOCK_DIR/cleanup-called" ]
}

@test "--poll DECLINED: pr.state DECLINED + event; classifier reads it as failed" {
  mk_open_pr_task fix-dec ultron
  printf '{"id":7,"state":"DECLINED"}\n200' > "$MOCK_DIR/response"
  run scripts/cerebro/cb-merge --poll fix-dec
  [ "$status" -eq 0 ]
  [ "$(cat "$CB_HOME/tasks/fix-dec/pr.state")" = "DECLINED" ]
  grep -q 'fix-dec declined' "$CB_HOME/logs/events"
  load ../lib/classify.sh
  CB_SESSION_LIST_CMD="printf ''" run classify_code "$CB_HOME/tasks/fix-dec"
  [ "$output" = "failed" ]
}

@test "--poll 401 propagates the escalate exit 3 + event" {
  mk_open_pr_task fix-esc ultron
  printf 'x\n401' > "$MOCK_DIR/response"
  run scripts/cerebro/cb-merge --poll fix-esc
  [ "$status" -eq 3 ]
  grep -q 'fix-esc escalate' "$CB_HOME/logs/events"
}

# M5#8 (folded into step 12): a dead token is polled every tick — the escalate
# line must NOT spam the events log. Content-keyed create-if-absent marker: log
# once per episode, still exit 3 each time; re-arm on a successful non-401 poll.
@test "M5#8: a repeated 401 poll logs the escalate ONCE, still exits 3 each time" {
  mk_open_pr_task fix-spam ultron
  printf 'x\n401' > "$MOCK_DIR/response"
  run scripts/cerebro/cb-merge --poll fix-spam; [ "$status" -eq 3 ]
  run scripts/cerebro/cb-merge --poll fix-spam; [ "$status" -eq 3 ]   # next tick, still dead
  run scripts/cerebro/cb-merge --poll fix-spam; [ "$status" -eq 3 ]
  [ "$(grep -c 'fix-spam escalate (token dead' "$CB_HOME/logs/events")" -eq 1 ]
}
@test "M5#8: a successful poll after a 401 re-arms the escalate (next 401 logs again)" {
  mk_open_pr_task fix-rearm ultron
  printf 'x\n401' > "$MOCK_DIR/response"
  run scripts/cerebro/cb-merge --poll fix-rearm; [ "$status" -eq 3 ]
  printf '{"id":7,"state":"OPEN"}\n200' > "$MOCK_DIR/response"         # token recovers, PR still open
  run scripts/cerebro/cb-merge --poll fix-rearm; [ "$status" -eq 0 ]
  printf 'x\n401' > "$MOCK_DIR/response"                              # dies again
  run scripts/cerebro/cb-merge --poll fix-rearm; [ "$status" -eq 3 ]
  [ "$(grep -c 'fix-rearm escalate (token dead' "$CB_HOME/logs/events")" -eq 2 ]
}

@test "--local refuses on a bitbucket-pr project (operator merges)" {
  mk_open_pr_task fix-bb ultron
  run scripts/cerebro/cb-merge --local fix-bb
  [ "$status" -ne 0 ]
  [[ "$output" == *"operator"* || "$output" == *"bitbucket"* ]]
}

@test "--local ffs a local-only project via the local adapter" {
  mkdir -p "$CB_HOME/tasks/fix-loc" "$CB_HOME/local-prs"
  printf 'kind=code\nworktree=%s\njira=\nsession=fix-loc\ntarget=sandbox\n' "$BATS_TEST_TMPDIR" > "$CB_HOME/tasks/fix-loc/meta"
  printf 'fe-fix-loc local:fe-fix-loc' > "$CB_HOME/tasks/fix-loc/pr"
  printf 'OPEN' > "$CB_HOME/tasks/fix-loc/pr.state"
  printf 'OPEN fe/fix-loc main' > "$CB_HOME/local-prs/fe-fix-loc"
  export CB_LOCAL_REPO="$BATS_TEST_TMPDIR/repo"; mkdir -p "$CB_LOCAL_REPO"
  cat > "$MOCK_DIR/gitmock" <<'EOF'
#!/usr/bin/env bash
echo "GIT $*" >> "$MOCK_DIR/git.log"
EOF
  chmod +x "$MOCK_DIR/gitmock"; export CB_GIT_CMD="$MOCK_DIR/gitmock"
  run scripts/cerebro/cb-merge --local fix-loc
  [ "$status" -eq 0 ]
  grep -q 'merge --ff-only fe/fix-loc' "$MOCK_DIR/git.log"
}

# --- watch integration: tick polls every code task with an OPEN pr file ---
@test "cb-watch tick auto-polls OPEN code PRs (zero-token bash)" {
  mk_open_pr_task fix-w ultron
  printf '{"id":7,"state":"MERGED"}\n200' > "$MOCK_DIR/response"
  export CB_SESSION_LIST_CMD="printf ''"
  run scripts/cerebro/cb-watch --tick
  [ "$status" -eq 0 ]
  [ "$(cat "$CB_HOME/tasks/fix-w/pr.state")" = "MERGED" ]
}
