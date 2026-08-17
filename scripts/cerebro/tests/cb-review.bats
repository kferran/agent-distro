#!/usr/bin/env bats
# cb-review (T24): read-only bounded branch diff for the operator/board.

setup() {
  export CB_HOME="$BATS_TEST_TMPDIR/.cerebro"; mkdir -p "$CB_HOME/tasks/fix-r"
  export CB_REGISTRY="$BATS_TEST_TMPDIR/projects.md"
  printf -- '- project: ultron\n  base: main\n  checkout: %s\n  delivery: bitbucket-pr\n' "$BATS_TEST_TMPDIR" > "$CB_REGISTRY"
  WT="$BATS_TEST_TMPDIR/wt"; mkdir -p "$WT"
  printf 'kind=code\nworktree=%s\njira=EJA-9\nsession=fix-r\ntarget=ultron\n' "$WT" > "$CB_HOME/tasks/fix-r/meta"
  export GITMOCK_LOG="$BATS_TEST_TMPDIR/git.log"
  cat > "$BATS_TEST_TMPDIR/gitmock" <<'EOF'
#!/usr/bin/env bash
echo "GIT $*" >> "$GITMOCK_LOG"
case "$*" in
  *"--stat"*) printf ' file.ts | 2 +-\n 1 file changed\n';;
  *diff*) seq 1 600 | sed 's/^/+line /';;
esac
EOF
  chmod +x "$BATS_TEST_TMPDIR/gitmock"
  export CB_GIT_CMD="$BATS_TEST_TMPDIR/gitmock"
  export CB_GUARD_CMD=:   # R1: don't invoke the real cb-guard (network MCP probe) from tests
}

# --- R1: cb-guard rides every supervision command ---
@test "cb-review runs cb-guard first" {
  export CB_GUARD_CMD="$BATS_TEST_TMPDIR/guard-rec"
  printf '#!/usr/bin/env bash\ntouch %q\n' "$BATS_TEST_TMPDIR/guard-ran" > "$CB_GUARD_CMD"
  chmod +x "$CB_GUARD_CMD"
  run scripts/cerebro/cb-review fix-r
  [ -f "$BATS_TEST_TMPDIR/guard-ran" ]
}

@test "diffs origin/<base>...HEAD in the task worktree (stat + patch)" {
  run scripts/cerebro/cb-review fix-r
  [ "$status" -eq 0 ]
  grep -q "GIT -C $WT diff origin/main...HEAD --stat" "$GITMOCK_LOG"
  grep -q "GIT -C $WT diff origin/main...HEAD$" "$GITMOCK_LOG"
  [[ "$output" == *"file.ts | 2 +-"* ]]
}

@test "patch output truncates at CB_REVIEW_MAX_LINES with a marker" {
  CB_REVIEW_MAX_LINES=50 run scripts/cerebro/cb-review fix-r
  [ "$status" -eq 0 ]
  [[ "$output" == *"+line 50"* ]]
  [[ "$output" != *"+line 51"* ]]
  [[ "$output" == *"truncated"* ]]
}

@test "default cap is 400 lines" {
  run scripts/cerebro/cb-review fix-r
  [[ "$output" == *"+line 400"* ]]
  [[ "$output" != *"+line 401"* ]]
}

@test "refuses a slug with no code meta" {
  mkdir -p "$CB_HOME/tasks/researchy"
  run scripts/cerebro/cb-review researchy
  [ "$status" -ne 0 ]
}
