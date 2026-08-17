#!/usr/bin/env bats
# cb-sync (T38): registry-driven fetch/ff/prune on canonical checkouts.
# Never touches live worktrees; prunes only branches whose PRs are MERGED.

setup() {
  export CB_HOME="$BATS_TEST_TMPDIR/.cerebro"; mkdir -p "$CB_HOME/tasks"
  export CB_REGISTRY="$BATS_TEST_TMPDIR/projects.md"
  CO="$BATS_TEST_TMPDIR/checkout"; mkdir -p "$CO"
  printf -- '- project: ultron\n  repo: ultron\n  base: main\n  branch_prefix: fe/\n  checkout: %s\n  delivery: bitbucket-pr\n- project: cerebro\n  checkout: %s\n  delivery: research-only\n' "$CO" "$BATS_TEST_TMPDIR" > "$CB_REGISTRY"
  export GITMOCK_LOG="$BATS_TEST_TMPDIR/git.log"
  export GITMOCK_HEAD="$BATS_TEST_TMPDIR/head"; printf 'main' > "$GITMOCK_HEAD"
  cat > "$BATS_TEST_TMPDIR/gitmock" <<'EOF'
#!/usr/bin/env bash
echo "GIT $*" >> "$GITMOCK_LOG"
case "$*" in
  *"status --porcelain"*) [ -f "${GITMOCK_STATUS:-}" ] && cat "$GITMOCK_STATUS";;
  *"rev-parse --abbrev-ref HEAD"*) cat "$GITMOCK_HEAD";;
  *"branch --list"*) [ -f "${GITMOCK_BRANCHES:-}" ] && cat "$GITMOCK_BRANCHES";;
  *"worktree list"*) [ -f "${GITMOCK_WORKTREES:-}" ] && cat "$GITMOCK_WORKTREES";;
esac
exit 0
EOF
  chmod +x "$BATS_TEST_TMPDIR/gitmock"
  export CB_GIT_CMD="$BATS_TEST_TMPDIR/gitmock"
}

mk_merged_task() { # a reaped, merged code task whose branch lingers locally
  mkdir -p "$CB_HOME/tasks/fix-s"
  printf 'kind=code\nworktree=/gone\njira=EJA-9\nsession=fix-s\ntarget=ultron\n' > "$CB_HOME/tasks/fix-s/meta"
  printf 'MERGED' > "$CB_HOME/tasks/fix-s/pr.state"
  export GITMOCK_BRANCHES="$BATS_TEST_TMPDIR/branches"
  printf '  fe/fix-s\n' > "$GITMOCK_BRANCHES"
}

@test "fetch --prune runs for every repo row, not research-only rows" {
  run scripts/cerebro/cb-sync
  [ "$status" -eq 0 ]
  grep -q "GIT -C $CO fetch --prune origin" "$GITMOCK_LOG"
  [ "$(grep -c 'fetch --prune' "$GITMOCK_LOG")" = "1" ]
}

@test "clean checkout on base → ff merge" {
  run scripts/cerebro/cb-sync
  grep -q "GIT -C $CO merge --ff-only origin/main" "$GITMOCK_LOG"
}

@test "dirty checkout → no ff, noted" {
  export GITMOCK_STATUS="$BATS_TEST_TMPDIR/status"
  printf ' M something.cs\n' > "$GITMOCK_STATUS"
  run scripts/cerebro/cb-sync
  ! grep -q 'merge --ff-only' "$GITMOCK_LOG"
  [[ "$output" == *"dirty"* ]]
}

@test "checkout on a different branch → no ff" {
  printf 'fe/wip-thing' > "$GITMOCK_HEAD"
  run scripts/cerebro/cb-sync
  ! grep -q 'merge --ff-only' "$GITMOCK_LOG"
}

@test "merged task's lingering branch is pruned" {
  mk_merged_task
  run scripts/cerebro/cb-sync
  grep -q "GIT -C $CO branch -D fe/fix-s" "$GITMOCK_LOG"
}

@test "OPEN-pr task's branch is never pruned" {
  mk_merged_task
  printf 'OPEN' > "$CB_HOME/tasks/fix-s/pr.state"
  run scripts/cerebro/cb-sync
  ! grep -q 'branch -D' "$GITMOCK_LOG"
}

@test "branch checked out in a live worktree is never pruned" {
  mk_merged_task
  export GITMOCK_WORKTREES="$BATS_TEST_TMPDIR/worktrees"
  printf 'worktree /home/kyle/code/worktrees/fix-s\nbranch refs/heads/fe/fix-s\n' > "$GITMOCK_WORKTREES"
  run scripts/cerebro/cb-sync
  ! grep -q 'branch -D' "$GITMOCK_LOG"
  [[ "$output" == *"worktree"* ]]
}

@test "branch already gone locally → nothing to prune, no error" {
  mk_merged_task
  : > "$GITMOCK_BRANCHES"
  run scripts/cerebro/cb-sync
  [ "$status" -eq 0 ]
  ! grep -q 'branch -D' "$GITMOCK_LOG"
}
